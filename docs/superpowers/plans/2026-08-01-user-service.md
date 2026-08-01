# User Service (Plan 2 of 5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `user-service` — a new, real (not skeleton) microservice owning users and authentication: registration, login, JWT issuance, and `GET /users/me`. Nothing in this repo does auth today — this is a net-new feature build, not an extraction.

**Architecture:** `user-service` is a standalone Node/Express app under `services/user-service/`, following the exact same shape as `services/catalog-service/` (same `app.js`/`index.js` split, same prom-client metrics pattern with a `service="user-service"` label, same Dockerfile, same K8s manifest set). It owns its own MySQL schema (`user_db`) and DB user inside the existing RDS instance, its own ECR repo, its own K8s namespace (`user`), and gets added as a new element to the existing `k8s/argocd/applicationset-microservices.yaml` list generator — no new ArgoCD Application needed. It also creates a new shared secret, `/bookstore/jwt-secret`, that `api-gateway` and `order-service` will read in Plan 4/Plan 3 — this plan only creates and uses it, doesn't wire it anywhere else yet. Traffic does **not** cut over — verified via `kubectl port-forward`, same as catalog-service's Plan 1. No new IRSA role is needed: `external-secrets-sa`'s existing policy already covers `arn:aws:secretsmanager:*:*:secret:/bookstore/*` (see `modules/eks-addons/external-secrets.tf`, fixed in catalog-service's Plan 1 Task 0).

**Tech Stack:** Node.js 22 / Express (matches every other service in this repo), `bcryptjs` (pure-JS, no native build step needed in the Alpine multi-stage Dockerfile — `bcrypt` would need `python3`/`make`/`g++` added to the `deps` stage, `bcryptjs` avoids that entirely), `jsonwebtoken`, Terraform (existing module patterns), Kustomize + the existing ArgoCD ApplicationSet, vitest + supertest.

---

## Pre-flight: what this plan touches vs. leaves alone

- **Does NOT modify** `backend/`, `client/`, `services/catalog-service/`, `k8s/base/`, `k8s/overlays/`, `k8s/argocd/application.yaml`, or any existing service's NetworkPolicy — the existing apps keep running untouched.
- **Does NOT wire `/bookstore/jwt-secret` into any other service yet.** `api-gateway` (Plan 4) and `order-service` (Plan 3) each add their own `ExternalSecret` reading it in their own plans — this plan only creates the Secrets Manager entry and consumes it inside `user-service` itself.
- **Appends** one element to `k8s/argocd/applicationset-microservices.yaml`'s existing list generator (`elements:`) rather than creating a new ArgoCD resource — same pattern every future service plan uses.
- Reuses the shared `aws-secretsmanager` `ClusterSecretStore` (already exists, cluster-wide, created once in `k8s/base/secrets/external-secret.yaml`) and the shared `external-secrets-sa` IRSA role (already scoped to `/bookstore/*`, no changes needed) — confirmed by reading `modules/eks-addons/external-secrets.tf` and `k8s/services/catalog-service/base/external-secret.yaml` before writing this plan.
- **Does not add a `ResourceQuota`** to the new `user` namespace. `catalog` namespace has none and that's intentional precedent — `bookstore-quota` (only in the `bookstore` namespace) caused a real incident (`docs/TROUBLESHOOTING.md` OBS-021: a PreSync hook Job got permanently rejected because it didn't declare `resources`, and the rejection is silent/non-obvious). Every container in this plan still sets `resources.requests`/`.limits` anyway (matches `catalog-service`'s convention) — just not enforced by a namespace-level `ResourceQuota`.

---

### Task 1: Add a `user-service` ECR repo

**Files:**
- Modify: `main.tf:95-101` (ecr module call)

- [ ] **Step 1: Add `user-service` to the `extra_repos` list**

Edit `main.tf`, in the `module "ecr"` block:

```hcl
module "ecr" {
  source                = "./modules/ecr"
  prefix                = "bookstore"
  image_retention_count = 10
  secondary_region      = var.secondary_region
  extra_repos           = ["catalog-service", "user-service"]
}
```

- [ ] **Step 2: Expose the new repo URL at root**

Edit `outputs.tf`, add after the existing `catalog_service_repo_url` output:

```hcl
output "user_service_repo_url" {
  description = "ECR repository URL for the user-service image"
  value       = module.ecr.repo_urls["user-service"]
}
```

- [ ] **Step 3: Validate**

Run: `terraform validate`
Expected: `Success! The configuration is valid, but there were some validation warnings as shown above.` (the pre-existing `ignore_changes` warning on `modules/acm/main.tf` — unrelated, already documented in `docs/TROUBLESHOOTING.md` as cosmetic, not a new issue).

- [ ] **Step 4: Commit**

```bash
git add main.tf outputs.tf
git commit -m "feat(ecr): add user-service repository"
```

---

### Task 2: User DB credentials + JWT secret

**Files:**
- Modify: `main.tf` (new resources, append after the `catalog_db_credentials` block)
- Modify: `outputs.tf`

- [ ] **Step 1: Generate and store user DB credentials**

Append to `main.tf`, after the existing `aws_secretsmanager_secret_version.catalog_db_credentials` block:

```hcl
# ── User Service — DB credentials ─────────────────────────────────────────────

resource "random_password" "user_db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}?"
}

resource "aws_secretsmanager_secret" "user_db_credentials" {
  name                    = "/bookstore/user-db-credentials"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "user_db_credentials" {
  secret_id = aws_secretsmanager_secret.user_db_credentials.id
  secret_string = jsonencode({
    DB_USERNAME = "user_service_user"
    DB_PASSWORD = random_password.user_db_password.result
    DB_HOST     = module.rds.rds_endpoint
    DB_NAME     = "user_db"
  })
}

# ── Shared JWT signing secret ──────────────────────────────────────────────────
# user-service issues tokens; api-gateway (Plan 4) and order-service (Plan 3)
# each add their own ExternalSecret reading this same entry to verify them.
# HS256 (symmetric) per the design spec — one shared secret, not a keypair.

resource "random_password" "jwt_secret" {
  length  = 64
  special = false # JWT secret goes straight into an env var; avoid shell-metacharacter escaping issues
}

resource "aws_secretsmanager_secret" "jwt_secret" {
  name                    = "/bookstore/jwt-secret"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "jwt_secret" {
  secret_id = aws_secretsmanager_secret.jwt_secret.id
  secret_string = jsonencode({
    JWT_SECRET = random_password.jwt_secret.result
  })
}
```

- [ ] **Step 2: Expose the secret ARNs**

Edit `outputs.tf`, add:

```hcl
output "user_db_secret_arn" {
  description = "ARN of the Secrets Manager secret at /bookstore/user-db-credentials"
  value       = aws_secretsmanager_secret.user_db_credentials.arn
  sensitive   = true
}

output "jwt_secret_arn" {
  description = "ARN of the Secrets Manager secret at /bookstore/jwt-secret"
  value       = aws_secretsmanager_secret.jwt_secret.arn
  sensitive   = true
}
```

- [ ] **Step 3: Validate**

Run: `terraform validate`
Expected: `Success!` (same pre-existing warning as Task 1).

- [ ] **Step 4: Commit**

```bash
git add main.tf outputs.tf
git commit -m "feat(user-service): provision DB credentials + shared JWT secret"
```

---

### Task 3: Scaffold the user-service Node app

**Files:**
- Create: `services/user-service/package.json`
- Create: `services/user-service/.env.example`
- Create: `services/user-service/.gitignore`
- Create: `services/user-service/.dockerignore`
- Create: `services/user-service/Dockerfile`

- [ ] **Step 1: package.json**

Create `services/user-service/package.json`:

```json
{
  "name": "user-service",
  "version": "1.0.0",
  "main": "index.js",
  "type": "module",
  "scripts": {
    "start": "node index.js",
    "dev": "nodemon index.js",
    "test": "vitest run"
  },
  "dependencies": {
    "bcryptjs": "^2.4.3",
    "cors": "^2.8.5",
    "dotenv": "^16.0.3",
    "express": "^4.18.1",
    "jsonwebtoken": "^9.0.2",
    "morgan": "^1.10.0",
    "mysql2": "^3.6.0",
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
  "description": "Bookstore user microservice — registration, login, JWT issuance"
}
```

- [ ] **Step 2: .env.example**

Create `services/user-service/.env.example`:

```
DB_HOST=
DB_USERNAME=
DB_PASSWORD=
DB_PORT=3306
DB_NAME=user_db
JWT_SECRET=
APP_PORT=3000
```

- [ ] **Step 3: .gitignore and .dockerignore**

Create `services/user-service/.gitignore`:

```
node_modules
.env
```

Create `services/user-service/.dockerignore`:

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

Create `services/user-service/Dockerfile` (identical pattern to `services/catalog-service/Dockerfile`):

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
git add services/user-service/package.json services/user-service/.env.example \
  services/user-service/.gitignore services/user-service/.dockerignore \
  services/user-service/Dockerfile
git commit -m "chore(user-service): scaffold package + Dockerfile"
```

---

### Task 4: Write the failing test suite (TDD)

**Files:**
- Create: `services/user-service/__tests__/auth.test.js`

- [ ] **Step 1: Write the test file, importing an `app.js` that does not exist yet**

Create `services/user-service/__tests__/auth.test.js`:

```javascript
import { describe, it, expect, vi, beforeEach } from "vitest";
import request from "supertest";
import jwt from "jsonwebtoken";
import { createApp } from "../app.js";

const JWT_SECRET = "test-secret";
const mockQuery = vi.fn();
const app = createApp({ query: mockQuery }, JWT_SECRET);

beforeEach(() => {
  mockQuery.mockReset();
});

describe("GET /health", () => {
  it("returns ok", async () => {
    const res = await request(app).get("/health");
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: "ok" });
  });
});

describe("GET /metrics", () => {
  it("exposes service-labeled prometheus metrics", async () => {
    const res = await request(app).get("/metrics");
    expect(res.status).toBe(200);
    expect(res.text).toContain('service="user-service"');
  });
});

describe("POST /auth/register", () => {
  it("creates a user and returns 201 with no password fields", async () => {
    // First query: check for existing email (none found)
    mockQuery.mockImplementationOnce((_q, _p, cb) => cb(null, []));
    // Second query: the INSERT
    mockQuery.mockImplementationOnce((_q, _p, cb) => cb(null, { insertId: 1, affectedRows: 1 }));

    const res = await request(app)
      .post("/auth/register")
      .send({ email: "new@example.com", password: "hunter22" });

    expect(res.status).toBe(201);
    expect(res.body).toEqual({ id: 1, email: "new@example.com" });
    expect(res.body.password).toBeUndefined();
    expect(res.body.password_hash).toBeUndefined();
  });

  it("rejects registration when the email is already taken", async () => {
    mockQuery.mockImplementationOnce((_q, _p, cb) =>
      cb(null, [{ id: 5, email: "taken@example.com" }])
    );

    const res = await request(app)
      .post("/auth/register")
      .send({ email: "taken@example.com", password: "hunter22" });

    expect(res.status).toBe(409);
    expect(res.body).toEqual({ error: "email already registered" });
  });

  it("rejects registration with a missing email or password", async () => {
    const res = await request(app).post("/auth/register").send({ email: "only@example.com" });
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: "email and password are required" });
  });
});

describe("POST /auth/login", () => {
  it("returns a valid JWT for correct credentials", async () => {
    const bcrypt = await import("bcryptjs");
    const hash = await bcrypt.hash("hunter22", 10);
    mockQuery.mockImplementationOnce((_q, _p, cb) =>
      cb(null, [{ id: 7, email: "user@example.com", password_hash: hash }])
    );

    const res = await request(app)
      .post("/auth/login")
      .send({ email: "user@example.com", password: "hunter22" });

    expect(res.status).toBe(200);
    expect(typeof res.body.token).toBe("string");

    const decoded = jwt.verify(res.body.token, JWT_SECRET);
    expect(decoded.userId).toBe(7);
    expect(decoded.email).toBe("user@example.com");
  });

  it("returns 401 for a wrong password", async () => {
    const bcrypt = await import("bcryptjs");
    const hash = await bcrypt.hash("correct-password", 10);
    mockQuery.mockImplementationOnce((_q, _p, cb) =>
      cb(null, [{ id: 7, email: "user@example.com", password_hash: hash }])
    );

    const res = await request(app)
      .post("/auth/login")
      .send({ email: "user@example.com", password: "wrong-password" });

    expect(res.status).toBe(401);
    expect(res.body).toEqual({ error: "invalid email or password" });
  });

  it("returns 401 when the email does not exist", async () => {
    mockQuery.mockImplementationOnce((_q, _p, cb) => cb(null, []));

    const res = await request(app)
      .post("/auth/login")
      .send({ email: "nobody@example.com", password: "anything" });

    expect(res.status).toBe(401);
    expect(res.body).toEqual({ error: "invalid email or password" });
  });
});

describe("GET /users/me", () => {
  it("returns the caller's profile for a valid token", async () => {
    const token = jwt.sign({ userId: 3, email: "me@example.com" }, JWT_SECRET, { expiresIn: "1h" });
    mockQuery.mockImplementationOnce((_q, _p, cb) =>
      cb(null, [{ id: 3, email: "me@example.com", created_at: "2026-01-01T00:00:00.000Z" }])
    );

    const res = await request(app).get("/users/me").set("Authorization", `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ id: 3, email: "me@example.com", created_at: "2026-01-01T00:00:00.000Z" });
  });

  it("returns 401 with no Authorization header", async () => {
    const res = await request(app).get("/users/me");
    expect(res.status).toBe(401);
    expect(res.body).toEqual({ error: "missing or invalid Authorization header" });
  });

  it("returns 401 for an invalid token", async () => {
    const res = await request(app).get("/users/me").set("Authorization", "Bearer not-a-real-token");
    expect(res.status).toBe(401);
    expect(res.body).toEqual({ error: "invalid or expired token" });
  });
});
```

- [ ] **Step 2: Install dependencies and run the test to verify it fails**

Run:
```bash
cd services/user-service && npm install
npx vitest run
```
Expected: FAIL — `Cannot find module '../app.js'` (or similar resolve error), since `app.js` doesn't exist yet.

- [ ] **Step 3: Commit the failing test**

```bash
git add services/user-service/__tests__/auth.test.js services/user-service/package-lock.json
git commit -m "test(user-service): add failing auth test suite"
```

---

### Task 5: Implement user-service (`app.js` + `index.js`)

**Files:**
- Create: `services/user-service/app.js`
- Create: `services/user-service/index.js`

- [ ] **Step 1: Write `app.js`**

Create `services/user-service/app.js`:

```javascript
import express from "express";
import cors from "cors";
import morgan from "morgan";
import bcrypt from "bcryptjs";
import jwt from "jsonwebtoken";
import { Registry, collectDefaultMetrics, Counter, Histogram } from "prom-client";

const SERVICE_NAME = "user-service";

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
      req.user = jwt.verify(token, jwtSecret);
      next();
    } catch {
      return res.status(401).json({ error: "invalid or expired token" });
    }
  };
}

export function createApp(db, jwtSecret) {
  const app = express();
  app.use(cors());
  app.use(express.json());
  app.use(morgan("common"));

  app.use((req, res, next) => {
    const start = Date.now();
    res.on("finish", () => {
      const route = req.route ? req.route.path : req.path;
      const duration = (Date.now() - start) / 1000;
      httpRequests.labels(req.method, route, String(res.statusCode), SERVICE_NAME).inc();
      httpDuration.labels(req.method, route, String(res.statusCode), SERVICE_NAME).observe(duration);
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

  app.post("/auth/register", (req, res) => {
    const { email, password } = req.body;
    if (!email || !password) {
      return res.status(400).json({ error: "email and password are required" });
    }

    db.query("SELECT id FROM users WHERE email = ?", [email], (err, existing) => {
      if (err) return res.status(500).json({ error: "internal error" });
      if (existing.length > 0) {
        return res.status(409).json({ error: "email already registered" });
      }

      const passwordHash = bcrypt.hashSync(password, 10);
      db.query(
        "INSERT INTO users (email, password_hash) VALUES (?, ?)",
        [email, passwordHash],
        (insertErr, result) => {
          if (insertErr) return res.status(500).json({ error: "internal error" });
          return res.status(201).json({ id: result.insertId, email });
        }
      );
    });
  });

  app.post("/auth/login", (req, res) => {
    const { email, password } = req.body;
    if (!email || !password) {
      return res.status(400).json({ error: "email and password are required" });
    }

    db.query("SELECT id, email, password_hash FROM users WHERE email = ?", [email], (err, rows) => {
      if (err) return res.status(500).json({ error: "internal error" });
      if (rows.length === 0) {
        return res.status(401).json({ error: "invalid email or password" });
      }

      const user = rows[0];
      const valid = bcrypt.compareSync(password, user.password_hash);
      if (!valid) {
        return res.status(401).json({ error: "invalid email or password" });
      }

      const token = jwt.sign({ userId: user.id, email: user.email }, jwtSecret, { expiresIn: "1h" });
      return res.status(200).json({ token });
    });
  });

  app.get("/users/me", verifyJwt(jwtSecret), (req, res) => {
    db.query(
      "SELECT id, email, created_at FROM users WHERE id = ?",
      [req.user.userId],
      (err, rows) => {
        if (err) return res.status(500).json({ error: "internal error" });
        if (rows.length === 0) return res.status(404).json({ error: "user not found" });
        return res.status(200).json(rows[0]);
      }
    );
  });

  return app;
}
```

- [ ] **Step 2: Write `index.js`**

Create `services/user-service/index.js`:

```javascript
import mysql from "mysql2";
import dotenv from "dotenv";
import { createApp } from "./app.js";

dotenv.config();

const db = mysql.createConnection({
  host: process.env.DB_HOST,
  user: process.env.DB_USERNAME,
  password: process.env.DB_PASSWORD,
  port: process.env.DB_PORT || 3306,
  database: process.env.DB_NAME || "user_db",
});

const app = createApp(db, process.env.JWT_SECRET);
const APP_PORT = process.env.APP_PORT || 3000;
app.listen(APP_PORT, () => {
  console.log(`user-service listening on port ${APP_PORT}.`);
});
```

- [ ] **Step 3: Run the tests, verify they pass**

Run: `cd services/user-service && npx vitest run`
Expected: All 9 tests pass (health, metrics, register x3, login x3, users/me x3 — 11 total across the 4 `describe` blocks — recount against the actual file: health=1, metrics=1, register=3, login=3, users/me=3 = 11 tests).

- [ ] **Step 4: Commit**

```bash
git add services/user-service/app.js services/user-service/index.js
git commit -m "feat(user-service): implement registration, login, JWT issuance, and /users/me"
```

---

### Task 6: K8s manifests

**Files:**
- Create: `k8s/services/user-service/base/namespace.yaml`
- Create: `k8s/services/user-service/base/configmap.yaml`
- Create: `k8s/services/user-service/base/external-secret.yaml`
- Create: `k8s/services/user-service/base/admin-db-secret.yaml`
- Create: `k8s/services/user-service/base/schema-init-job.yaml`
- Create: `k8s/services/user-service/base/deployment.yaml`
- Create: `k8s/services/user-service/base/service.yaml`
- Create: `k8s/services/user-service/base/hpa.yaml`
- Create: `k8s/services/user-service/base/pdb.yaml`
- Create: `k8s/services/user-service/base/network-policy.yaml`
- Create: `k8s/services/user-service/base/kustomization.yaml`
- Create: `k8s/services/user-service/overlays/prod/kustomization.yaml`

- [ ] **Step 1: Namespace**

Create `k8s/services/user-service/base/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: user
  labels:
    name: user
```

- [ ] **Step 2: ConfigMap**

Create `k8s/services/user-service/base/configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-config
  namespace: user
data:
  DB_PORT: "3306"
  DB_NAME: "user_db"
  APP_PORT: "3000"
```

- [ ] **Step 3: ExternalSecret for the service's own DB + JWT credentials**

Create `k8s/services/user-service/base/external-secret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: user-db-secret
  namespace: user
spec:
  refreshInterval: 1h

  secretStoreRef:
    name: aws-secretsmanager
    kind: ClusterSecretStore

  target:
    name:           user-db-secret
    creationPolicy: Owner

  data:
    - secretKey: DB_USERNAME
      remoteRef:
        key:      /bookstore/user-db-credentials
        property: DB_USERNAME

    - secretKey: DB_PASSWORD
      remoteRef:
        key:      /bookstore/user-db-credentials
        property: DB_PASSWORD

    - secretKey: DB_HOST
      remoteRef:
        key:      /bookstore/user-db-credentials
        property: DB_HOST
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: jwt-secret
  namespace: user
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

- [ ] **Step 4: Admin DB credentials, materialized into the `user` namespace — needed by the schema-init hook**

Same pattern as `k8s/services/catalog-service/base/admin-db-secret.yaml` — pulls the same `/bookstore/db-credentials` entry the cluster-wide admin secret already uses.

Create `k8s/services/user-service/base/admin-db-secret.yaml`:

```yaml
# ─────────────────────────────────────────────────────────────────────────────
# Admin DB credentials, materialized into the user namespace
#
# The schema-init PreSync hook Job (schema-init-job.yaml) needs RDS admin
# credentials to create the user_db schema and the user_service_user MySQL
# user. Same pattern as catalog-service's admin-db-secret.yaml — pulling the
# same admin secret a second time into this namespace, no new IAM permissions
# needed (external-secrets-sa is already scoped to /bookstore/*).
# ─────────────────────────────────────────────────────────────────────────────

apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: admin-db-secret
  namespace: user
  annotations:
    # PreSync + an earlier sync-wave than schema-init-job.yaml (PreSync,
    # default wave "0") — same fix as catalog-service's admin-db-secret /
    # bookstore's db-secret. Without this the Job has no guarantee this
    # secret exists yet, since PreSync hooks and normal Sync-phase resources
    # are separate phases. See docs/TROUBLESHOOTING.md OBS-013.
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/sync-wave: "-1"
spec:
  refreshInterval: 1h

  secretStoreRef:
    name: aws-secretsmanager
    kind: ClusterSecretStore

  target:
    name:           admin-db-secret
    creationPolicy: Owner

  data:
    - secretKey: DB_HOST
      remoteRef:
        key:      /bookstore/db-credentials
        property: DB_HOST

    - secretKey: DB_USERNAME
      remoteRef:
        key:      /bookstore/db-credentials
        property: DB_USERNAME

    - secretKey: DB_PASSWORD
      remoteRef:
        key:      /bookstore/db-credentials
        property: DB_PASSWORD
```

The `user-db-secret` ExternalSecret created in Step 3 also needs the same PreSync ordering annotation — the schema-init Job (Step 5) reads its `DB_PASSWORD` to create the MySQL user. Go back and add these annotations to the `user-db-secret` `ExternalSecret` in `k8s/services/user-service/base/external-secret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: user-db-secret
  namespace: user
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/sync-wave: "-1"
spec:
  refreshInterval: 1h
  # ... rest unchanged from Step 3
```

(The `jwt-secret` `ExternalSecret` does NOT need this annotation — nothing in this plan's PreSync hook reads it.)

- [ ] **Step 5: Schema-init PreSync hook Job** — creates `user_db`, the `users` table, and the scoped `user_service_user` MySQL user. No legacy data to migrate (users never existed anywhere before this plan), so this is simpler than catalog-service's — no `INSERT ... SELECT FROM` migration step.

Create `k8s/services/user-service/base/schema-init-job.yaml`:

```yaml
# ─────────────────────────────────────────────────────────────────────────────
# User DB schema bootstrap — ArgoCD PreSync hook, same pattern as
# k8s/services/catalog-service/base/schema-init-job.yaml (see
# docs/TROUBLESHOOTING.md OBS-013/015/017/021 for why hook-delete-policy,
# resources, and the securityContext below look the way they do).
# ─────────────────────────────────────────────────────────────────────────────

apiVersion: batch/v1
kind: Job
metadata:
  name: user-schema-init
  namespace: user
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation,HookSucceeded
spec:
  backoffLimit: 2
  template:
    metadata:
      # Matches network-policy.yaml's user-service-policy podSelector —
      # without this label the namespace's default-deny-all NetworkPolicy
      # blocks this pod's egress to RDS (port 3306).
      labels:
        app: user-service
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        runAsGroup: 1001
        seccompProfile:
          type: RuntimeDefault
      restartPolicy: Never
      containers:
        - name: schema-init
          image: mysql:8.0
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "250m"
              memory: "128Mi"
          command:
            - sh
            - -c
            - |
              set -eu
              mysql -h "$ADMIN_DB_HOST" -u "$ADMIN_DB_USERNAME" -p"$ADMIN_DB_PASSWORD" <<SQL
              CREATE DATABASE IF NOT EXISTS user_db;

              CREATE TABLE IF NOT EXISTS user_db.users (
                id            INT AUTO_INCREMENT PRIMARY KEY,
                email         VARCHAR(255) NOT NULL UNIQUE,
                password_hash VARCHAR(255) NOT NULL,
                created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
              );

              CREATE USER IF NOT EXISTS 'user_service_user'@'%' IDENTIFIED BY '$USER_DB_PASSWORD';
              GRANT ALL PRIVILEGES ON user_db.* TO 'user_service_user'@'%';
              FLUSH PRIVILEGES;
              SQL
          env:
            - name: ADMIN_DB_HOST
              valueFrom:
                secretKeyRef: { name: admin-db-secret, key: DB_HOST }
            - name: ADMIN_DB_USERNAME
              valueFrom:
                secretKeyRef: { name: admin-db-secret, key: DB_USERNAME }
            - name: ADMIN_DB_PASSWORD
              valueFrom:
                secretKeyRef: { name: admin-db-secret, key: DB_PASSWORD }
            - name: USER_DB_PASSWORD
              valueFrom:
                secretKeyRef: { name: user-db-secret, key: DB_PASSWORD }
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
```

This SQL heredoc is unquoted (`<<SQL`) for `$USER_DB_PASSWORD` expansion (same reason as catalog-service's, see `docs/TROUBLESHOOTING.md` OBS-003) but contains **no backtick-quoted identifiers** (`email`, `password_hash`, `created_at`, `id` are all plain unreserved words, no backticks needed anywhere in this SQL) — so the OBS-017 backtick-escaping hazard does not apply here. Confirmed by re-reading the SQL above: zero backtick characters.

- [ ] **Step 6: Deployment**

Create `k8s/services/user-service/base/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: user-service
  namespace: user
  labels:
    app: user-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: user-service
  template:
    metadata:
      labels:
        app: user-service
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        runAsGroup: 1001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: user-service
          image: bookstore-user-service:latest
          ports:
            - containerPort: 3000
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "250m"
              memory: "128Mi"
          env:
            - name: DB_HOST
              valueFrom:
                secretKeyRef: { name: user-db-secret, key: DB_HOST }
            - name: DB_USERNAME
              valueFrom:
                secretKeyRef: { name: user-db-secret, key: DB_USERNAME }
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef: { name: user-db-secret, key: DB_PASSWORD }
            - name: JWT_SECRET
              valueFrom:
                secretKeyRef: { name: jwt-secret, key: JWT_SECRET }
            - name: DB_PORT
              valueFrom:
                configMapKeyRef: { name: user-config, key: DB_PORT }
            - name: DB_NAME
              valueFrom:
                configMapKeyRef: { name: user-config, key: DB_NAME }
            - name: APP_PORT
              valueFrom:
                configMapKeyRef: { name: user-config, key: APP_PORT }
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

- [ ] **Step 7: Service**

Create `k8s/services/user-service/base/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: user-service
  namespace: user
  labels:
    app: user-service
spec:
  selector:
    app: user-service
  ports:
    - name: http
      port: 80
      targetPort: 3000
  type: ClusterIP
```

- [ ] **Step 8: HPA**

Create `k8s/services/user-service/base/hpa.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: user-service-hpa
  namespace: user
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: user-service
  minReplicas: 1
  maxReplicas: 5
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

- [ ] **Step 9: PDB**

Create `k8s/services/user-service/base/pdb.yaml`:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: user-service-pdb
  namespace: user
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: user-service
```

- [ ] **Step 10: NetworkPolicy** — same "open ingress, tightened once api-gateway exists" pattern as catalog-service's Plan 1 (see that file's own comment — Plan 4 tightens both).

Create `k8s/services/user-service/base/network-policy.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: user
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: user-service-policy
  namespace: user
spec:
  podSelector:
    matchLabels:
      app: user-service
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - {} # tightened in Plan 4 once api-gateway exists and owns ingress
  egress:
    - to:
        - ipBlock:
            cidr: 170.20.0.0/16
      ports:
        - port: 3306
    - ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
```

- [ ] **Step 11: Kustomize base**

Create `k8s/services/user-service/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: user

resources:
- namespace.yaml
- configmap.yaml
- external-secret.yaml
- admin-db-secret.yaml
- schema-init-job.yaml
- deployment.yaml
- service.yaml
- hpa.yaml
- pdb.yaml
- network-policy.yaml
```

- [ ] **Step 12: Prod overlay**

Create `k8s/services/user-service/overlays/prod/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../../base

# Account ID is intentionally NOT hardcoded here.
# CI (deploy stage) overwrites this from secrets.AWS_ACCOUNT_ID every push:
#   kustomize edit set image bookstore-user-service=${ECR_REGISTRY}/bookstore-user-service:${SHA}
# Placeholder 000000000000 is replaced automatically on first CI deploy.
# For manual local deploy: replace 000000000000 with your real AWS account ID.
images:
- name: bookstore-user-service
  newName: 000000000000.dkr.ecr.us-west-1.amazonaws.com/bookstore-user-service
  newTag: latest
```

- [ ] **Step 13: Validate manifests render**

Run: `kubectl kustomize k8s/services/user-service/overlays/prod`
Expected: Rendered YAML for Namespace, ConfigMap, 2x ExternalSecret (user-db-secret, jwt-secret), admin-db-secret ExternalSecret, schema-init Job, Deployment, Service, HPA, PDB, 2x NetworkPolicy — no errors.

- [ ] **Step 14: Commit**

```bash
git add k8s/services/user-service/base k8s/services/user-service/overlays
git commit -m "feat(user-service): add K8s manifests (namespace, deployment, service, hpa, pdb, netpol, schema-init hook)"
```

---

### Task 7: ArgoCD — add user-service to the existing ApplicationSet

**Files:**
- Modify: `k8s/argocd/applicationset-microservices.yaml`

- [ ] **Step 1: Append the new element**

Edit `k8s/argocd/applicationset-microservices.yaml`'s `elements` list:

```yaml
  generators:
    - list:
        elements:
          - service: catalog-service
            namespace: catalog
          - service: user-service
            namespace: user
```

- [ ] **Step 2: Commit**

```bash
git add k8s/argocd/applicationset-microservices.yaml
git commit -m "feat(argocd): add user-service to the microservices ApplicationSet"
```

---

### Task 8: CI — build, scan, and push user-service

**Files:**
- Modify: `.github/workflows/ci-cd.yml`

- [ ] **Step 1: Add a `USER_REPO` env var**

Edit the top-level `env:` block:

```yaml
env:
  AWS_REGION:    us-west-1
  BACKEND_REPO:  bookstore-backend
  FRONTEND_REPO: bookstore-frontend
  CATALOG_REPO:  bookstore-catalog-service
  USER_REPO:     bookstore-user-service
  EKS_CLUSTER:   bookstore-eks
  K8S_NAMESPACE: bookstore
```

- [ ] **Step 2: Add user-service to the `sast` job's Node setup cache path**

Edit the `sast` job's `actions/setup-node` step:

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
```

- [ ] **Step 3: Run user-service's own tests in the `sast` job**

In the `sast` job, after the existing "npm audit — catalog-service production deps" step, add:

```yaml
      - name: Install user-service dependencies
        run: cd services/user-service && npm ci

      - name: Run user-service tests
        run: cd services/user-service && npm test

      - name: npm audit — user-service production deps (fail on high/critical CVEs)
        run: cd services/user-service && npm audit --audit-level=high --omit=dev
```

- [ ] **Step 4: Build, scan, and push the user-service image**

In the `build-and-push` job, after the existing "Push catalog-service image" step and before the "Frontend image" section, add:

```yaml
      # ── User service image ───────────────────────────────────────────────
      - name: Build user-service image (no push yet)
        uses: docker/build-push-action@10e90e3645eae34f1e60eeb005ba3a3d33f178e8  # v6
        with:
          context:   ./services/user-service
          push:      false
          load:      true
          tags:      ${{ env.ECR_REGISTRY }}/${{ env.USER_REPO }}:${{ steps.tag.outputs.tag }}
          cache-from: type=gha
          cache-to:   type=gha,mode=max

      - name: Trivy — scan user-service (CRITICAL + HIGH = hard fail)
        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25  # v0.36.0
        with:
          image-ref:      ${{ env.ECR_REGISTRY }}/${{ env.USER_REPO }}:${{ steps.tag.outputs.tag }}
          format:         sarif
          output:         trivy-user-service.sarif
          severity:       CRITICAL,HIGH
          exit-code:      "1"
          ignore-unfixed: true

      - name: Show user-service CVEs in CI log (diagnostic on failure)
        if: failure()
        run: |
          [ -f trivy-user-service.sarif ] && \
            jq -r '.runs[].results[] |
              "[" + (.level | ascii_upcase) + "] " + .ruleId +
              ": " + (.message.text | split("\n")[0])' \
            trivy-user-service.sarif \
          || echo "trivy-user-service.sarif not found"

      - name: Upload user-service Trivy SARIF to GitHub Security tab
        uses: github/codeql-action/upload-sarif@8aad20d150bbac5944a9f9d289da16a4b0d87c1e  # v4
        if: always()
        with:
          sarif_file: trivy-user-service.sarif
          category:   trivy-user-service

      - name: Push user-service image
        run: |
          docker push ${{ env.ECR_REGISTRY }}/${{ env.USER_REPO }}:${{ steps.tag.outputs.tag }}
```

- [ ] **Step 5: Bump the user-service image tag in the `deploy` job**

Edit the `deploy` job's "Update image tags in kustomization.yaml" step:

```yaml
      - name: Update image tags in kustomization.yaml
        env:
          TAG: ${{ needs.build-and-push.outputs.image-tag }}
        run: |
          cd k8s/overlays/prod
          kustomize edit set image \
            bookstore-backend=${{ env.ECR_REGISTRY }}/${{ env.BACKEND_REPO }}:${TAG}
          kustomize edit set image \
            bookstore-frontend=${{ env.ECR_REGISTRY }}/${{ env.FRONTEND_REPO }}:${TAG}
          cd ../../services/catalog-service/overlays/prod
          kustomize edit set image \
            bookstore-catalog-service=${{ env.ECR_REGISTRY }}/${{ env.CATALOG_REPO }}:${TAG}
          cd ../../user-service/overlays/prod
          kustomize edit set image \
            bookstore-user-service=${{ env.ECR_REGISTRY }}/${{ env.USER_REPO }}:${TAG}

      - name: Commit and push updated image tags
        env:
          TAG: ${{ needs.build-and-push.outputs.image-tag }}
        run: |
          git config user.email "ci-bot@github-actions"
          git config user.name "GitHub Actions"
          git add k8s/overlays/prod/kustomization.yaml \
                  k8s/services/catalog-service/overlays/prod/kustomization.yaml \
                  k8s/services/user-service/overlays/prod/kustomization.yaml
          git diff --staged --quiet && echo "No image tag changes." && exit 0
          git commit -m "chore: bump image tags to ${TAG}"
          git push
```

(Replaces the existing "Update image tags in kustomization.yaml" and "Commit and push updated image tags" steps.)

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/ci-cd.yml
git commit -m "ci: build/scan/push user-service image"
```

---

### Task 9: Manual verification (real `terraform apply`, real deploy, real curl)

No new files — this task exercises everything built above end-to-end.

- [ ] **Step 1: Apply the Terraform changes**

Run: `terraform plan -out=user-service.tfplan`
Review: should show the new `aws_ecr_repository.this["bookstore-user-service"]`, `aws_secretsmanager_secret.user_db_credentials` (+ version), `aws_secretsmanager_secret.jwt_secret` (+ version) — no changes to any existing resource.

Run: `terraform apply user-service.tfplan`
Expected: Apply completes with no errors.

- [ ] **Step 2: Push the new ApplicationSet element and let ArgoCD deploy user-service**

Run:
```bash
kubectl -n argocd annotate applicationset bookstore-microservices argocd.argoproj.io/refresh=hard --overwrite
kubectl get applications -n argocd
```
Expected: an `Application` named `user-service` appears, `SYNC STATUS` eventually reaches `Synced`, `HEALTH STATUS` reaches `Healthy`. If images haven't been pushed yet (Task 8's CI hasn't run against this commit), the Deployment will show `ImagePullBackOff` until an image lands in ECR — push once by hand if needed, same pattern as catalog-service's Plan 1 Task 9 Step 3.

- [ ] **Step 3: Confirm the schema-init hook ran**

```bash
kubectl get jobs -n user
kubectl logs job/user-schema-init -n user 2>/dev/null || echo "hook already cleaned up (HookSucceeded) — this is expected"
```
Expected: either the Job's logs show no MySQL errors, or (more likely, if you check after ArgoCD's `hook-delete-policy: BeforeHookCreation,HookSucceeded` already cleaned it up) the Job is simply gone — a sign it already succeeded. Confirm the schema exists by proceeding to Step 4.

- [ ] **Step 4: Curl the live service end-to-end (bypassing any gateway — none exists yet)**

```bash
kubectl port-forward -n user svc/user-service 8082:80
```
In another terminal:
```bash
curl -s http://localhost:8082/health

curl -s -X POST http://localhost:8082/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"verify@example.com","password":"hunter22"}'
# Expected: {"id":1,"email":"verify@example.com"}

TOKEN=$(curl -s -X POST http://localhost:8082/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"verify@example.com","password":"hunter22"}' | jq -r .token)
echo "$TOKEN"
# Expected: a JWT string (three base64url segments separated by dots)

curl -s http://localhost:8082/users/me -H "Authorization: Bearer $TOKEN"
# Expected: {"id":1,"email":"verify@example.com","created_at":"..."}

curl -s http://localhost:8082/users/me
# Expected: 401 {"error":"missing or invalid Authorization header"}

curl -s http://localhost:8082/metrics | grep 'service="user-service"' | head -5
```
Expected: every response matches the comments above; the `/metrics` output shows `http_requests_total`/`http_request_duration_seconds` samples labeled `service="user-service"`.

- [ ] **Step 5: Final commit — mark this plan's outcome**

No code changes at this step; if any fixes were needed during verification, commit those now with a clear message before moving to Plan 3.

---

## Plan Series Status

- [x] Design spec approved — `docs/superpowers/specs/2026-07-29-microservices-observability-design.md`
- [x] Plan 1 — catalog-service (live)
- [ ] **Plan 2 (this file) — user-service**
- [ ] Plan 3 — order-service (with cart/checkout) + notification-service
- [ ] Plan 4 — api-gateway (routing, JWT enforcement, traffic cutover, old `backend/` removal)
- [ ] Plan 5 — observability (EC2 Prometheus scrape config, Grafana dashboards, Alertmanager rules)

Each subsequent plan gets written just before it's executed, once this plan's actual output (file paths, secret names, service conventions) is confirmed on disk — not guessed in advance.
