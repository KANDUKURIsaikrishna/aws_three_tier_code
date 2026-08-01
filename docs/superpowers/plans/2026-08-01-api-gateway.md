# API Gateway (Plan 4 of 5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `api-gateway` — the single public entry point that routes to `catalog-service`, `user-service`, and `order-service`, enforces JWT auth on protected routes, and injects `X-User-Id` downstream. Then perform the one-way traffic cutover: point `api.bookstore.<domain>` at the gateway instead of the old monolith, tighten every other service's NetworkPolicy to only accept traffic from the gateway, and retire `backend/` (code + K8s manifests) for good.

**Architecture:** `api-gateway` is a standalone Node/Express app under `services/api-gateway/` using `http-proxy-middleware` to forward requests, and `jsonwebtoken` to verify tokens issued by `user-service` (shared secret at `/bookstore/jwt-secret`, created in Plan 2). It is stateless — no database, no schema-init hook. Unlike every prior plan, this one **is not verified standalone via port-forward first** — its entire purpose is the real public cutover, so Task 11 (manual verification) exercises it through the actual domain, with a real backend deletion in the middle. This is a one-way, higher-risk change; the plan sequences verification steps *before* the irreversible deletion (Task 10) wherever possible, per this repo's own established caution (`docs/TROUBLESHOOTING.md`'s pattern of never running destructive commands without first confirming the replacement actually works).

**Routing table** (from the design spec, unchanged):
```
/books*          -> catalog-service   (GET public, POST/PUT/DELETE require JWT)
/auth/*          -> user-service      (public — register/login)
/users*          -> user-service      (GET /users/me requires JWT)
/orders*, /cart*  -> order-service    (all require JWT)
(no route to notification-service — internal only, unchanged)
```

**Tech Stack:** Node.js 22 / Express, `http-proxy-middleware` (^2.0.6), `jsonwebtoken`, Terraform (existing module patterns), Kustomize + the existing ArgoCD ApplicationSet, vitest + supertest with real in-process HTTP servers as proxy targets (not mocks — proxying behavior is exactly what needs real verification here).

**Critical implementation detail — no `express.json()` in the gateway.** Every other service in this repo uses `app.use(express.json())`. The gateway must **not** — `http-proxy-middleware` forwards the raw incoming request stream to the upstream service; if `express.json()` (or any body-parsing middleware) runs first, it fully consumes that stream to populate `req.body`, and there is nothing left to forward — POST/PUT bodies silently arrive empty at the downstream service. This is one of the most common real-world `http-proxy-middleware` bugs. The gateway parses no body at all — it only reads headers (`Authorization`) and forwards everything else untouched.

---

## Pre-flight: what this plan touches vs. leaves alone

- **Does NOT modify** `services/catalog-service/`, `services/user-service/`, `services/order-service/`, `services/notification-service/`, or `client/` (frontend) source code. The frontend already talks to `api.bookstore.<domain>` and only ever calls `/books*` endpoints (it has no cart/auth UI — none was ever built, and building one is a separate, unrequested UI feature, out of scope here). Once the gateway proxies `/books*` to `catalog-service` — which already serves functionally identical book data (migrated in Plan 1) — the frontend keeps working with **zero code changes**. This is confirmed, not assumed: Task 11 curls the live frontend through the real domain after cutover.
- **DOES modify** `k8s/base/ingress/ingress.yaml` (drops the `api.bookstore.<domain>` host rule — that traffic now enters through a new Ingress in the `gateway` namespace instead).
- **DOES delete** `backend/` (the whole directory), `k8s/base/backend/`, `k8s/base/database/` (the dead in-cluster MySQL StatefulSet *and* this session's `schema-init-job.yaml` for the monolith's `test.books` — once `backend/` is gone, nothing reads `test.books` anymore; `catalog-service` reads its own already-migrated `catalog_db.books`), `k8s/base/configmaps/backend-config.yaml`, and `k8s/base/secrets/external-secret.yaml`'s `db-secret` `ExternalSecret` (its only consumer in `k8s/base` was `backend/`'s Rollout — once that's gone, nothing in the `bookstore` namespace reads `db-secret` either; every other service now has its own per-service DB credential).
- **DOES tighten** the NetworkPolicy `ingress: - {}` placeholder on `catalog-service`, `user-service`, and `order-service` — each explicitly deferred this to "Plan 4" in its own plan/manifest comments. `notification-service`'s policy is untouched (it was never open — see Plan 3).
- **Does not add a `ResourceQuota`** to the new `gateway` namespace — same reasoning as every prior plan (`docs/TROUBLESHOOTING.md` OBS-021).
- **Does not rotate or change** `/bookstore/jwt-secret` — created once in Plan 2, this plan only adds a third consumer (`api-gateway`; `order-service` deliberately does *not* verify JWTs itself, per Plan 3's Pre-flight — it trusts the header the gateway injects).

---

### Task 1: Add an `api-gateway` ECR repo

**Files:**
- Modify: `main.tf` (ecr module call)

- [ ] **Step 1: Add `api-gateway` to the `extra_repos` list**

Edit `main.tf`, in the `module "ecr"` block:

```hcl
module "ecr" {
  source                = "./modules/ecr"
  prefix                = "bookstore"
  image_retention_count = 10
  secondary_region      = var.secondary_region
  extra_repos           = ["catalog-service", "user-service", "order-service", "notification-service", "api-gateway"]
}
```

- [ ] **Step 2: Expose the new repo URL at root**

Edit `outputs.tf`, add after the existing `notification_service_repo_url` output:

```hcl
output "api_gateway_repo_url" {
  description = "ECR repository URL for the api-gateway image"
  value       = module.ecr.repo_urls["api-gateway"]
}
```

- [ ] **Step 3: Validate**

Run: `terraform validate`
Expected: `Success!` (same pre-existing cosmetic warning as every prior plan).

- [ ] **Step 4: Commit**

```bash
git add main.tf outputs.tf
git commit -m "feat(ecr): add api-gateway repository"
```

No new DB credentials or secrets in this task — `api-gateway` is stateless and reuses the existing `/bookstore/jwt-secret` from Plan 2.

---

### Task 2: Scaffold the api-gateway Node app

**Files:**
- Create: `services/api-gateway/package.json`
- Create: `services/api-gateway/.env.example`
- Create: `services/api-gateway/.gitignore`
- Create: `services/api-gateway/.dockerignore`
- Create: `services/api-gateway/Dockerfile`

- [ ] **Step 1: package.json**

Create `services/api-gateway/package.json`:

```json
{
  "name": "api-gateway",
  "version": "1.0.0",
  "main": "index.js",
  "type": "module",
  "scripts": {
    "start": "node index.js",
    "dev": "nodemon index.js",
    "test": "vitest run"
  },
  "dependencies": {
    "cors": "^2.8.5",
    "dotenv": "^16.0.3",
    "express": "^4.18.1",
    "http-proxy-middleware": "^2.0.6",
    "jsonwebtoken": "^9.0.2",
    "morgan": "^1.10.0",
    "prom-client": "^15.1.3"
  },
  "devDependencies": {
    "nodemon": "^3.1.14",
    "supertest": "^7.2.2",
    "vitest": "^2.1.9"
  },
  "keywords": [],
  "author": "",
  "license": "ISC",
  "description": "Bookstore API gateway — routing, JWT enforcement, single public entry point"
}
```

No `mysql2` — this service is stateless, no database.

- [ ] **Step 2: .env.example**

Create `services/api-gateway/.env.example`:

```
JWT_SECRET=
CATALOG_SERVICE_URL=http://catalog-service.catalog.svc.cluster.local
USER_SERVICE_URL=http://user-service.user.svc.cluster.local
ORDER_SERVICE_URL=http://order-service.order.svc.cluster.local
APP_PORT=3000
```

- [ ] **Step 3: .gitignore and .dockerignore**

Create `services/api-gateway/.gitignore`:

```
node_modules
.env
```

Create `services/api-gateway/.dockerignore`:

```
node_modules
npm-debug.log
.env
.env.*
!.env.example
.git
.gitignore
*.md
```

- [ ] **Step 4: Dockerfile**

Create `services/api-gateway/Dockerfile`:

```dockerfile
FROM node:22-alpine AS deps

WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force

FROM node:22-alpine AS runtime

RUN apk upgrade --no-cache

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

COPY --from=deps --chown=appuser:appgroup /app/node_modules ./node_modules
COPY --chown=appuser:appgroup . .
RUN rm -f package-lock.json package.json && \
    rm -rf /usr/local/lib/node_modules/npm \
           /usr/local/bin/npm \
           /usr/local/bin/npx \
           /usr/local/bin/corepack

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["node", "index.js"]
```

- [ ] **Step 5: Commit**

```bash
git add services/api-gateway/package.json services/api-gateway/.env.example \
  services/api-gateway/.gitignore services/api-gateway/.dockerignore \
  services/api-gateway/Dockerfile
git commit -m "chore(api-gateway): scaffold package + Dockerfile"
```

---

### Task 3: Write the failing test suite (TDD) — real in-process HTTP servers as proxy targets, not mocks

**Files:**
- Create: `services/api-gateway/__tests__/gateway.test.js`

Proxying behavior is exactly what this service exists to do correctly — mocking `http-proxy-middleware` itself would test nothing real. Instead, each test spins up a tiny real `node:http` server as a stand-in for a downstream service, points the gateway at its real `http://127.0.0.1:<port>` address, and asserts on what that stand-in server actually received.

- [ ] **Step 1: Write the test file, importing an `app.js` that does not exist yet**

Create `services/api-gateway/__tests__/gateway.test.js`:

```javascript
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import http from "node:http";
import jwt from "jsonwebtoken";
import request from "supertest";
import { createApp } from "../app.js";

const JWT_SECRET = "test-secret";

function startStubServer(handler) {
  return new Promise((resolve) => {
    const server = http.createServer(handler);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      resolve({ server, url: `http://127.0.0.1:${port}` });
    });
  });
}

let catalogStub, userStub, orderStub;
let app;

beforeAll(async () => {
  catalogStub = await startStubServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      res.writeHead(200, {
        "Content-Type": "application/json",
        "X-Received-Path": req.url,
        "X-Received-User-Id": req.headers["x-user-id"] || "",
      });
      res.end(JSON.stringify({ from: "catalog-service", method: req.method, body }));
    });
  });

  userStub = await startStubServer((req, res) => {
    res.writeHead(200, {
      "Content-Type": "application/json",
      "X-Received-Path": req.url,
      "X-Received-User-Id": req.headers["x-user-id"] || "",
    });
    res.end(JSON.stringify({ from: "user-service" }));
  });

  orderStub = await startStubServer((req, res) => {
    res.writeHead(200, {
      "Content-Type": "application/json",
      "X-Received-Path": req.url,
      "X-Received-User-Id": req.headers["x-user-id"] || "",
    });
    res.end(JSON.stringify({ from: "order-service" }));
  });

  app = createApp(JWT_SECRET, {
    catalog: catalogStub.url,
    user: userStub.url,
    order: orderStub.url,
  });
});

afterAll(() => {
  catalogStub.server.close();
  userStub.server.close();
  orderStub.server.close();
});

function tokenFor(userId) {
  return jwt.sign({ userId, email: `user${userId}@example.com` }, JWT_SECRET, { expiresIn: "1h" });
}

describe("GET /health", () => {
  it("returns ok without proxying anywhere", async () => {
    const res = await request(app).get("/health");
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: "ok" });
  });
});

describe("GET /metrics", () => {
  it("exposes service-labeled prometheus metrics", async () => {
    const res = await request(app).get("/metrics");
    expect(res.status).toBe(200);
    expect(res.text).toContain('service="api-gateway"');
  });
});

describe("GET /books (public)", () => {
  it("proxies to catalog-service with no auth required", async () => {
    const res = await request(app).get("/books");
    expect(res.status).toBe(200);
    expect(res.body.from).toBe("catalog-service");
    expect(res.headers["x-received-path"]).toBe("/books");
  });
});

describe("POST /books (protected)", () => {
  it("rejects with no token", async () => {
    const res = await request(app).post("/books").send({ title: "New" });
    expect(res.status).toBe(401);
  });

  it("proxies with a valid token and injects X-User-Id", async () => {
    const res = await request(app)
      .post("/books")
      .set("Authorization", `Bearer ${tokenFor(9)}`)
      .send({ title: "New" });
    expect(res.status).toBe(200);
    expect(res.body.from).toBe("catalog-service");
    expect(res.headers["x-received-user-id"]).toBe("9");
  });
});

describe("POST /auth/register and /auth/login (public)", () => {
  it("proxies /auth/register to user-service with no auth required", async () => {
    const res = await request(app).post("/auth/register").send({ email: "a@b.com", password: "x" });
    expect(res.status).toBe(200);
    expect(res.body.from).toBe("user-service");
  });

  it("proxies /auth/login to user-service with no auth required", async () => {
    const res = await request(app).post("/auth/login").send({ email: "a@b.com", password: "x" });
    expect(res.status).toBe(200);
    expect(res.body.from).toBe("user-service");
  });
});

describe("GET /users/me (protected)", () => {
  it("rejects with no token", async () => {
    const res = await request(app).get("/users/me");
    expect(res.status).toBe(401);
  });

  it("proxies with a valid token and injects X-User-Id", async () => {
    const res = await request(app).get("/users/me").set("Authorization", `Bearer ${tokenFor(4)}`);
    expect(res.status).toBe(200);
    expect(res.body.from).toBe("user-service");
    expect(res.headers["x-received-user-id"]).toBe("4");
  });
});

describe("/orders and /cart (protected)", () => {
  it("rejects GET /orders with no token", async () => {
    const res = await request(app).get("/orders");
    expect(res.status).toBe(401);
  });

  it("proxies GET /orders with a valid token and injects X-User-Id", async () => {
    const res = await request(app).get("/orders").set("Authorization", `Bearer ${tokenFor(6)}`);
    expect(res.status).toBe(200);
    expect(res.body.from).toBe("order-service");
    expect(res.headers["x-received-user-id"]).toBe("6");
  });

  it("rejects POST /cart with no token", async () => {
    const res = await request(app).post("/cart").send({ book_id: 1, quantity: 1 });
    expect(res.status).toBe(401);
  });

  it("proxies POST /cart with a valid token and injects X-User-Id", async () => {
    const res = await request(app)
      .post("/cart")
      .set("Authorization", `Bearer ${tokenFor(6)}`)
      .send({ book_id: 1, quantity: 1 });
    expect(res.status).toBe(200);
    expect(res.body.from).toBe("order-service");
    expect(res.headers["x-received-user-id"]).toBe("6");
  });
});

describe("invalid token handling", () => {
  it("rejects a malformed token on a protected route", async () => {
    const res = await request(app).get("/users/me").set("Authorization", "Bearer not-a-real-token");
    expect(res.status).toBe(401);
  });
});
```

- [ ] **Step 2: Install dependencies and run the test to verify it fails**

Run:
```bash
cd services/api-gateway && npm install
npx vitest run
```
Expected: FAIL — `Cannot find module '../app.js'`.

- [ ] **Step 3: Commit the failing test**

```bash
git add services/api-gateway/__tests__/gateway.test.js services/api-gateway/package-lock.json
git commit -m "test(api-gateway): add failing routing/auth test suite with real proxy-target stub servers"
```

---

### Task 4: Implement api-gateway (`app.js` + `index.js`)

**Files:**
- Create: `services/api-gateway/app.js`
- Create: `services/api-gateway/index.js`

- [ ] **Step 1: Write `app.js`**

Create `services/api-gateway/app.js`:

```javascript
import express from "express";
import cors from "cors";
import morgan from "morgan";
import jwt from "jsonwebtoken";
import { createProxyMiddleware } from "http-proxy-middleware";
import { Registry, collectDefaultMetrics, Counter, Histogram } from "prom-client";

const SERVICE_NAME = "api-gateway";

const registry = new Registry();
registry.setDefaultLabels({ service: SERVICE_NAME });
collectDefaultMetrics({ register: registry });

const httpRequests = new Counter({
  name: "http_requests_total",
  help: "Total HTTP requests",
  labelNames: ["method", "route", "status", "service"],
  registers: [registry],
});

const httpDuration = new Histogram({
  name: "http_request_duration_seconds",
  help: "HTTP request duration in seconds",
  labelNames: ["method", "route", "status", "service"],
  buckets: [0.01, 0.05, 0.1, 0.5, 1, 2],
  registers: [registry],
});

function verifyJwt(jwtSecret) {
  return (req, res, next) => {
    const header = req.headers.authorization;
    if (!header || !header.startsWith("Bearer ")) {
      return res.status(401).json({ error: "missing or invalid Authorization header" });
    }
    const token = header.slice("Bearer ".length);
    try {
      const decoded = jwt.verify(token, jwtSecret);
      req.headers["x-user-id"] = String(decoded.userId);
      next();
    } catch {
      return res.status(401).json({ error: "invalid or expired token" });
    }
  };
}

// GET is public (book browsing); every other method requires a valid JWT.
function protectMutations(jwtSecret) {
  return (req, res, next) => {
    if (req.method === "GET") return next();
    return verifyJwt(jwtSecret)(req, res, next);
  };
}

// targets = { catalog: url, user: url, order: url }
export function createApp(jwtSecret, targets) {
  const app = express();
  app.use(cors());
  app.use(morgan("common"));
  // Deliberately NO express.json() here — see the plan's "critical
  // implementation detail" note. Parsing the body would consume the
  // request stream before http-proxy-middleware can forward it.

  app.use((req, res, next) => {
    const start = Date.now();
    res.on("finish", () => {
      const duration = (Date.now() - start) / 1000;
      httpRequests.labels(req.method, req.path, String(res.statusCode), SERVICE_NAME).inc();
      httpDuration.labels(req.method, req.path, String(res.statusCode), SERVICE_NAME).observe(duration);
    });
    next();
  });

  app.get("/metrics", async (_req, res) => {
    res.set("Content-Type", registry.contentType);
    res.end(await registry.metrics());
  });

  app.get("/health", (_req, res) => {
    res.status(200).json({ status: "ok" });
  });

  app.use(
    "/books",
    protectMutations(jwtSecret),
    createProxyMiddleware({ target: targets.catalog, changeOrigin: true })
  );

  app.use("/auth", createProxyMiddleware({ target: targets.user, changeOrigin: true }));

  app.use(
    "/users",
    verifyJwt(jwtSecret),
    createProxyMiddleware({ target: targets.user, changeOrigin: true })
  );

  app.use(
    ["/orders", "/cart"],
    verifyJwt(jwtSecret),
    createProxyMiddleware({ target: targets.order, changeOrigin: true })
  );

  return app;
}
```

- [ ] **Step 2: Write `index.js`**

Create `services/api-gateway/index.js`:

```javascript
import dotenv from "dotenv";
import { createApp } from "./app.js";

dotenv.config();

const targets = {
  catalog: process.env.CATALOG_SERVICE_URL || "http://catalog-service.catalog.svc.cluster.local",
  user: process.env.USER_SERVICE_URL || "http://user-service.user.svc.cluster.local",
  order: process.env.ORDER_SERVICE_URL || "http://order-service.order.svc.cluster.local",
};

const app = createApp(process.env.JWT_SECRET, targets);
const APP_PORT = process.env.APP_PORT || 3000;
app.listen(APP_PORT, () => {
  console.log(`api-gateway listening on port ${APP_PORT}.`);
});
```

- [ ] **Step 3: Run the tests, verify they pass**

Run: `cd services/api-gateway && npx vitest run`
Expected: All 12 tests pass (health, metrics, books public GET, books protected POST x2, auth x2, users/me x2, orders/cart x4, invalid token x1 — recount: 1+1+1+2+2+2+4+1 = 14; the exact count doesn't matter, the important thing is zero failures).

- [ ] **Step 4: Commit**

```bash
git add services/api-gateway/app.js services/api-gateway/index.js
git commit -m "feat(api-gateway): implement routing, JWT enforcement, X-User-Id injection"
```

---

### Task 5: K8s manifests for api-gateway

**Files:**
- Create: `k8s/services/api-gateway/base/namespace.yaml`
- Create: `k8s/services/api-gateway/base/configmap.yaml`
- Create: `k8s/services/api-gateway/base/external-secret.yaml`
- Create: `k8s/services/api-gateway/base/deployment.yaml`
- Create: `k8s/services/api-gateway/base/service.yaml`
- Create: `k8s/services/api-gateway/base/ingress.yaml`
- Create: `k8s/services/api-gateway/base/hpa.yaml`
- Create: `k8s/services/api-gateway/base/pdb.yaml`
- Create: `k8s/services/api-gateway/base/network-policy.yaml`
- Create: `k8s/services/api-gateway/base/kustomization.yaml`
- Create: `k8s/services/api-gateway/overlays/prod/kustomization.yaml`

- [ ] **Step 1: Namespace**

Create `k8s/services/api-gateway/base/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: gateway
  labels:
    name: gateway
```

- [ ] **Step 2: ConfigMap**

Create `k8s/services/api-gateway/base/configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: gateway-config
  namespace: gateway
data:
  APP_PORT: "3000"
  CATALOG_SERVICE_URL: "http://catalog-service.catalog.svc.cluster.local"
  USER_SERVICE_URL: "http://user-service.user.svc.cluster.local"
  ORDER_SERVICE_URL: "http://order-service.order.svc.cluster.local"
```

- [ ] **Step 3: ExternalSecret** — reads the JWT secret Plan 2 already created

Create `k8s/services/api-gateway/base/external-secret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: jwt-secret
  namespace: gateway
spec:
  refreshInterval: 1h

  secretStoreRef:
    name: aws-secretsmanager
    kind: ClusterSecretStore

  target:
    name:           jwt-secret
    creationPolicy: Owner

  data:
    - secretKey: JWT_SECRET
      remoteRef:
        key:      /bookstore/jwt-secret
        property: JWT_SECRET
```

No `PreSync` annotation needed — `api-gateway` has no schema-init hook depending on this secret; the Deployment just needs it present before its own pods start, which ArgoCD's normal Sync-phase ordering (Secret before Deployment, both plain resources) already guarantees.

- [ ] **Step 4: Deployment**

Create `k8s/services/api-gateway/base/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-gateway
  namespace: gateway
  labels:
    app: api-gateway
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api-gateway
  template:
    metadata:
      labels:
        app: api-gateway
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        runAsGroup: 1001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: api-gateway
          image: bookstore-api-gateway:latest
          ports:
            - containerPort: 3000
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
          env:
            - name: JWT_SECRET
              valueFrom:
                secretKeyRef: { name: jwt-secret, key: JWT_SECRET }
            - name: APP_PORT
              valueFrom:
                configMapKeyRef: { name: gateway-config, key: APP_PORT }
            - name: CATALOG_SERVICE_URL
              valueFrom:
                configMapKeyRef: { name: gateway-config, key: CATALOG_SERVICE_URL }
            - name: USER_SERVICE_URL
              valueFrom:
                configMapKeyRef: { name: gateway-config, key: USER_SERVICE_URL }
            - name: ORDER_SERVICE_URL
              valueFrom:
                configMapKeyRef: { name: gateway-config, key: ORDER_SERVICE_URL }
          readinessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 30
            periodSeconds: 15
            failureThreshold: 3
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
```

`replicas: 2` and higher resource limits than every other service (`100m`/`128Mi` requests, `500m`/`256Mi` limits) — deliberate: this is the single public entry point for every request that used to go straight to `backend/`, so it's sized like the old `backend` Rollout container was (`k8s/overlays/prod/kustomization.yaml`'s patch: `128Mi`/`256Mi` limits), not like the internal-only services behind it.

- [ ] **Step 5: Service**

Create `k8s/services/api-gateway/base/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: gateway-service
  namespace: gateway
  labels:
    app: api-gateway
spec:
  selector:
    app: api-gateway
  ports:
    - name: http
      port: 80
      targetPort: 3000
  type: ClusterIP
```

Named `gateway-service` (not `api-gateway`) to match this repo's existing convention of `<role>-service` names for anything an `Ingress` points at (`backend-service`, `frontend-service` in `k8s/base/`) — the Ingress in Step 6 references this exact name.

- [ ] **Step 6: Ingress — `api.bookstore.<domain>`, moved here from `k8s/base/ingress/ingress.yaml`**

Create `k8s/services/api-gateway/base/ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gateway-ingress
  namespace: gateway
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - api.bookstore.b17facebook.xyz
      secretName: gateway-tls
  rules:
    - host: api.bookstore.b17facebook.xyz
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: gateway-service
                port:
                  number: 80
```

A Kubernetes `Ingress` backend `Service` must live in the **same namespace** as the `Ingress` object itself — that's why this is a brand new `Ingress` resource in the `gateway` namespace, not a rule added to the existing one in `bookstore`. `gateway-tls` is a **new**, separate TLS Secret — Secrets are namespace-scoped too, so this namespace can't reuse `bookstore` namespace's `bookstore-tls`. `cert-manager` issues it independently via the same `letsencrypt-prod` `ClusterIssuer` (HTTP-01 challenge) already used for the existing cert; this is a normal, expected new `Certificate`/`Order`, not a conflict with the existing one.

The literal domain `b17facebook.xyz` is hardcoded here the same way it already is in `k8s/base/ingress/ingress.yaml` (this repo's existing convention — not templated per-environment anywhere else either, so this plan doesn't introduce a new pattern).

- [ ] **Step 7: HPA**

Create `k8s/services/api-gateway/base/hpa.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-gateway-hpa
  namespace: gateway
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-gateway
  minReplicas: 2
  maxReplicas: 8
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
```

`minReplicas: 2` / `maxReplicas: 8` — higher than every other service's `1`/`5`, matching the Deployment's own higher baseline (Step 4) since this is the single front door for all traffic.

- [ ] **Step 8: PDB**

Create `k8s/services/api-gateway/base/pdb.yaml`:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api-gateway-pdb
  namespace: gateway
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: api-gateway
```

- [ ] **Step 9: NetworkPolicy** — accepts from `ingress-nginx` (public traffic), egresses to all three downstream namespaces + DNS. No RDS egress needed — `api-gateway` has no database.

Create `k8s/services/api-gateway/base/network-policy.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: gateway
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-gateway-policy
  namespace: gateway
spec:
  podSelector:
    matchLabels:
      app: api-gateway
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - port: 3000
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: catalog
      ports:
        - port: 80
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: user
      ports:
        - port: 80
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: order
      ports:
        - port: 80
    - ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
```

- [ ] **Step 10: Kustomize base**

Create `k8s/services/api-gateway/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: gateway

resources:
- namespace.yaml
- configmap.yaml
- external-secret.yaml
- deployment.yaml
- service.yaml
- ingress.yaml
- hpa.yaml
- pdb.yaml
- network-policy.yaml
```

- [ ] **Step 11: Prod overlay**

Create `k8s/services/api-gateway/overlays/prod/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../../base

images:
- name: bookstore-api-gateway
  newName: 000000000000.dkr.ecr.us-west-1.amazonaws.com/bookstore-api-gateway
  newTag: latest
```

- [ ] **Step 12: Validate manifests render**

Run: `kubectl kustomize k8s/services/api-gateway/overlays/prod`
Expected: Rendered YAML for Namespace, ConfigMap, ExternalSecret, Deployment, Service, Ingress, HPA, PDB, 2x NetworkPolicy — no errors.

- [ ] **Step 13: Commit**

```bash
git add k8s/services/api-gateway/base k8s/services/api-gateway/overlays
git commit -m "feat(api-gateway): add K8s manifests, including the new gateway-namespace Ingress for api.bookstore.<domain>"
```

---

### Task 6: Tighten NetworkPolicies on catalog-service, user-service, and order-service

**Files:**
- Modify: `k8s/services/catalog-service/base/network-policy.yaml`
- Modify: `k8s/services/user-service/base/network-policy.yaml`
- Modify: `k8s/services/order-service/base/network-policy.yaml`

Each of these currently has `ingress: - {}` (open to any pod in the cluster) with a comment promising this gets tightened once `api-gateway` exists. It now does.

- [ ] **Step 1: Tighten catalog-service**

Edit `k8s/services/catalog-service/base/network-policy.yaml`, replace the `catalog-service-policy`'s `ingress` block:

```yaml
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: gateway
      ports:
        - port: 3000
```

- [ ] **Step 2: Tighten user-service**

Edit `k8s/services/user-service/base/network-policy.yaml`, replace the `user-service-policy`'s `ingress` block with the identical structure (same `gateway` namespace selector, same port).

- [ ] **Step 3: Tighten order-service**

Edit `k8s/services/order-service/base/network-policy.yaml`, replace the `order-service-policy`'s `ingress` block with the identical structure. (Its `egress` block — RDS, `notification` namespace, DNS — is untouched; only `ingress` changes.)

- [ ] **Step 4: Validate all three render correctly**

Run:
```bash
kubectl kustomize k8s/services/catalog-service/overlays/prod | grep -A6 "name: catalog-service-policy"
kubectl kustomize k8s/services/user-service/overlays/prod | grep -A6 "name: user-service-policy"
kubectl kustomize k8s/services/order-service/overlays/prod | grep -A6 "name: order-service-policy"
```
Expected: each shows the new `namespaceSelector` matching `gateway`, not the old `- {}`.

- [ ] **Step 5: Commit**

```bash
git add k8s/services/catalog-service/base/network-policy.yaml \
        k8s/services/user-service/base/network-policy.yaml \
        k8s/services/order-service/base/network-policy.yaml
git commit -m "fix(network-policy): restrict catalog/user/order ingress to the gateway namespace now that api-gateway exists"
```

---

### Task 7: ArgoCD — add api-gateway to the existing ApplicationSet

**Files:**
- Modify: `k8s/argocd/applicationset-microservices.yaml`

- [ ] **Step 1: Append the new element**

```yaml
  generators:
    - list:
        elements:
          - service: catalog-service
            namespace: catalog
          - service: user-service
            namespace: user
          - service: notification-service
            namespace: notification
          - service: order-service
            namespace: order
          - service: api-gateway
            namespace: gateway
```

- [ ] **Step 2: Commit**

```bash
git add k8s/argocd/applicationset-microservices.yaml
git commit -m "feat(argocd): add api-gateway to the microservices ApplicationSet"
```

---

### Task 8: CI — build, scan, and push api-gateway

**Files:**
- Modify: `.github/workflows/ci-cd.yml`

- [ ] **Step 1: Add an `API_GATEWAY_REPO` env var**

```yaml
env:
  AWS_REGION:        us-west-1
  BACKEND_REPO:      bookstore-backend
  FRONTEND_REPO:     bookstore-frontend
  CATALOG_REPO:      bookstore-catalog-service
  USER_REPO:         bookstore-user-service
  ORDER_REPO:        bookstore-order-service
  NOTIFICATION_REPO: bookstore-notification-service
  API_GATEWAY_REPO:  bookstore-api-gateway
  EKS_CLUSTER:       bookstore-eks
  K8S_NAMESPACE:     bookstore
```

(`BACKEND_REPO` stays for this task — it's still removed together with the rest of `backend/` in Task 9's CI cleanup, not here, to keep this task's diff focused on additions only.)

- [ ] **Step 2: Add api-gateway to the `sast` job's Node setup cache path and test steps**

```yaml
      - uses: actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020  # v4
        with:
          node-version: "18"
          cache: npm
          cache-dependency-path: |
            backend/package-lock.json
            client/package-lock.json
            services/catalog-service/package-lock.json
            services/user-service/package-lock.json
            services/order-service/package-lock.json
            services/notification-service/package-lock.json
            services/api-gateway/package-lock.json
```

After the existing "npm audit — order-service production deps" step, add:

```yaml
      - name: Install api-gateway dependencies
        run: cd services/api-gateway && npm ci

      - name: Run api-gateway tests
        run: cd services/api-gateway && npm test

      - name: npm audit — api-gateway production deps (fail on high/critical CVEs)
        run: cd services/api-gateway && npm audit --audit-level=high --omit=dev
```

- [ ] **Step 3: Build, scan, and push the api-gateway image**

In the `build-and-push` job, after "Push order-service image" and before the "Frontend image" section, add:

```yaml
      # ── API gateway image ────────────────────────────────────────────────
      - name: Build api-gateway image (no push yet)
        uses: docker/build-push-action@10e90e3645eae34f1e60eeb005ba3a3d33f178e8  # v6
        with:
          context:   ./services/api-gateway
          push:      false
          load:      true
          tags:      ${{ env.ECR_REGISTRY }}/${{ env.API_GATEWAY_REPO }}:${{ steps.tag.outputs.tag }}
          cache-from: type=gha
          cache-to:   type=gha,mode=max

      - name: Trivy — scan api-gateway (CRITICAL + HIGH = hard fail)
        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25  # v0.36.0
        with:
          image-ref:      ${{ env.ECR_REGISTRY }}/${{ env.API_GATEWAY_REPO }}:${{ steps.tag.outputs.tag }}
          format:         sarif
          output:         trivy-api-gateway.sarif
          severity:       CRITICAL,HIGH
          exit-code:      "1"
          ignore-unfixed: true

      - name: Show api-gateway CVEs in CI log (diagnostic on failure)
        if: failure()
        run: |
          [ -f trivy-api-gateway.sarif ] && \
            jq -r '.runs[].results[] |
              "[" + (.level | ascii_upcase) + "] " + .ruleId +
              ": " + (.message.text | split("\n")[0])' \
            trivy-api-gateway.sarif \
          || echo "trivy-api-gateway.sarif not found"

      - name: Upload api-gateway Trivy SARIF to GitHub Security tab
        uses: github/codeql-action/upload-sarif@8aad20d150bbac5944a9f9d289da16a4b0d87c1e  # v4
        if: always()
        with:
          sarif_file: trivy-api-gateway.sarif
          category:   trivy-api-gateway

      - name: Push api-gateway image
        run: |
          docker push ${{ env.ECR_REGISTRY }}/${{ env.API_GATEWAY_REPO }}:${{ steps.tag.outputs.tag }}
```

- [ ] **Step 4: Bump the api-gateway image tag in the `deploy` job**

Add one more `kustomize edit` line and one more path to `git add`, alongside the existing ones (this step's exact final form is superseded by Task 9 Step 5, which also removes the `backend`-related lines in the same file — written out in full there to avoid two overlapping partial edits to the same step).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci-cd.yml
git commit -m "ci: build/scan/push api-gateway image"
```

---

### Task 9: Retire `backend/` — code, K8s manifests, CI steps, and the old ingress rule

**This is the irreversible part of this plan.** Every step in this task is sequenced *after* Task 5-8 (api-gateway fully built, tested, and deployable) and *before* Task 11 (which proves the new path works over the real domain, then confirms the old one is gone). Do not skip ahead to this task before those are done.

**Files:**
- Delete: `backend/` (entire directory)
- Delete: `k8s/base/backend/` (entire directory)
- Delete: `k8s/base/database/` (entire directory — the dead in-cluster MySQL StatefulSet, plus this session's `schema-init-job.yaml` for the monolith's `test.books`, now unreferenced once `backend/` is gone)
- Delete: `k8s/base/configmaps/backend-config.yaml`
- Modify: `k8s/base/secrets/external-secret.yaml` (remove the `db-secret` `ExternalSecret` block)
- Modify: `k8s/base/ingress/ingress.yaml` (remove the `api.bookstore.<domain>` host rule and its TLS entry)
- Modify: `k8s/base/kustomization.yaml` (remove references to everything just deleted)
- Modify: `.github/workflows/ci-cd.yml` (remove backend-specific steps, finish the `deploy` job edit from Task 8 Step 4)

- [ ] **Step 1: Confirm the replacement is actually live before deleting anything**

```bash
curl -s https://api.bookstore.b17facebook.xyz/books
```
This should currently still return data from the OLD `backend/` (the cutover in Step 6 below hasn't happened yet in this task's ordering) — this is just a sanity baseline. Do not proceed to Step 2 until Task 5's `api-gateway` Application shows `Synced`/`Healthy` in `kubectl get applications -n argocd` (verify now if you haven't already — this task assumes it).

- [ ] **Step 2: Trim `k8s/base/ingress/ingress.yaml` to just the frontend host**

Edit `k8s/base/ingress/ingress.yaml`, remove the `api.bookstore.b17facebook.xyz` entry from `tls.hosts` and delete its entire `rules` block, leaving:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: bookstore-ingress
  namespace: bookstore
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - bookstore.b17facebook.xyz
      secretName: bookstore-tls
  rules:
    - host: bookstore.b17facebook.xyz
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend-service
                port:
                  number: 80
```

`bookstore-tls`'s existing cert covers both hostnames as SANs (issued when both rules existed) — cert-manager will simply stop renewing the `api.bookstore.<domain>` SAN on the next renewal cycle once it's no longer referenced; the current cert stays valid for `bookstore.<domain>` regardless. `api-gateway`'s own `Ingress` (Task 5 Step 6) already has its own separate cert (`gateway-tls`) for `api.bookstore.<domain>` — no gap in coverage at any point.

- [ ] **Step 3: Remove `db-secret` from `k8s/base/secrets/external-secret.yaml`**

Edit the file, delete the entire second `ExternalSecret` block (`metadata.name: db-secret`) — keep only the `ClusterSecretStore` at the top (every other service's `ExternalSecret` still references it by name).

- [ ] **Step 4: Delete the dead directories and file**

```bash
git rm -r backend/
git rm -r k8s/base/backend/
git rm -r k8s/base/database/
git rm k8s/base/configmaps/backend-config.yaml
```

- [ ] **Step 5: Update `k8s/base/kustomization.yaml`**

Edit `k8s/base/kustomization.yaml`, remove the lines referencing now-deleted files:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: bookstore

resources:
- storageclass/gp3.yaml
- namespace.yaml
- cert-manager/cluster-issuer.yaml
- secrets/external-secret.yaml
- frontend/deployment.yaml
- frontend/service.yaml
- ingress/ingress.yaml
- network-policy/network-policy.yaml
- pdb/pdb.yaml
- quota.yaml
- monitoring/analysis-template.yaml
```

Removed: `configmaps/backend-config.yaml`, `database/schema-init-job.yaml`, `backend/rollout.yaml`, `backend/service.yaml` — all now-deleted or (for `analysis-template.yaml`, which stays) unrelated to `backend/`'s existence.

Note: `analysis-template.yaml` (Argo Rollouts' `AnalysisTemplate`) was only ever consumed by `backend`'s `Rollout` — with the `Rollout` gone, this becomes dead configuration too, but it is **not** deleted in this plan. It's inert (an `AnalysisTemplate` with no `Rollout` referencing it does nothing) and removing it is unrelated cleanup outside this plan's cutover scope — noted here so it isn't mistaken for an oversight; track it in `docs/FUTURE_IMPROVEMENTS.md` if it should be cleaned up later.

- [ ] **Step 6: Update `network-policy/network-policy.yaml`** — the `bookstore` namespace's `backend-policy` NetworkPolicy has no more `backend` pods to select; the `frontend-policy`'s egress rule to `app: backend` is now dead too

Edit `k8s/base/network-policy/network-policy.yaml`, remove the entire `backend-policy` `NetworkPolicy` block, and remove `frontend-policy`'s now-dead egress rule to `app: backend`:

```yaml
# Default deny all ingress + egress in bookstore namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: bookstore
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
# Frontend: accept from ingress-nginx only; send to DNS only.
# (Previously also egressed to backend:3000 in-namespace — the frontend now
# calls api.bookstore.<domain> over the public internet, through
# api-gateway's own Ingress, same as any other client; no in-cluster path
# to a same-namespace "backend" exists anymore.)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-policy
  namespace: bookstore
spec:
  podSelector:
    matchLabels:
      app: frontend
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - port: 8080
  egress:
    - ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
```

This matches how the React frontend has always actually called its API — via `REACT_APP_API_URL` (a public URL, `client/Dockerfile`'s build-arg), not an in-cluster Service DNS name — confirmed by reading `client/Dockerfile` and the CI workflow's `build-args: REACT_APP_API_URL=${{ secrets.API_URL }}` before writing this step. The frontend pod's egress was always going out through `ingress-nginx`/the internet for its API calls in practice, even though the NetworkPolicy technically also allowed a same-namespace path to `backend` that the app never used.

- [ ] **Step 7: Remove backend-specific CI steps and finish the `deploy` job edit**

Edit `.github/workflows/ci-cd.yml`:

Remove the `BACKEND_REPO` line from the top-level `env:` block.

Remove `backend/package-lock.json` from the `sast` job's `cache-dependency-path`.

Remove these three steps from the `sast` job: "Install backend dependencies", "Run backend tests", "npm audit — backend production deps".

Remove the entire "── Backend image ──" block from `build-and-push` (every step from "Build backend image (no push yet)" through "Push backend image").

Replace the `deploy` job's "Update image tags in kustomization.yaml" and "Commit and push updated image tags" steps with their final form (this also completes Task 8 Step 4's api-gateway addition, and drops every `backend`-related line):

```yaml
      - name: Update image tags in kustomization.yaml
        env:
          TAG: ${{ needs.build-and-push.outputs.image-tag }}
        run: |
          cd k8s/overlays/prod
          kustomize edit set image \
            bookstore-frontend=${{ env.ECR_REGISTRY }}/${{ env.FRONTEND_REPO }}:${TAG}
          cd ../../services/catalog-service/overlays/prod
          kustomize edit set image \
            bookstore-catalog-service=${{ env.ECR_REGISTRY }}/${{ env.CATALOG_REPO }}:${TAG}
          cd ../../user-service/overlays/prod
          kustomize edit set image \
            bookstore-user-service=${{ env.ECR_REGISTRY }}/${{ env.USER_REPO }}:${TAG}
          cd ../../notification-service/overlays/prod
          kustomize edit set image \
            bookstore-notification-service=${{ env.ECR_REGISTRY }}/${{ env.NOTIFICATION_REPO }}:${TAG}
          cd ../../order-service/overlays/prod
          kustomize edit set image \
            bookstore-order-service=${{ env.ECR_REGISTRY }}/${{ env.ORDER_REPO }}:${TAG}
          cd ../../api-gateway/overlays/prod
          kustomize edit set image \
            bookstore-api-gateway=${{ env.ECR_REGISTRY }}/${{ env.API_GATEWAY_REPO }}:${TAG}

      - name: Commit and push updated image tags
        env:
          TAG: ${{ needs.build-and-push.outputs.image-tag }}
        run: |
          git config user.email "ci-bot@github-actions"
          git config user.name "GitHub Actions"
          git add k8s/overlays/prod/kustomization.yaml \
                  k8s/services/catalog-service/overlays/prod/kustomization.yaml \
                  k8s/services/user-service/overlays/prod/kustomization.yaml \
                  k8s/services/notification-service/overlays/prod/kustomization.yaml \
                  k8s/services/order-service/overlays/prod/kustomization.yaml \
                  k8s/services/api-gateway/overlays/prod/kustomization.yaml
          git diff --staged --quiet && echo "No image tag changes." && exit 0
          git commit -m "chore: bump image tags to ${TAG}"
          git push
```

Also remove `bookstore-backend=...` from `k8s/overlays/prod/kustomization.yaml`'s own `images:` list (Task 9 Step 8 below handles this file directly).

- [ ] **Step 8: Remove the backend image entry from `k8s/overlays/prod/kustomization.yaml`**

Edit `k8s/overlays/prod/kustomization.yaml`, remove the `bookstore-backend` entry from `images:`, and remove the `patches:` block targeting `kind: Rollout, name: backend` (no `Rollout` named `backend` exists anymore):

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../../base
- hpa-frontend.yaml

images:
- name: bookstore-frontend
  newName: 905221885307.dkr.ecr.us-west-1.amazonaws.com/bookstore-frontend
  newTag: 3af802cf

patches:
- target:
    group: cert-manager.io
    version: v1
    kind: ClusterIssuer
    name: letsencrypt-prod
  patch: |-
    - op: replace
      path: /spec/acme/email
      value: kandukurisaikrishna778@gmail.com
```

Also remove `hpa-backend.yaml` from `resources:` (listed above already excluded) and delete that file:

```bash
git rm k8s/overlays/prod/hpa-backend.yaml
```

- [ ] **Step 9: Validate everything still renders**

Run:
```bash
kubectl kustomize k8s/overlays/prod
```
Expected: renders cleanly — Namespace, ConfigMap, ExternalSecret (`db-secret` gone), frontend Deployment/Service/HPA, trimmed Ingress (one host only), trimmed NetworkPolicies, PDB, quota, `analysis-template.yaml` (inert but present), `ClusterIssuer` patch. No reference to `backend` anywhere in the output:
```bash
kubectl kustomize k8s/overlays/prod | grep -i backend
```
Expected: no output.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat(cutover): retire backend/ — traffic now flows through api-gateway

One-way cutover per docs/superpowers/specs/2026-07-29-microservices-observability-design.md:
- deleted backend/ and its K8s manifests (Deployment/Rollout, Service,
  ConfigMap, the dead in-cluster MySQL StatefulSet under k8s/base/database/,
  and this session's schema-init-job.yaml for the monolith's test.books —
  nothing reads it anymore)
- removed db-secret (only ever consumed by backend's Rollout)
- api.bookstore.<domain> now routes to api-gateway (new Ingress in the
  gateway namespace, own TLS cert) instead of directly to backend-service
- tightened frontend-policy's egress (dead in-namespace route to backend removed)
- removed all backend-specific CI steps"
```

- [ ] **Step 11: Push and let ArgoCD reconcile the deletions**

```bash
git push origin observability
kubectl -n argocd annotate application bookstore argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd patch application bookstore --type merge -p '{"operation":{"sync":{"revision":"observability","prune":false}}}'
kubectl -n argocd patch application bookstore --type merge -p '{"operation":{"sync":{"revision":"observability","prune":true}}}'
```
`prune: true` is what actually lets ArgoCD delete the live `backend` Rollout/Service/ConfigMap/db-secret/NetworkPolicy objects that no longer appear in the manifests — this is the moment the old backend actually stops existing in the cluster, not just in git.

---

### Task 10: Manual verification (real `terraform apply`, real deploy, real cutover, real curl through the actual domain)

No new files — this task exercises the full, real cutover end-to-end.

- [ ] **Step 1: Apply the Terraform changes**

Run: `terraform plan -out=gateway.tfplan`
Review: should show only `aws_ecr_repository.this["bookstore-api-gateway"]` as new — no other resource changes (no DB credentials needed for this plan).

Run: `terraform apply gateway.tfplan`

- [ ] **Step 2: Let ArgoCD deploy api-gateway (before touching backend/)**

```bash
kubectl -n argocd annotate applicationset bookstore-microservices argocd.argoproj.io/refresh=hard --overwrite
kubectl get applications -n argocd
```
Expected: an `Application` named `api-gateway` appears, reaches `Synced`/`Healthy`.

- [ ] **Step 3: Confirm cert-manager issued the new `gateway-tls` certificate**

```bash
kubectl get certificate -n gateway
```
Expected: `gateway-tls`, `READY: True`. If still `False`/pending, check `kubectl describe certificate gateway-tls -n gateway` for the HTTP-01 challenge status before proceeding — DNS for `api.bookstore.<domain>` must already resolve to the ingress LB for this to succeed (it does, confirmed earlier this session).

- [ ] **Step 4: Curl every route through the real domain, through the gateway, BEFORE deleting `backend/`**

```bash
curl -s https://api.bookstore.b17facebook.xyz/books
# Expected: the real book list, proxied through api-gateway -> catalog-service

TOKEN=$(curl -s -X POST https://api.bookstore.b17facebook.xyz/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"cutover-test@example.com","password":"hunter22"}' \
  > /dev/null; \
  curl -s -X POST https://api.bookstore.b17facebook.xyz/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"cutover-test@example.com","password":"hunter22"}' | jq -r .token)
echo "$TOKEN"

curl -s https://api.bookstore.b17facebook.xyz/users/me -H "Authorization: Bearer $TOKEN"
# Expected: the registered user's profile

curl -s -X POST https://api.bookstore.b17facebook.xyz/cart \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"book_id":1,"quantity":1}'
# Expected: {"book_id":1,"quantity":1}

curl -s -X POST https://api.bookstore.b17facebook.xyz/orders/checkout -H "Authorization: Bearer $TOKEN"
# Expected: 201, one order created

curl -s https://api.bookstore.b17facebook.xyz/orders -H "Authorization: Bearer $TOKEN"
# Expected: the order just created
```

**Do not proceed to Task 9's deletion steps until every one of these returns the expected result.** This is the real proof the replacement works, before the irreversible part happens.

- [ ] **Step 5: Now execute Task 9** (retire `backend/`) if not already done, then push and force the sync per Task 9 Step 11.

- [ ] **Step 6: Confirm the old backend is actually gone from the cluster**

```bash
kubectl get all -n bookstore
```
Expected: no `backend` Deployment/Rollout, no `backend-service`, no `backend-schema-init` Job — only `frontend` and the `cm-acme-http-solver` pods (unrelated, cert-manager's own challenge pods) remain.

```bash
kubectl get secret db-secret -n bookstore
```
Expected: `Error from server (NotFound)`.

- [ ] **Step 7: Re-run every curl from Step 4 again** — confirms the cutover didn't regress anything now that the old path is gone.

- [ ] **Step 8: Prove the `X-User-Id` trust boundary is actually enforced — not just that the gateway path works**

The design spec's own "Open risks" section is explicit: *"`X-User-Id` trust boundary depends on NetworkPolicy actually blocking direct external access to service pods — must be verified, not assumed."* Steps 4 and 7 only proved the gateway path *works* — they don't prove a caller **can't bypass the gateway** and forge an `X-User-Id` header directly against `order-service`. `kubectl port-forward` can't be used for this check — it talks straight to the pod's network namespace and bypasses NetworkPolicy entirely (the same reason catalog-service's Plan 1 could always reach it via port-forward even before any Ingress existed). The real test needs traffic to originate from a pod in a namespace NetworkPolicy actually evaluates.

Run this from a pod that is **not** in the `gateway` namespace (a throwaway debug pod in, e.g., the `default` namespace, which Task 6's tightened NetworkPolicies never allow):

```bash
kubectl run netpol-check --rm -it --restart=Never --image=curlimages/curl -- \
  curl -s -m 5 -o /dev/null -w "HTTP %{http_code} (000 = blocked/timed out)\n" \
  http://order-service.order.svc.cluster.local/orders \
  -H "X-User-Id: 1"
```

Expected: `HTTP 000` (connection timeout — no route allowed) or the pod hangs until curl's own `-m 5` timeout fires. **If this instead returns a real HTTP status** (200, 401, anything), the NetworkPolicy tightening in Task 6 did not actually take effect — stop and diagnose before considering this plan done, since that would mean any pod anywhere in the cluster can currently forge `X-User-Id` and hit `order-service` directly, completely bypassing the gateway's JWT check. Repeat the same check against `catalog-service.catalog.svc.cluster.local/books` (with `-X POST`, since `GET` is intentionally public even through the gateway) and `user-service.user.svc.cluster.local/users/me` for full coverage of all three tightened services.

- [ ] **Step 9: Confirm the frontend still works, unmodified**

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://bookstore.b17facebook.xyz
```
Expected: `200`. Then open it in a real browser and confirm the book list renders — this is the actual proof the frontend's existing, unmodified `REACT_APP_API_URL` calls now correctly flow through `api-gateway` to `catalog-service` with no frontend code changes, exactly as this plan's Pre-flight predicted.

- [ ] **Step 10: Final commit — mark this plan's outcome**

No code changes at this step; if any fixes were needed during verification, commit those now with a clear message.

---

## Plan Series Status

- [x] Design spec approved — `docs/superpowers/specs/2026-07-29-microservices-observability-design.md`
- [x] Plan 1 — catalog-service (live)
- [ ] Plan 2 — user-service
- [ ] Plan 3 — order-service (with cart/checkout) + notification-service
- [ ] **Plan 4 (this file) — api-gateway (routing, JWT enforcement, traffic cutover, old `backend/` removal)**
- [ ] Plan 5 — observability (EC2 Prometheus scrape config, Grafana dashboards, Alertmanager rules)

Plan 5 (observability extension across all 5 new namespaces) was not requested in this round and is not written yet — every service built in Plans 1-4 already exposes `/metrics` in the same `service`-labeled prom-client format, so Plan 5 is scoped purely to the EC2 Prometheus scrape config and Grafana dashboards, not any application code change.
