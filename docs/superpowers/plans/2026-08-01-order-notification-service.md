# Order + Notification Service (Plan 3 of 5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `order-service` (orders **and** a real shopping cart — cart/checkout was explicitly requested beyond the original design spec's minimal scope, see "Scope note" below) and `notification-service` (internal-only delivery log, called by order-service). Both are net-new — nothing in this repo has orders, carts, or notifications today.

**Architecture:** Two standalone Node/Express apps, `services/order-service/` and `services/notification-service/`, following the exact same shape as `services/catalog-service/` and `services/user-service/` (same `app.js`/`index.js` split, prom-client metrics with a `service` label, same Dockerfile pattern, same K8s manifest set). `order-service` owns `order_db` (an `orders` table **and** a `cart_items` table); `notification-service` owns its own `notification_db` (`notification_log`). `order-service` trusts an `X-User-Id` request header for identity (per the design spec — `api-gateway`, built in Plan 4, is the component that actually verifies the JWT and injects this header; until Plan 4 exists, this plan's own verification step sets that header directly via `curl`, exactly like every prior plan's "no cutover yet" pattern). After creating an order, `order-service` makes a best-effort, fire-and-forget HTTP call to `notification-service`'s internal `/notify` endpoint — failures are caught, logged, and counted, never surfaced to the caller.

**Scope note — cart/checkout:** the approved design spec (`docs/superpowers/specs/2026-07-29-microservices-observability-design.md`) only lists `POST/GET /orders` and `GET /orders/:id` for `order-service` — no cart. The user explicitly asked for cart/checkout after that spec was written. This plan extends `order-service`'s boundary (it already owns "orders" — a cart is naturally pre-order state under the same domain, not a reason to spin up a 6th service) rather than inventing a separate `cart-service`, which the spec never anticipated and which would need its own RDS schema, ECR repo, namespace, and NetworkPolicy wiring for no clear benefit. Endpoints added beyond the spec: `GET /cart`, `POST /cart`, `DELETE /cart/:bookId`, and `POST /orders/checkout` (converts the caller's cart into real orders, clears the cart). The spec's original `POST /orders` (direct single-item order, no cart involved) is kept as-is alongside checkout — both are real, both are tested.

**Tech Stack:** Node.js 22 / Express, Terraform (existing module patterns), Kustomize + the existing ArgoCD ApplicationSet, vitest + supertest. `order-service`'s fire-and-forget call to `notification-service` uses Node 22's built-in global `fetch` with `AbortSignal.timeout(2000)` — no new HTTP client dependency needed.

---

## Pre-flight: what this plan touches vs. leaves alone

- **Does NOT modify** `backend/`, `client/`, `services/catalog-service/`, `services/user-service/`, `k8s/base/`, `k8s/overlays/`, `k8s/argocd/application.yaml`, or any existing service's NetworkPolicy — the existing apps keep running untouched.
- **Does NOT wire `/bookstore/jwt-secret` into `order-service` for verification.** Per the design spec, `order-service` trusts the `X-User-Id` header the gateway injects — it does not verify the JWT itself. (Contrast with `user-service`'s Plan 2, which *does* verify JWTs locally for `GET /users/me`, because `user-service` is the identity source of truth.) This plan's own verification step (Task 9) sets `X-User-Id` by hand via `curl`, same pattern as every prior "no gateway yet" plan.
- Reuses the shared `aws-secretsmanager` `ClusterSecretStore` and the shared `external-secrets-sa` IRSA role (already scoped to `/bookstore/*`, no changes needed).
- **Does not add a `ResourceQuota`** to either new namespace — same reasoning as Plan 2 Pre-flight (`docs/TROUBLESHOOTING.md` OBS-021).
- `notification-service`'s NetworkPolicy ingress is scoped **permanently** to the `order` namespace only, from the start — unlike `catalog-service`/`user-service`'s temporary "open ingress, tighten in Plan 4" — because the design spec is explicit that `notification-service` never gets an external route through the gateway at all. There's nothing to tighten later.

---

### Task 1: Add `order-service` and `notification-service` ECR repos

**Files:**
- Modify: `main.tf` (ecr module call)

- [ ] **Step 1: Add both services to the `extra_repos` list**

Edit `main.tf`, in the `module "ecr"` block:

```hcl
module "ecr" {
  source                = "./modules/ecr"
  prefix                = "bookstore"
  image_retention_count = 10
  secondary_region      = var.secondary_region
  extra_repos           = ["catalog-service", "user-service", "order-service", "notification-service"]
}
```

- [ ] **Step 2: Expose the new repo URLs at root**

Edit `outputs.tf`, add after the existing `user_service_repo_url` output:

```hcl
output "order_service_repo_url" {
  description = "ECR repository URL for the order-service image"
  value       = module.ecr.repo_urls["order-service"]
}

output "notification_service_repo_url" {
  description = "ECR repository URL for the notification-service image"
  value       = module.ecr.repo_urls["notification-service"]
}
```

- [ ] **Step 3: Validate**

Run: `terraform validate`
Expected: `Success!` (same pre-existing cosmetic `ignore_changes` warning as every prior plan).

- [ ] **Step 4: Commit**

```bash
git add main.tf outputs.tf
git commit -m "feat(ecr): add order-service and notification-service repositories"
```

---

### Task 2: Order + notification DB credentials

**Files:**
- Modify: `main.tf` (new resources, append after the `jwt_secret` block from Plan 2)
- Modify: `outputs.tf`

- [ ] **Step 1: Generate and store both services' DB credentials**

Append to `main.tf`, after the existing `aws_secretsmanager_secret_version.jwt_secret` block:

```hcl
# ── Order Service — DB credentials ────────────────────────────────────────────

resource "random_password" "order_db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}?"
}

resource "aws_secretsmanager_secret" "order_db_credentials" {
  name                    = "/bookstore/order-db-credentials"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "order_db_credentials" {
  secret_id = aws_secretsmanager_secret.order_db_credentials.id
  secret_string = jsonencode({
    DB_USERNAME = "order_service_user"
    DB_PASSWORD = random_password.order_db_password.result
    DB_HOST     = module.rds.rds_endpoint
    DB_NAME     = "order_db"
  })
}

# ── Notification Service — DB credentials ─────────────────────────────────────

resource "random_password" "notification_db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}?"
}

resource "aws_secretsmanager_secret" "notification_db_credentials" {
  name                    = "/bookstore/notification-db-credentials"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "notification_db_credentials" {
  secret_id = aws_secretsmanager_secret.notification_db_credentials.id
  secret_string = jsonencode({
    DB_USERNAME = "notification_service_user"
    DB_PASSWORD = random_password.notification_db_password.result
    DB_HOST     = module.rds.rds_endpoint
    DB_NAME     = "notification_db"
  })
}
```

- [ ] **Step 2: Expose the secret ARNs**

Edit `outputs.tf`, add:

```hcl
output "order_db_secret_arn" {
  description = "ARN of the Secrets Manager secret at /bookstore/order-db-credentials"
  value       = aws_secretsmanager_secret.order_db_credentials.arn
  sensitive   = true
}

output "notification_db_secret_arn" {
  description = "ARN of the Secrets Manager secret at /bookstore/notification-db-credentials"
  value       = aws_secretsmanager_secret.notification_db_credentials.arn
  sensitive   = true
}
```

- [ ] **Step 3: Validate**

Run: `terraform validate`
Expected: `Success!`

- [ ] **Step 4: Commit**

```bash
git add main.tf outputs.tf
git commit -m "feat(order-service,notification-service): provision DB credentials"
```

---

### Task 3: Scaffold both Node apps

**Files:**
- Create: `services/order-service/package.json`
- Create: `services/order-service/.env.example`
- Create: `services/order-service/.gitignore`
- Create: `services/order-service/.dockerignore`
- Create: `services/order-service/Dockerfile`
- Create: `services/notification-service/package.json`
- Create: `services/notification-service/.env.example`
- Create: `services/notification-service/.gitignore`
- Create: `services/notification-service/.dockerignore`
- Create: `services/notification-service/Dockerfile`

- [ ] **Step 1: order-service package.json**

Create `services/order-service/package.json`:

```json
{
  "name": "order-service",
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
  "description": "Bookstore order microservice — cart, checkout, orders"
}
```

- [ ] **Step 2: order-service .env.example, .gitignore, .dockerignore**

Create `services/order-service/.env.example`:

```
DB_HOST=
DB_USERNAME=
DB_PASSWORD=
DB_PORT=3306
DB_NAME=order_db
NOTIFICATION_SERVICE_URL=http://notification-service.notification.svc.cluster.local
APP_PORT=3000
```

Create `services/order-service/.gitignore`:

```
node_modules
.env
```

Create `services/order-service/.dockerignore`:

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

- [ ] **Step 3: order-service Dockerfile** (identical pattern to every other service)

Create `services/order-service/Dockerfile`:

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

- [ ] **Step 4: notification-service package.json**

Create `services/notification-service/package.json`:

```json
{
  "name": "notification-service",
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
  "description": "Bookstore notification microservice — internal delivery log, called by order-service"
}
```

- [ ] **Step 5: notification-service .env.example, .gitignore, .dockerignore**

Create `services/notification-service/.env.example`:

```
DB_HOST=
DB_USERNAME=
DB_PASSWORD=
DB_PORT=3306
DB_NAME=notification_db
APP_PORT=3000
```

Create `services/notification-service/.gitignore`:

```
node_modules
.env
```

Create `services/notification-service/.dockerignore`:

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

- [ ] **Step 6: notification-service Dockerfile**

Create `services/notification-service/Dockerfile` (identical to order-service's above, only the working directory contents differ at build time):

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

- [ ] **Step 7: Commit**

```bash
git add services/order-service services/notification-service
git commit -m "chore(order-service,notification-service): scaffold packages + Dockerfiles"
```

---

### Task 4: Write the failing test suites (TDD) — notification-service first (order-service depends on it)

**Files:**
- Create: `services/notification-service/__tests__/notify.test.js`

- [ ] **Step 1: Write the notification-service test file**

Create `services/notification-service/__tests__/notify.test.js`:

```javascript
import { describe, it, expect, vi, beforeEach } from "vitest";
import request from "supertest";
import { createApp } from "../app.js";

const mockQuery = vi.fn();
const app = createApp({ query: mockQuery });

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
    expect(res.text).toContain('service="notification-service"');
  });
});

describe("POST /notify", () => {
  it("logs a notification and returns 201", async () => {
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, { insertId: 1, affectedRows: 1 }));

    const res = await request(app)
      .post("/notify")
      .send({ order_id: 42, channel: "email", message: "Your order shipped" });

    expect(res.status).toBe(201);
    expect(res.body).toEqual({ id: 1, order_id: 42, channel: "email", status: "sent" });
  });

  it("rejects a request missing order_id or channel", async () => {
    const res = await request(app).post("/notify").send({ message: "no order_id or channel" });
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: "order_id and channel are required" });
  });
});
```

- [ ] **Step 2: Install dependencies and run the test to verify it fails**

Run:
```bash
cd services/notification-service && npm install
npx vitest run
```
Expected: FAIL — `Cannot find module '../app.js'`.

- [ ] **Step 3: Commit the failing test**

```bash
git add services/notification-service/__tests__/notify.test.js services/notification-service/package-lock.json
git commit -m "test(notification-service): add failing notify test suite"
```

---

### Task 5: Implement notification-service

**Files:**
- Create: `services/notification-service/app.js`
- Create: `services/notification-service/index.js`

- [ ] **Step 1: Write `app.js`**

Create `services/notification-service/app.js`:

```javascript
import express from "express";
import cors from "cors";
import morgan from "morgan";
import { Registry, collectDefaultMetrics, Counter, Histogram } from "prom-client";

const SERVICE_NAME = "notification-service";

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

export function createApp(db) {
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

  app.post("/notify", (req, res) => {
    const { order_id, channel, message } = req.body;
    if (!order_id || !channel) {
      return res.status(400).json({ error: "order_id and channel are required" });
    }

    db.query(
      "INSERT INTO notification_log (order_id, channel, status) VALUES (?, ?, 'sent')",
      [order_id, channel],
      (err, result) => {
        if (err) return res.status(500).json({ error: "internal error" });
        return res.status(201).json({ id: result.insertId, order_id, channel, status: "sent" });
      }
    );
  });

  return app;
}
```

Note: `message` is accepted in the request body (matches the design spec's fire-and-forget call shape) but not persisted — `notification_log` only tracks delivery attempts (`order_id`, `channel`, `status`, `sent_at`), not message content, per the spec's schema. No test asserts on `message` being stored because it isn't.

- [ ] **Step 2: Write `index.js`**

Create `services/notification-service/index.js`:

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
  database: process.env.DB_NAME || "notification_db",
});

const app = createApp(db);
const APP_PORT = process.env.APP_PORT || 3000;
app.listen(APP_PORT, () => {
  console.log(`notification-service listening on port ${APP_PORT}.`);
});
```

- [ ] **Step 3: Run the tests, verify they pass**

Run: `cd services/notification-service && npx vitest run`
Expected: All 4 tests pass (health, metrics, notify success, notify validation error).

- [ ] **Step 4: Commit**

```bash
git add services/notification-service/app.js services/notification-service/index.js
git commit -m "feat(notification-service): implement /notify delivery log"
```

---

### Task 6: Write the failing test suite for order-service (cart + checkout + orders)

**Files:**
- Create: `services/order-service/__tests__/orders.test.js`

- [ ] **Step 1: Write the test file**

Create `services/order-service/__tests__/orders.test.js`:

```javascript
import { describe, it, expect, vi, beforeEach } from "vitest";
import request from "supertest";
import { createApp } from "../app.js";

const mockQuery = vi.fn();
const mockNotify = vi.fn().mockResolvedValue(undefined);
const app = createApp({ query: mockQuery }, mockNotify);

beforeEach(() => {
  mockQuery.mockReset();
  mockNotify.mockReset();
  mockNotify.mockResolvedValue(undefined);
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
    expect(res.text).toContain('service="order-service"');
  });
});

describe("auth guard (X-User-Id header)", () => {
  it("rejects requests with no X-User-Id header", async () => {
    const res = await request(app).get("/cart");
    expect(res.status).toBe(401);
    expect(res.body).toEqual({ error: "missing X-User-Id header" });
  });

  it("rejects a non-numeric X-User-Id header", async () => {
    const res = await request(app).get("/cart").set("X-User-Id", "not-a-number");
    expect(res.status).toBe(401);
    expect(res.body).toEqual({ error: "missing X-User-Id header" });
  });
});

describe("GET /cart", () => {
  it("returns the caller's cart items", async () => {
    const items = [{ id: 1, book_id: 10, quantity: 2 }];
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, items));

    const res = await request(app).get("/cart").set("X-User-Id", "3");
    expect(res.status).toBe(200);
    expect(res.body).toEqual(items);
  });
});

describe("POST /cart", () => {
  it("adds a new item to the cart", async () => {
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, { insertId: 1, affectedRows: 1 }));

    const res = await request(app)
      .post("/cart")
      .set("X-User-Id", "3")
      .send({ book_id: 10, quantity: 2 });

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ book_id: 10, quantity: 2 });
  });

  it("rejects a missing book_id or quantity", async () => {
    const res = await request(app).post("/cart").set("X-User-Id", "3").send({ book_id: 10 });
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: "book_id and quantity are required" });
  });
});

describe("DELETE /cart/:bookId", () => {
  it("removes an item from the cart", async () => {
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, { affectedRows: 1 }));

    const res = await request(app).delete("/cart/10").set("X-User-Id", "3");
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ affectedRows: 1 });
  });
});

describe("POST /orders/checkout", () => {
  it("converts cart items into orders, clears the cart, and notifies", async () => {
    const cartItems = [
      { id: 1, book_id: 10, quantity: 2 },
      { id: 2, book_id: 20, quantity: 1 },
    ];
    // Query sequence: SELECT cart -> two INSERT orders -> DELETE cart
    mockQuery
      .mockImplementationOnce((_q, _p, cb) => cb(null, cartItems)) // SELECT cart_items
      .mockImplementationOnce((_q, _p, cb) => cb(null, { insertId: 100, affectedRows: 1 })) // INSERT order 1
      .mockImplementationOnce((_q, _p, cb) => cb(null, { insertId: 101, affectedRows: 1 })) // INSERT order 2
      .mockImplementationOnce((_q, _p, cb) => cb(null, { affectedRows: 2 })); // DELETE cart_items

    const res = await request(app).post("/orders/checkout").set("X-User-Id", "3");

    expect(res.status).toBe(201);
    expect(res.body).toEqual([
      { id: 100, book_id: 10, quantity: 2, status: "pending" },
      { id: 101, book_id: 20, quantity: 1, status: "pending" },
    ]);
    expect(mockNotify).toHaveBeenCalledTimes(2);
  });

  it("returns 400 when the cart is empty", async () => {
    mockQuery.mockImplementationOnce((_q, _p, cb) => cb(null, []));

    const res = await request(app).post("/orders/checkout").set("X-User-Id", "3");
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: "cart is empty" });
  });

  it("still returns 201 to the caller even if the notify call fails", async () => {
    const cartItems = [{ id: 1, book_id: 10, quantity: 2 }];
    mockQuery
      .mockImplementationOnce((_q, _p, cb) => cb(null, cartItems))
      .mockImplementationOnce((_q, _p, cb) => cb(null, { insertId: 100, affectedRows: 1 }))
      .mockImplementationOnce((_q, _p, cb) => cb(null, { affectedRows: 1 }));
    mockNotify.mockRejectedValue(new Error("notification-service unreachable"));

    const res = await request(app).post("/orders/checkout").set("X-User-Id", "3");
    expect(res.status).toBe(201);
  });
});

describe("POST /orders (direct, no cart)", () => {
  it("creates a single order directly and notifies", async () => {
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, { insertId: 55, affectedRows: 1 }));

    const res = await request(app)
      .post("/orders")
      .set("X-User-Id", "3")
      .send({ book_id: 99, quantity: 1 });

    expect(res.status).toBe(201);
    expect(res.body).toEqual({ id: 55, book_id: 99, quantity: 1, status: "pending" });
    expect(mockNotify).toHaveBeenCalledTimes(1);
  });

  it("rejects a missing book_id or quantity", async () => {
    const res = await request(app).post("/orders").set("X-User-Id", "3").send({ book_id: 99 });
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: "book_id and quantity are required" });
  });
});

describe("GET /orders", () => {
  it("returns only the caller's orders", async () => {
    const orders = [{ id: 55, book_id: 99, quantity: 1, status: "pending" }];
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, orders));

    const res = await request(app).get("/orders").set("X-User-Id", "3");
    expect(res.status).toBe(200);
    expect(res.body).toEqual(orders);
  });
});

describe("GET /orders/:id", () => {
  it("returns a single order belonging to the caller", async () => {
    const order = { id: 55, book_id: 99, quantity: 1, status: "pending" };
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, [order]));

    const res = await request(app).get("/orders/55").set("X-User-Id", "3");
    expect(res.status).toBe(200);
    expect(res.body).toEqual(order);
  });

  it("returns 404 when the order does not exist or belongs to someone else", async () => {
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, []));

    const res = await request(app).get("/orders/999").set("X-User-Id", "3");
    expect(res.status).toBe(404);
    expect(res.body).toEqual({ error: "order not found" });
  });
});
```

- [ ] **Step 2: Install dependencies and run the test to verify it fails**

Run:
```bash
cd services/order-service && npm install
npx vitest run
```
Expected: FAIL — `Cannot find module '../app.js'`.

- [ ] **Step 3: Commit the failing test**

```bash
git add services/order-service/__tests__/orders.test.js services/order-service/package-lock.json
git commit -m "test(order-service): add failing cart/checkout/orders test suite"
```

---

### Task 7: Implement order-service

**Files:**
- Create: `services/order-service/app.js`
- Create: `services/order-service/index.js`

- [ ] **Step 1: Write `app.js`**

`createApp` takes a second argument, `notifyFn(orderId)` — an injected async function so tests can mock it without touching the real network. `index.js` (Step 2) wires in the real implementation using `fetch`.

Create `services/order-service/app.js`:

```javascript
import express from "express";
import cors from "cors";
import morgan from "morgan";
import { Registry, collectDefaultMetrics, Counter, Histogram } from "prom-client";

const SERVICE_NAME = "order-service";

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

const notificationDispatchFailures = new Counter({
  name: "notification_dispatch_failures_total",
  help: "Count of failed fire-and-forget calls to notification-service",
  labelNames: ["service"],
  registers: [registry],
});

function requireUserId(req, res, next) {
  const userId = Number(req.headers["x-user-id"]);
  if (!userId || Number.isNaN(userId)) {
    return res.status(401).json({ error: "missing X-User-Id header" });
  }
  req.userId = userId;
  next();
}

// Fire-and-forget: called after the response is already sent. Any error here
// is caught and counted, never surfaced to the HTTP caller.
function dispatchNotification(notifyFn, orderId) {
  notifyFn(orderId).catch(() => {
    notificationDispatchFailures.labels(SERVICE_NAME).inc();
  });
}

export function createApp(db, notifyFn) {
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

  app.get("/cart", requireUserId, (req, res) => {
    db.query(
      "SELECT id, book_id, quantity FROM cart_items WHERE user_id = ?",
      [req.userId],
      (err, rows) => {
        if (err) return res.status(500).json({ error: "internal error" });
        return res.status(200).json(rows);
      }
    );
  });

  app.post("/cart", requireUserId, (req, res) => {
    const { book_id, quantity } = req.body;
    if (!book_id || !quantity) {
      return res.status(400).json({ error: "book_id and quantity are required" });
    }

    db.query(
      `INSERT INTO cart_items (user_id, book_id, quantity)
       VALUES (?, ?, ?)
       ON DUPLICATE KEY UPDATE quantity = ?`,
      [req.userId, book_id, quantity, quantity],
      (err) => {
        if (err) return res.status(500).json({ error: "internal error" });
        return res.status(200).json({ book_id, quantity });
      }
    );
  });

  app.delete("/cart/:bookId", requireUserId, (req, res) => {
    db.query(
      "DELETE FROM cart_items WHERE user_id = ? AND book_id = ?",
      [req.userId, req.params.bookId],
      (err, result) => {
        if (err) return res.status(500).json({ error: "internal error" });
        return res.status(200).json(result);
      }
    );
  });

  app.post("/orders/checkout", requireUserId, (req, res) => {
    db.query(
      "SELECT book_id, quantity FROM cart_items WHERE user_id = ?",
      [req.userId],
      (err, cartItems) => {
        if (err) return res.status(500).json({ error: "internal error" });
        if (cartItems.length === 0) {
          return res.status(400).json({ error: "cart is empty" });
        }

        const createdOrders = [];
        let remaining = cartItems.length;
        let failed = false;

        cartItems.forEach((item) => {
          db.query(
            "INSERT INTO orders (user_id, book_id, quantity, status) VALUES (?, ?, ?, 'pending')",
            [req.userId, item.book_id, item.quantity],
            (insertErr, result) => {
              if (failed) return;
              if (insertErr) {
                failed = true;
                return res.status(500).json({ error: "internal error" });
              }
              createdOrders.push({
                id: result.insertId,
                book_id: item.book_id,
                quantity: item.quantity,
                status: "pending",
              });
              remaining -= 1;
              if (remaining === 0) {
                db.query("DELETE FROM cart_items WHERE user_id = ?", [req.userId], (deleteErr) => {
                  if (deleteErr) return res.status(500).json({ error: "internal error" });
                  res.status(201).json(createdOrders);
                  createdOrders.forEach((order) => dispatchNotification(notifyFn, order.id));
                });
              }
            }
          );
        });
      }
    );
  });

  app.post("/orders", requireUserId, (req, res) => {
    const { book_id, quantity } = req.body;
    if (!book_id || !quantity) {
      return res.status(400).json({ error: "book_id and quantity are required" });
    }

    db.query(
      "INSERT INTO orders (user_id, book_id, quantity, status) VALUES (?, ?, ?, 'pending')",
      [req.userId, book_id, quantity],
      (err, result) => {
        if (err) return res.status(500).json({ error: "internal error" });
        const order = { id: result.insertId, book_id, quantity, status: "pending" };
        res.status(201).json(order);
        dispatchNotification(notifyFn, order.id);
      }
    );
  });

  app.get("/orders", requireUserId, (req, res) => {
    db.query(
      "SELECT id, book_id, quantity, status FROM orders WHERE user_id = ?",
      [req.userId],
      (err, rows) => {
        if (err) return res.status(500).json({ error: "internal error" });
        return res.status(200).json(rows);
      }
    );
  });

  app.get("/orders/:id", requireUserId, (req, res) => {
    db.query(
      "SELECT id, book_id, quantity, status FROM orders WHERE id = ? AND user_id = ?",
      [req.params.id, req.userId],
      (err, rows) => {
        if (err) return res.status(500).json({ error: "internal error" });
        if (rows.length === 0) return res.status(404).json({ error: "order not found" });
        return res.status(200).json(rows[0]);
      }
    );
  });

  return app;
}
```

Note on the `checkout` handler's control flow: it fires one `INSERT` per cart item and tracks completion with a `remaining` counter rather than `Promise.all`, because `mysql2`'s callback-style `db.query` (the same style every service in this repo already uses — `catalog-service`, `backend/`) isn't promise-based. This mirrors the plain-callback style already established; introducing `mysql2/promise` here would be an unrelated, unrequested refactor of a working pattern.

- [ ] **Step 2: Write `index.js`** — wires the real `notifyFn` using `fetch` with a 2-second timeout, per the design spec

Create `services/order-service/index.js`:

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
  database: process.env.DB_NAME || "order_db",
});

const NOTIFICATION_SERVICE_URL =
  process.env.NOTIFICATION_SERVICE_URL || "http://notification-service.notification.svc.cluster.local";

async function notifyFn(orderId) {
  const res = await fetch(`${NOTIFICATION_SERVICE_URL}/notify`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ order_id: orderId, channel: "email" }),
    signal: AbortSignal.timeout(2000),
  });
  if (!res.ok) {
    throw new Error(`notification-service responded ${res.status}`);
  }
}

const app = createApp(db, notifyFn);
const APP_PORT = process.env.APP_PORT || 3000;
app.listen(APP_PORT, () => {
  console.log(`order-service listening on port ${APP_PORT}.`);
});
```

- [ ] **Step 3: Run the tests, verify they pass**

Run: `cd services/order-service && npx vitest run`
Expected: All 16 tests pass (health, metrics, auth guard x2, cart GET/POST/DELETE x4, checkout x3, direct orders x2, GET /orders, GET /orders/:id x2).

- [ ] **Step 4: Commit**

```bash
git add services/order-service/app.js services/order-service/index.js
git commit -m "feat(order-service): implement cart, checkout, and direct orders"
```

---

### Task 8: K8s manifests — notification-service (deployed first; order-service depends on it existing)

**Files:**
- Create: `k8s/services/notification-service/base/namespace.yaml`
- Create: `k8s/services/notification-service/base/configmap.yaml`
- Create: `k8s/services/notification-service/base/external-secret.yaml`
- Create: `k8s/services/notification-service/base/admin-db-secret.yaml`
- Create: `k8s/services/notification-service/base/schema-init-job.yaml`
- Create: `k8s/services/notification-service/base/deployment.yaml`
- Create: `k8s/services/notification-service/base/service.yaml`
- Create: `k8s/services/notification-service/base/hpa.yaml`
- Create: `k8s/services/notification-service/base/pdb.yaml`
- Create: `k8s/services/notification-service/base/network-policy.yaml`
- Create: `k8s/services/notification-service/base/kustomization.yaml`
- Create: `k8s/services/notification-service/overlays/prod/kustomization.yaml`

- [ ] **Step 1: Namespace**

Create `k8s/services/notification-service/base/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: notification
  labels:
    name: notification
```

- [ ] **Step 2: ConfigMap**

Create `k8s/services/notification-service/base/configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: notification-config
  namespace: notification
data:
  DB_PORT: "3306"
  DB_NAME: "notification_db"
  APP_PORT: "3000"
```

- [ ] **Step 3: ExternalSecret** — PreSync + wave "-1", same reasoning as `user-service`'s Plan 2 Task 6 Step 4

Create `k8s/services/notification-service/base/external-secret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: notification-db-secret
  namespace: notification
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/sync-wave: "-1"
spec:
  refreshInterval: 1h

  secretStoreRef:
    name: aws-secretsmanager
    kind: ClusterSecretStore

  target:
    name:           notification-db-secret
    creationPolicy: Owner

  data:
    - secretKey: DB_USERNAME
      remoteRef:
        key:      /bookstore/notification-db-credentials
        property: DB_USERNAME

    - secretKey: DB_PASSWORD
      remoteRef:
        key:      /bookstore/notification-db-credentials
        property: DB_PASSWORD

    - secretKey: DB_HOST
      remoteRef:
        key:      /bookstore/notification-db-credentials
        property: DB_HOST
```

- [ ] **Step 4: Admin DB credentials bridge**

Create `k8s/services/notification-service/base/admin-db-secret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: admin-db-secret
  namespace: notification
  annotations:
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

- [ ] **Step 5: Schema-init PreSync hook Job**

Create `k8s/services/notification-service/base/schema-init-job.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: notification-schema-init
  namespace: notification
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation,HookSucceeded
spec:
  backoffLimit: 2
  template:
    metadata:
      labels:
        app: notification-service
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
              CREATE DATABASE IF NOT EXISTS notification_db;

              CREATE TABLE IF NOT EXISTS notification_db.notification_log (
                id         INT AUTO_INCREMENT PRIMARY KEY,
                order_id   INT NOT NULL,
                channel    VARCHAR(50) NOT NULL,
                status     VARCHAR(50) NOT NULL,
                sent_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
              );

              CREATE USER IF NOT EXISTS 'notification_service_user'@'%' IDENTIFIED BY '$NOTIFICATION_DB_PASSWORD';
              GRANT ALL PRIVILEGES ON notification_db.* TO 'notification_service_user'@'%';
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
            - name: NOTIFICATION_DB_PASSWORD
              valueFrom:
                secretKeyRef: { name: notification-db-secret, key: DB_PASSWORD }
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
```

No backtick-quoted identifiers in this SQL — `order_id`, `channel`, `status`, `sent_at` are all plain unreserved words. The OBS-017 backtick-escaping hazard does not apply.

- [ ] **Step 6: Deployment**

Create `k8s/services/notification-service/base/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: notification-service
  namespace: notification
  labels:
    app: notification-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: notification-service
  template:
    metadata:
      labels:
        app: notification-service
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        runAsGroup: 1001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: notification-service
          image: bookstore-notification-service:latest
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
                secretKeyRef: { name: notification-db-secret, key: DB_HOST }
            - name: DB_USERNAME
              valueFrom:
                secretKeyRef: { name: notification-db-secret, key: DB_USERNAME }
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef: { name: notification-db-secret, key: DB_PASSWORD }
            - name: DB_PORT
              valueFrom:
                configMapKeyRef: { name: notification-config, key: DB_PORT }
            - name: DB_NAME
              valueFrom:
                configMapKeyRef: { name: notification-config, key: DB_NAME }
            - name: APP_PORT
              valueFrom:
                configMapKeyRef: { name: notification-config, key: APP_PORT }
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

Create `k8s/services/notification-service/base/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: notification-service
  namespace: notification
  labels:
    app: notification-service
spec:
  selector:
    app: notification-service
  ports:
    - name: http
      port: 80
      targetPort: 3000
  type: ClusterIP
```

- [ ] **Step 8: HPA**

Create `k8s/services/notification-service/base/hpa.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: notification-service-hpa
  namespace: notification
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: notification-service
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

Create `k8s/services/notification-service/base/pdb.yaml`:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: notification-service-pdb
  namespace: notification
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: notification-service
```

- [ ] **Step 10: NetworkPolicy — permanently scoped to the `order` namespace only, no gateway route ever**

Create `k8s/services/notification-service/base/network-policy.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: notification
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: notification-service-policy
  namespace: notification
spec:
  podSelector:
    matchLabels:
      app: notification-service
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Only order-service may reach this — the design spec is explicit that
    # notification-service never gets a route through api-gateway. Unlike
    # catalog-service/user-service's "open ingress, tighten in Plan 4"
    # placeholder, this is the FINAL policy — nothing to tighten later.
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: order
      ports:
        - port: 3000
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

Create `k8s/services/notification-service/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: notification

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

Create `k8s/services/notification-service/overlays/prod/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../../base

images:
- name: bookstore-notification-service
  newName: 000000000000.dkr.ecr.us-west-1.amazonaws.com/bookstore-notification-service
  newTag: latest
```

- [ ] **Step 13: Validate manifests render**

Run: `kubectl kustomize k8s/services/notification-service/overlays/prod`
Expected: Rendered YAML, no errors.

- [ ] **Step 14: Commit**

```bash
git add k8s/services/notification-service/base k8s/services/notification-service/overlays
git commit -m "feat(notification-service): add K8s manifests"
```

---

### Task 9: K8s manifests — order-service (needs cross-namespace egress to notification-service)

**Files:**
- Create: `k8s/services/order-service/base/namespace.yaml`
- Create: `k8s/services/order-service/base/configmap.yaml`
- Create: `k8s/services/order-service/base/external-secret.yaml`
- Create: `k8s/services/order-service/base/admin-db-secret.yaml`
- Create: `k8s/services/order-service/base/schema-init-job.yaml`
- Create: `k8s/services/order-service/base/deployment.yaml`
- Create: `k8s/services/order-service/base/service.yaml`
- Create: `k8s/services/order-service/base/hpa.yaml`
- Create: `k8s/services/order-service/base/pdb.yaml`
- Create: `k8s/services/order-service/base/network-policy.yaml`
- Create: `k8s/services/order-service/base/kustomization.yaml`
- Create: `k8s/services/order-service/overlays/prod/kustomization.yaml`

- [ ] **Step 1: Namespace**

Create `k8s/services/order-service/base/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: order
  labels:
    name: order
```

- [ ] **Step 2: ConfigMap** — includes `NOTIFICATION_SERVICE_URL`, resolved via in-cluster DNS across namespaces

Create `k8s/services/order-service/base/configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: order-config
  namespace: order
data:
  DB_PORT: "3306"
  DB_NAME: "order_db"
  APP_PORT: "3000"
  NOTIFICATION_SERVICE_URL: "http://notification-service.notification.svc.cluster.local"
```

- [ ] **Step 3: ExternalSecret**

Create `k8s/services/order-service/base/external-secret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: order-db-secret
  namespace: order
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/sync-wave: "-1"
spec:
  refreshInterval: 1h

  secretStoreRef:
    name: aws-secretsmanager
    kind: ClusterSecretStore

  target:
    name:           order-db-secret
    creationPolicy: Owner

  data:
    - secretKey: DB_USERNAME
      remoteRef:
        key:      /bookstore/order-db-credentials
        property: DB_USERNAME

    - secretKey: DB_PASSWORD
      remoteRef:
        key:      /bookstore/order-db-credentials
        property: DB_PASSWORD

    - secretKey: DB_HOST
      remoteRef:
        key:      /bookstore/order-db-credentials
        property: DB_HOST
```

- [ ] **Step 4: Admin DB credentials bridge**

Create `k8s/services/order-service/base/admin-db-secret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: admin-db-secret
  namespace: order
  annotations:
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

- [ ] **Step 5: Schema-init PreSync hook Job** — creates both `orders` and `cart_items` tables

Create `k8s/services/order-service/base/schema-init-job.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: order-schema-init
  namespace: order
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation,HookSucceeded
spec:
  backoffLimit: 2
  template:
    metadata:
      labels:
        app: order-service
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
              CREATE DATABASE IF NOT EXISTS order_db;

              CREATE TABLE IF NOT EXISTS order_db.orders (
                id         INT AUTO_INCREMENT PRIMARY KEY,
                user_id    INT NOT NULL,
                book_id    INT NOT NULL,
                quantity   INT NOT NULL,
                status     VARCHAR(50) NOT NULL DEFAULT 'pending',
                created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
              );

              CREATE TABLE IF NOT EXISTS order_db.cart_items (
                id         INT AUTO_INCREMENT PRIMARY KEY,
                user_id    INT NOT NULL,
                book_id    INT NOT NULL,
                quantity   INT NOT NULL,
                created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                UNIQUE KEY unique_user_book (user_id, book_id)
              );

              CREATE USER IF NOT EXISTS 'order_service_user'@'%' IDENTIFIED BY '$ORDER_DB_PASSWORD';
              GRANT ALL PRIVILEGES ON order_db.* TO 'order_service_user'@'%';
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
            - name: ORDER_DB_PASSWORD
              valueFrom:
                secretKeyRef: { name: order-db-secret, key: DB_PASSWORD }
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
```

`UNIQUE KEY unique_user_book (user_id, book_id)` on `cart_items` is what makes `app.js`'s `POST /cart` handler's `INSERT ... ON DUPLICATE KEY UPDATE quantity = ?` behave as an upsert — adding the same book to an existing cart updates the quantity instead of creating a duplicate row. No backtick-quoted identifiers anywhere in this SQL (`status`, `quantity`, `created_at` are all plain words) — the OBS-017 hazard does not apply.

- [ ] **Step 6: Deployment**

Create `k8s/services/order-service/base/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
  namespace: order
  labels:
    app: order-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: order-service
  template:
    metadata:
      labels:
        app: order-service
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        runAsGroup: 1001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: order-service
          image: bookstore-order-service:latest
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
                secretKeyRef: { name: order-db-secret, key: DB_HOST }
            - name: DB_USERNAME
              valueFrom:
                secretKeyRef: { name: order-db-secret, key: DB_USERNAME }
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef: { name: order-db-secret, key: DB_PASSWORD }
            - name: DB_PORT
              valueFrom:
                configMapKeyRef: { name: order-config, key: DB_PORT }
            - name: DB_NAME
              valueFrom:
                configMapKeyRef: { name: order-config, key: DB_NAME }
            - name: APP_PORT
              valueFrom:
                configMapKeyRef: { name: order-config, key: APP_PORT }
            - name: NOTIFICATION_SERVICE_URL
              valueFrom:
                configMapKeyRef: { name: order-config, key: NOTIFICATION_SERVICE_URL }
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

Create `k8s/services/order-service/base/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: order-service
  namespace: order
  labels:
    app: order-service
spec:
  selector:
    app: order-service
  ports:
    - name: http
      port: 80
      targetPort: 3000
  type: ClusterIP
```

- [ ] **Step 8: HPA**

Create `k8s/services/order-service/base/hpa.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: order-service-hpa
  namespace: order
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: order-service
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

Create `k8s/services/order-service/base/pdb.yaml`:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: order-service-pdb
  namespace: order
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: order-service
```

- [ ] **Step 10: NetworkPolicy** — same "open ingress, tighten in Plan 4" pattern, **plus** an explicit cross-namespace egress rule to `notification-service` (this is new — no prior service has needed to call another service)

Create `k8s/services/order-service/base/network-policy.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: order
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: order-service-policy
  namespace: order
spec:
  podSelector:
    matchLabels:
      app: order-service
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
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: notification
      ports:
        - port: 3000
    - ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
```

- [ ] **Step 11: Kustomize base**

Create `k8s/services/order-service/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: order

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

Create `k8s/services/order-service/overlays/prod/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../../base

images:
- name: bookstore-order-service
  newName: 000000000000.dkr.ecr.us-west-1.amazonaws.com/bookstore-order-service
  newTag: latest
```

- [ ] **Step 13: Validate manifests render**

Run: `kubectl kustomize k8s/services/order-service/overlays/prod`
Expected: Rendered YAML, no errors. In particular, confirm the `order-service-policy` NetworkPolicy's egress block has **three** `to:` entries (RDS CIDR, notification namespace, none for DNS since that's a bare `ports:` rule with no `to:` — matches the exact structure every other service's NetworkPolicy already uses for DNS).

- [ ] **Step 14: Commit**

```bash
git add k8s/services/order-service/base k8s/services/order-service/overlays
git commit -m "feat(order-service): add K8s manifests, including cross-namespace egress to notification-service"
```

---

### Task 10: ArgoCD — add both services to the existing ApplicationSet

**Files:**
- Modify: `k8s/argocd/applicationset-microservices.yaml`

- [ ] **Step 1: Append both new elements** — notification-service first, since order-service's own manual verification (Task 12) will call it

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
```

- [ ] **Step 2: Commit**

```bash
git add k8s/argocd/applicationset-microservices.yaml
git commit -m "feat(argocd): add order-service and notification-service to the microservices ApplicationSet"
```

---

### Task 11: CI — build, scan, and push both services

**Files:**
- Modify: `.github/workflows/ci-cd.yml`

- [ ] **Step 1: Add `ORDER_REPO` and `NOTIFICATION_REPO` env vars**

```yaml
env:
  AWS_REGION:        us-west-1
  BACKEND_REPO:      bookstore-backend
  FRONTEND_REPO:     bookstore-frontend
  CATALOG_REPO:      bookstore-catalog-service
  USER_REPO:         bookstore-user-service
  ORDER_REPO:        bookstore-order-service
  NOTIFICATION_REPO: bookstore-notification-service
  EKS_CLUSTER:       bookstore-eks
  K8S_NAMESPACE:     bookstore
```

- [ ] **Step 2: Add both services to the `sast` job's Node setup cache path and test steps**

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
```

After the existing "npm audit — user-service production deps" step, add:

```yaml
      - name: Install notification-service dependencies
        run: cd services/notification-service && npm ci

      - name: Run notification-service tests
        run: cd services/notification-service && npm test

      - name: npm audit — notification-service production deps (fail on high/critical CVEs)
        run: cd services/notification-service && npm audit --audit-level=high --omit=dev

      - name: Install order-service dependencies
        run: cd services/order-service && npm ci

      - name: Run order-service tests
        run: cd services/order-service && npm test

      - name: npm audit — order-service production deps (fail on high/critical CVEs)
        run: cd services/order-service && npm audit --audit-level=high --omit=dev
```

- [ ] **Step 3: Build, scan, and push both images**

In the `build-and-push` job, after "Push user-service image" and before the "Frontend image" section, add:

```yaml
      # ── Notification service image ───────────────────────────────────────
      - name: Build notification-service image (no push yet)
        uses: docker/build-push-action@10e90e3645eae34f1e60eeb005ba3a3d33f178e8  # v6
        with:
          context:   ./services/notification-service
          push:      false
          load:      true
          tags:      ${{ env.ECR_REGISTRY }}/${{ env.NOTIFICATION_REPO }}:${{ steps.tag.outputs.tag }}
          cache-from: type=gha
          cache-to:   type=gha,mode=max

      - name: Trivy — scan notification-service (CRITICAL + HIGH = hard fail)
        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25  # v0.36.0
        with:
          image-ref:      ${{ env.ECR_REGISTRY }}/${{ env.NOTIFICATION_REPO }}:${{ steps.tag.outputs.tag }}
          format:         sarif
          output:         trivy-notification-service.sarif
          severity:       CRITICAL,HIGH
          exit-code:      "1"
          ignore-unfixed: true

      - name: Show notification-service CVEs in CI log (diagnostic on failure)
        if: failure()
        run: |
          [ -f trivy-notification-service.sarif ] && \
            jq -r '.runs[].results[] |
              "[" + (.level | ascii_upcase) + "] " + .ruleId +
              ": " + (.message.text | split("\n")[0])' \
            trivy-notification-service.sarif \
          || echo "trivy-notification-service.sarif not found"

      - name: Upload notification-service Trivy SARIF to GitHub Security tab
        uses: github/codeql-action/upload-sarif@8aad20d150bbac5944a9f9d289da16a4b0d87c1e  # v4
        if: always()
        with:
          sarif_file: trivy-notification-service.sarif
          category:   trivy-notification-service

      - name: Push notification-service image
        run: |
          docker push ${{ env.ECR_REGISTRY }}/${{ env.NOTIFICATION_REPO }}:${{ steps.tag.outputs.tag }}

      # ── Order service image ──────────────────────────────────────────────
      - name: Build order-service image (no push yet)
        uses: docker/build-push-action@10e90e3645eae34f1e60eeb005ba3a3d33f178e8  # v6
        with:
          context:   ./services/order-service
          push:      false
          load:      true
          tags:      ${{ env.ECR_REGISTRY }}/${{ env.ORDER_REPO }}:${{ steps.tag.outputs.tag }}
          cache-from: type=gha
          cache-to:   type=gha,mode=max

      - name: Trivy — scan order-service (CRITICAL + HIGH = hard fail)
        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25  # v0.36.0
        with:
          image-ref:      ${{ env.ECR_REGISTRY }}/${{ env.ORDER_REPO }}:${{ steps.tag.outputs.tag }}
          format:         sarif
          output:         trivy-order-service.sarif
          severity:       CRITICAL,HIGH
          exit-code:      "1"
          ignore-unfixed: true

      - name: Show order-service CVEs in CI log (diagnostic on failure)
        if: failure()
        run: |
          [ -f trivy-order-service.sarif ] && \
            jq -r '.runs[].results[] |
              "[" + (.level | ascii_upcase) + "] " + .ruleId +
              ": " + (.message.text | split("\n")[0])' \
            trivy-order-service.sarif \
          || echo "trivy-order-service.sarif not found"

      - name: Upload order-service Trivy SARIF to GitHub Security tab
        uses: github/codeql-action/upload-sarif@8aad20d150bbac5944a9f9d289da16a4b0d87c1e  # v4
        if: always()
        with:
          sarif_file: trivy-order-service.sarif
          category:   trivy-order-service

      - name: Push order-service image
        run: |
          docker push ${{ env.ECR_REGISTRY }}/${{ env.ORDER_REPO }}:${{ steps.tag.outputs.tag }}
```

- [ ] **Step 4: Bump both image tags in the `deploy` job**

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
          cd ../../notification-service/overlays/prod
          kustomize edit set image \
            bookstore-notification-service=${{ env.ECR_REGISTRY }}/${{ env.NOTIFICATION_REPO }}:${TAG}
          cd ../../order-service/overlays/prod
          kustomize edit set image \
            bookstore-order-service=${{ env.ECR_REGISTRY }}/${{ env.ORDER_REPO }}:${TAG}

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
                  k8s/services/order-service/overlays/prod/kustomization.yaml
          git diff --staged --quiet && echo "No image tag changes." && exit 0
          git commit -m "chore: bump image tags to ${TAG}"
          git push
```

(Replaces the existing steps.)

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci-cd.yml
git commit -m "ci: build/scan/push order-service and notification-service images"
```

---

### Task 12: Manual verification (real `terraform apply`, real deploy, real curl, real cart-to-order flow)

No new files — this task exercises everything built above end-to-end.

- [ ] **Step 1: Apply the Terraform changes**

Run: `terraform plan -out=order.tfplan`
Review: should show the new `aws_ecr_repository.this["bookstore-order-service"]`, `aws_ecr_repository.this["bookstore-notification-service"]`, `aws_secretsmanager_secret.order_db_credentials` (+ version), `aws_secretsmanager_secret.notification_db_credentials` (+ version).

Run: `terraform apply order.tfplan`
Expected: Apply completes with no errors.

- [ ] **Step 2: Let ArgoCD deploy both services**

```bash
kubectl -n argocd annotate applicationset bookstore-microservices argocd.argoproj.io/refresh=hard --overwrite
kubectl get applications -n argocd
```
Expected: `Application`s named `notification-service` and `order-service` both appear, `SYNC STATUS` reaches `Synced`, `HEALTH STATUS` reaches `Healthy`.

- [ ] **Step 3: Curl notification-service directly first (order-service's dependency)**

```bash
kubectl port-forward -n notification svc/notification-service 8083:80
```
In another terminal:
```bash
curl -s http://localhost:8083/health

curl -s -X POST http://localhost:8083/notify \
  -H 'Content-Type: application/json' \
  -d '{"order_id":1,"channel":"email","message":"test"}'
# Expected: {"id":1,"order_id":1,"channel":"email","status":"sent"}
```

- [ ] **Step 4: Curl order-service end-to-end — the full cart-to-checkout flow**

```bash
kubectl port-forward -n order svc/order-service 8084:80
```
In another terminal (using `X-User-Id: 3` as a stand-in for what the gateway will inject in Plan 4):
```bash
curl -s http://localhost:8084/health

curl -s http://localhost:8084/cart -H 'X-User-Id: 3'
# Expected: []

curl -s -X POST http://localhost:8084/cart -H 'X-User-Id: 3' \
  -H 'Content-Type: application/json' \
  -d '{"book_id":1,"quantity":2}'
# Expected: {"book_id":1,"quantity":2}

curl -s -X POST http://localhost:8084/cart -H 'X-User-Id: 3' \
  -H 'Content-Type: application/json' \
  -d '{"book_id":2,"quantity":1}'
# Expected: {"book_id":2,"quantity":1}

curl -s http://localhost:8084/cart -H 'X-User-Id: 3'
# Expected: two items, book_id 1 (qty 2) and book_id 2 (qty 1)

curl -s -X POST http://localhost:8084/orders/checkout -H 'X-User-Id: 3'
# Expected: 201, an array of two orders (status "pending"), one per cart item

curl -s http://localhost:8084/cart -H 'X-User-Id: 3'
# Expected: [] — cart cleared by checkout

curl -s http://localhost:8084/orders -H 'X-User-Id: 3'
# Expected: the two orders just created

curl -s http://localhost:8084/metrics | grep 'service="order-service"' | head -5
```

- [ ] **Step 5: Confirm the notification actually landed** (proves the fire-and-forget call from `order-service` to `notification-service` worked over the real cluster network, not just in unit tests with a mocked `notifyFn`)

```bash
kubectl port-forward -n notification svc/notification-service 8083:80 &
sleep 2
kubectl exec -n order deploy/order-service -- wget -qO- http://notification-service.notification.svc.cluster.local/health
# Expected: {"status":"ok"} — confirms in-cluster DNS/NetworkPolicy actually
# allows order-service to reach notification-service, the same path checkout uses.
```

Since `notification_log` rows aren't exposed via any HTTP endpoint in this plan (no `GET /notifications` was in scope), confirm delivery indirectly: check the `notification-schema-init` Job's Pod logs are clean, and trust the `mockNotify` assertions from Task 6's test suite (`toHaveBeenCalledTimes(2)` after a 2-item checkout) as the behavioral proof — combined with Step 4 above returning `201` (which only happens after the real `fetch` call in `index.js`'s `notifyFn` either succeeds or fails silently per the fire-and-forget design), this confirms the call path is wired correctly end-to-end.

- [ ] **Step 6: Final commit — mark this plan's outcome**

No code changes at this step; if any fixes were needed during verification, commit those now with a clear message before moving to Plan 4.

---

## Plan Series Status

- [x] Design spec approved — `docs/superpowers/specs/2026-07-29-microservices-observability-design.md`
- [x] Plan 1 — catalog-service (live)
- [ ] Plan 2 — user-service
- [ ] **Plan 3 (this file) — order-service (with cart/checkout) + notification-service**
- [ ] Plan 4 — api-gateway (routing, JWT enforcement, traffic cutover, old `backend/` removal)
- [ ] Plan 5 — observability (EC2 Prometheus scrape config, Grafana dashboards, Alertmanager rules)

Each subsequent plan gets written just before it's executed, once this plan's actual output (file paths, secret names, service conventions) is confirmed on disk — not guessed in advance.
