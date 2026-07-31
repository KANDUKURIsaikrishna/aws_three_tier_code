# Catalog Service (Plan 1 of 5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract books CRUD out of the monolithic `backend/` into a standalone, independently-deployed `catalog-service`, with its own ECR repo, DB schema/user, K8s namespace, and ArgoCD-managed deployment — while fixing a pre-existing gap that would otherwise silently break every ExternalSecret in the cluster.

**Architecture:** `catalog-service` is a straight port of `backend/app.js`'s books routes into its own Node/Express app under `services/catalog-service/`, with a `service="catalog-service"` label added to its Prometheus metrics. It gets its own MySQL schema (`catalog_db`) and DB user inside the existing RDS instance, its own ECR repo, and its own K8s namespace (`catalog`) deployed via a new ArgoCD `ApplicationSet`. Traffic does **not** cut over yet — `backend/` keeps serving the live app; this plan proves the pattern standalone (verified via port-forward/curl), not via the public ingress. The old `backend/` deletion and public cutover happen in Plan 4 (api-gateway), per [`docs/superpowers/specs/2026-07-29-microservices-observability-design.md`](../specs/2026-07-29-microservices-observability-design.md).

**Tech Stack:** Node.js 22 / Express (matches `backend/`), Terraform (existing module patterns), Kustomize + ArgoCD ApplicationSet, vitest + supertest.

---

## Pre-flight: what this plan touches vs. leaves alone

- **Does NOT modify** `backend/`, `client/`, `k8s/base/`, `k8s/overlays/`, or `k8s/argocd/application.yaml` — the existing app keeps running untouched.
- **Fixes** a real pre-existing bug: `modules/eks-addons/external-secrets.tf` installs the External Secrets Operator via Helm but never creates an IRSA role or names/annotates its ServiceAccount, even though `k8s/base/secrets/external-secret.yaml` already references a `ClusterSecretStore` expecting a ServiceAccount named `external-secrets-sa` with IRSA auth. Without this fix, **no** ExternalSecret in the cluster — old or new — can actually pull from Secrets Manager. This plan fixes it once, cluster-wide, benefiting the existing `db-secret` too.
- Every future microservice plan (2-5) reuses the same shared `external-secrets-sa` IRSA role (scoped to `/bookstore/*`) — no new IRSA role needed per service, just a new Secrets Manager entry + ExternalSecret. This is a deliberate simplification vs. the spec's "per-service IRSA" line: true per-service isolation would need per-service `SecretStore`s, which is disproportionate complexity given the spec's own non-goals already defer full DB isolation.

---

### Task 0: Fix External Secrets Operator IRSA wiring

**Files:**
- Modify: `modules/eks-addons/variables.tf`
- Modify: `modules/eks-addons/external-secrets.tf`
- Modify: `main.tf:130-137` (eks_addons module call)

- [ ] **Step 1: Add `oidc_provider_url` and `aws_region` variables to the eks-addons module**

Edit `modules/eks-addons/variables.tf`, add after the existing `node_role_name` variable:

```hcl
variable "oidc_provider_url" {
  description = "URL of the EKS cluster OIDC provider, WITH the https:// scheme — stripped via replace() at point of use in IRSA trust policy conditions"
  type        = string
}

variable "aws_region" {
  description = "AWS region — used to scope the external-secrets IRSA policy to this account/region"
  type        = string
}
```

- [ ] **Step 2: Add the IRSA role + policy, and wire the Helm release to use it**

Replace the full contents of `modules/eks-addons/external-secrets.tf` with:

```hcl
data "aws_caller_identity" "eks_addons" {}

data "aws_iam_policy_document" "external_secrets_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = "bookstore-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.external_secrets_trust.json
}

resource "aws_iam_role_policy" "external_secrets" {
  name = "bookstore-external-secrets-secretsmanager"
  role = aws_iam_role.external_secrets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.eks_addons.account_id}:secret:/bookstore/*"
    }]
  })
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  wait             = true
  timeout          = 600

  set {
    name  = "installCRDs"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "external-secrets-sa"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.external_secrets.arn
  }

  # No real functional dependency on cert-manager (was serialized here only for
  # single-node resource contention — cluster now has 2 nodes, see TF main.tf
  # node_desired_size). Installs concurrently with cert_manager and ingress_nginx.
}
```

- [ ] **Step 3: Pass the new variables from root `main.tf`**

Edit `main.tf`, in the `module "eks_addons"` block (around line 130-137):

```hcl
module "eks_addons" {
  source             = "./modules/eks-addons"
  cluster_name       = module.eks.cluster_name
  oidc_provider_arn  = module.eks.oidc_provider_arn
  oidc_provider_url  = module.eks.oidc_provider_url
  aws_region         = var.aws_region
  node_role_name     = module.eks.node_role_name

  depends_on = [module.eks]
}
```

- [ ] **Step 4: Validate the Terraform changes**

Run: `terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit**

```bash
git add modules/eks-addons/variables.tf modules/eks-addons/external-secrets.tf main.tf
git commit -m "fix(eks-addons): wire IRSA role for external-secrets-sa

ExternalSecrets could never actually pull from Secrets Manager — the
Helm release created a default-named ServiceAccount with no IRSA
role or annotation, while the existing ClusterSecretStore already
expected one named external-secrets-sa. Fixes it cluster-wide."
```

---

### Task 1: Add a `catalog-service` ECR repo

**Files:**
- Modify: `modules/ecr/variables.tf`
- Modify: `modules/ecr/main.tf`
- Modify: `modules/ecr/outputs.tf`
- Modify: `main.tf:66-71` (ecr module call)
- Modify: `outputs.tf`

- [ ] **Step 1: Add an `extra_repos` variable**

Edit `modules/ecr/variables.tf`, add:

```hcl
variable "extra_repos" {
  description = "Additional short repo names (without prefix) to create, e.g. [\"catalog-service\"]"
  type        = list(string)
  default     = []
}
```

- [ ] **Step 2: Merge extra repos into the repo list**

Edit `modules/ecr/main.tf` line 1-3, replace:

```hcl
locals {
  repos = ["${var.prefix}-frontend", "${var.prefix}-backend"]
}
```

with:

```hcl
locals {
  repos = concat(
    ["${var.prefix}-frontend", "${var.prefix}-backend"],
    [for r in var.extra_repos : "${var.prefix}-${r}"]
  )
}
```

- [ ] **Step 3: Add a generic map output for all repos**

Append to `modules/ecr/outputs.tf`:

```hcl
output "repo_urls" {
  description = "Map of short repo name (without prefix) to ECR repository URL — covers frontend, backend, and all extra_repos"
  value = {
    for full_name, repo in aws_ecr_repository.this :
    trimprefix(full_name, "${var.prefix}-") => repo.repository_url
  }
}
```

- [ ] **Step 4: Request the catalog-service repo from root `main.tf`**

Edit `main.tf`, in the `module "ecr"` block (around line 66-71):

```hcl
module "ecr" {
  source                = "./modules/ecr"
  prefix                = "bookstore"
  image_retention_count = 10
  secondary_region      = var.secondary_region
  extra_repos           = ["catalog-service"]
}
```

- [ ] **Step 5: Expose the new repo URL at root**

Edit `outputs.tf`, add after the existing `backend_repo_url` output (line 22-25):

```hcl
output "catalog_service_repo_url" {
  description = "ECR repository URL for the catalog-service image"
  value       = module.ecr.repo_urls["catalog-service"]
}
```

- [ ] **Step 6: Validate**

Run: `terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 7: Commit**

```bash
git add modules/ecr/variables.tf modules/ecr/main.tf modules/ecr/outputs.tf main.tf outputs.tf
git commit -m "feat(ecr): add catalog-service repository via new extra_repos input"
```

---

### Task 2: Catalog DB credentials + schema bootstrap

**Files:**
- Modify: `main.tf` (new resources, append near the ECR/RDS section)
- Modify: `outputs.tf`
- Create: `k8s/services/catalog-service/bootstrap/schema-init-job.yaml`

- [ ] **Step 1: Generate and store catalog DB credentials**

Append to `main.tf`, after the `module "rds"` block:

```hcl
# ── Catalog Service — DB credentials ──────────────────────────────────────────
# Own schema + own DB user inside the existing RDS instance. Full per-service
# RDS isolation is explicitly deferred (see design spec Non-goals) — this is
# schema-level isolation, the cheap intermediate step.

resource "random_password" "catalog_db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}?"
}

resource "aws_secretsmanager_secret" "catalog_db_credentials" {
  name                    = "/bookstore/catalog-db-credentials"
  recovery_window_in_days = 0 # 0 = force delete on destroy, matches modules/rds pattern
}

resource "aws_secretsmanager_secret_version" "catalog_db_credentials" {
  secret_id = aws_secretsmanager_secret.catalog_db_credentials.id
  secret_string = jsonencode({
    DB_USERNAME = "catalog_user"
    DB_PASSWORD = random_password.catalog_db_password.result
    DB_HOST     = module.rds.rds_endpoint
    DB_NAME     = "catalog_db"
  })
}
```

- [ ] **Step 2: Expose the secret ARN**

Edit `outputs.tf`, add:

```hcl
output "catalog_db_secret_arn" {
  description = "ARN of the Secrets Manager secret at /bookstore/catalog-db-credentials"
  value       = aws_secretsmanager_secret.catalog_db_credentials.arn
  sensitive   = true
}
```

- [ ] **Step 3: Write the one-off schema/user bootstrap Job**

This runs once, by hand, after `terraform apply` — it is intentionally **not** part of any kustomize base (a completed Job is immutable; ArgoCD's `selfHeal` would fight with re-applying it). It creates the `catalog_db` schema, migrates the existing `books` table into it, and creates the scoped `catalog_user`.

Create `k8s/services/catalog-service/bootstrap/schema-init-job.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: catalog-schema-init
  namespace: catalog
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: schema-init
          image: mysql:8.0
          command:
            - sh
            - -c
            - |
              set -eu
              mysql -h "$ADMIN_DB_HOST" -u "$ADMIN_DB_USERNAME" -p"$ADMIN_DB_PASSWORD" <<'SQL'
              CREATE DATABASE IF NOT EXISTS catalog_db;

              CREATE TABLE IF NOT EXISTS catalog_db.books (
                id INT AUTO_INCREMENT PRIMARY KEY,
                title VARCHAR(255) NOT NULL,
                `desc` TEXT,
                price DECIMAL(10,2) NOT NULL,
                cover VARCHAR(1024)
              );

              INSERT INTO catalog_db.books (id, title, `desc`, price, cover)
              SELECT id, title, `desc`, price, cover FROM test.books
              ON DUPLICATE KEY UPDATE title = VALUES(title);

              CREATE USER IF NOT EXISTS 'catalog_user'@'%' IDENTIFIED BY '$CATALOG_DB_PASSWORD';
              GRANT ALL PRIVILEGES ON catalog_db.* TO 'catalog_user'@'%';
              FLUSH PRIVILEGES;
              SQL
          env:
            - name: ADMIN_DB_HOST
              valueFrom:
                secretKeyRef: { name: db-secret, key: DB_HOST }
            - name: ADMIN_DB_USERNAME
              valueFrom:
                secretKeyRef: { name: db-secret, key: DB_USERNAME }
            - name: ADMIN_DB_PASSWORD
              valueFrom:
                secretKeyRef: { name: db-secret, key: DB_PASSWORD }
            - name: CATALOG_DB_PASSWORD
              valueFrom:
                secretKeyRef: { name: catalog-db-secret, key: DB_PASSWORD }
```

Note: `db-secret` (namespace `bookstore`) and `catalog-db-secret` (namespace `catalog`) live in different namespaces — this Job runs in the `catalog` namespace, so it can only mount `catalog-db-secret` directly. Task 5 Step 3 below creates `catalog-db-secret` in the `catalog` namespace via ExternalSecret; for `db-secret`'s admin credentials, copy them into the `catalog` namespace once by hand before running this Job (documented in Task 7's verification step) — this Job is a one-time bootstrap tool, not a standing credential bridge between namespaces.

- [ ] **Step 4: Commit**

```bash
git add main.tf outputs.tf k8s/services/catalog-service/bootstrap/schema-init-job.yaml
git commit -m "feat(catalog-service): provision DB credentials + schema bootstrap Job"
```

---

### Task 3: Scaffold the catalog-service Node app

**Files:**
- Create: `services/catalog-service/package.json`
- Create: `services/catalog-service/.env.example`
- Create: `services/catalog-service/.gitignore`
- Create: `services/catalog-service/.dockerignore`
- Create: `services/catalog-service/Dockerfile`

- [ ] **Step 1: package.json**

Create `services/catalog-service/package.json`:

```json
{
  "name": "catalog-service",
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
  "description": "Bookstore catalog microservice — books CRUD"
}
```

- [ ] **Step 2: .env.example**

Create `services/catalog-service/.env.example`:

```
DB_HOST=
DB_USERNAME=
DB_PASSWORD=
DB_PORT=3306
DB_NAME=catalog_db
APP_PORT=3000
```

- [ ] **Step 3: .gitignore and .dockerignore**

Create `services/catalog-service/.gitignore`:

```
node_modules
.env
```

Create `services/catalog-service/.dockerignore`:

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

Create `services/catalog-service/Dockerfile` (identical pattern to `backend/Dockerfile`):

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
git add services/catalog-service/package.json services/catalog-service/.env.example \
  services/catalog-service/.gitignore services/catalog-service/.dockerignore \
  services/catalog-service/Dockerfile
git commit -m "chore(catalog-service): scaffold package + Dockerfile"
```

---

### Task 4: Port the test suite (TDD — write the failing test first)

**Files:**
- Create: `services/catalog-service/__tests__/books.test.js`

- [ ] **Step 1: Write the test file, importing an `app.js` that does not exist yet**

Create `services/catalog-service/__tests__/books.test.js`:

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
    expect(res.text).toContain('service="catalog-service"');
  });
});

describe("GET /books", () => {
  it("returns book list", async () => {
    const books = [{ id: 1, title: "Test", desc: "Desc", price: 9.99, cover: "url" }];
    mockQuery.mockImplementation((_q, cb) => cb(null, books));

    const res = await request(app).get("/books");
    expect(res.status).toBe(200);
    expect(res.body).toEqual(books);
  });

  it("returns empty array when no books", async () => {
    mockQuery.mockImplementation((_q, cb) => cb(null, []));
    const res = await request(app).get("/books");
    expect(res.body).toEqual([]);
  });
});

describe("POST /books", () => {
  it("inserts a book and returns insert result", async () => {
    const result = { insertId: 5, affectedRows: 1 };
    mockQuery.mockImplementation((_q, _v, cb) => cb(null, result));

    const res = await request(app)
      .post("/books")
      .send({ title: "New", desc: "A book", price: 12.99, cover: "http://img" });
    expect(res.status).toBe(200);
    expect(res.body).toEqual(result);
  });
});

describe("DELETE /books/:id", () => {
  it("deletes a book by id", async () => {
    const result = { affectedRows: 1 };
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, result));

    const res = await request(app).delete("/books/1");
    expect(res.status).toBe(200);
    expect(res.body).toEqual(result);
  });
});

describe("PUT /books/:id", () => {
  it("updates a book by id", async () => {
    const result = { affectedRows: 1 };
    mockQuery.mockImplementation((_q, _p, cb) => cb(null, result));

    const res = await request(app)
      .put("/books/1")
      .send({ title: "Updated", desc: "Updated desc", price: 15.99, cover: "http://newimg" });
    expect(res.status).toBe(200);
    expect(res.body).toEqual(result);
  });
});
```

- [ ] **Step 2: Install dependencies and run the test to verify it fails**

Run:
```bash
cd services/catalog-service && npm install
npx vitest run
```
Expected: FAIL — `Cannot find module '../app.js'` (or similar resolve error), since `app.js` doesn't exist yet.

- [ ] **Step 3: Commit the failing test**

```bash
git add services/catalog-service/__tests__/books.test.js services/catalog-service/package-lock.json
git commit -m "test(catalog-service): add failing books CRUD test suite"
```

---

### Task 5: Implement catalog-service (`app.js` + `index.js`)

**Files:**
- Create: `services/catalog-service/app.js`
- Create: `services/catalog-service/index.js`

- [ ] **Step 1: Write `app.js` — ported from `backend/app.js:1-87`, with a `service` label added to both metrics**

Create `services/catalog-service/app.js`:

```javascript
import express from "express";
import cors from "cors";
import morgan from "morgan";
import { Registry, collectDefaultMetrics, Counter, Histogram } from "prom-client";

const SERVICE_NAME = "catalog-service";

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

  app.get("/books", (_req, res) => {
    db.query("SELECT * FROM books", (err, data) => {
      if (err) { console.log(err); return res.json(err); }
      return res.json(data);
    });
  });

  app.post("/books", (req, res) => {
    const q = "INSERT INTO books(`title`, `desc`, `price`, `cover`) VALUES (?)";
    const values = [req.body.title, req.body.desc, req.body.price, req.body.cover];
    db.query(q, [values], (err, data) => {
      if (err) return res.send(err);
      return res.json(data);
    });
  });

  app.delete("/books/:id", (req, res) => {
    db.query(" DELETE FROM books WHERE id = ? ", [req.params.id], (err, data) => {
      if (err) return res.send(err);
      return res.json(data);
    });
  });

  app.put("/books/:id", (req, res) => {
    const q = "UPDATE books SET `title`= ?, `desc`= ?, `price`= ?, `cover`= ? WHERE id = ?";
    const values = [req.body.title, req.body.desc, req.body.price, req.body.cover];
    db.query(q, [...values, req.params.id], (err, data) => {
      if (err) return res.send(err);
      return res.json(data);
    });
  });

  return app;
}
```

Note: dropped the old `GET /` "hello" route — it wasn't part of the books domain and has no equivalent test requirement.

- [ ] **Step 2: Write `index.js` — ported from `backend/index.js`**

Create `services/catalog-service/index.js`:

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
  database: process.env.DB_NAME || "catalog_db",
});

const app = createApp(db);
const APP_PORT = process.env.APP_PORT || 3000;
app.listen(APP_PORT, () => {
  console.log(`catalog-service listening on port ${APP_PORT}.`);
});
```

- [ ] **Step 3: Run the tests, verify they pass**

Run: `cd services/catalog-service && npx vitest run`
Expected: All 7 tests pass (health, metrics, GET books x2, POST, DELETE, PUT).

- [ ] **Step 4: Commit**

```bash
git add services/catalog-service/app.js services/catalog-service/index.js
git commit -m "feat(catalog-service): implement books CRUD (ported from backend/app.js)"
```

---

### Task 6: K8s manifests

**Files:**
- Create: `k8s/services/catalog-service/base/namespace.yaml`
- Create: `k8s/services/catalog-service/base/configmap.yaml`
- Create: `k8s/services/catalog-service/base/external-secret.yaml`
- Create: `k8s/services/catalog-service/base/deployment.yaml`
- Create: `k8s/services/catalog-service/base/service.yaml`
- Create: `k8s/services/catalog-service/base/hpa.yaml`
- Create: `k8s/services/catalog-service/base/pdb.yaml`
- Create: `k8s/services/catalog-service/base/network-policy.yaml`
- Create: `k8s/services/catalog-service/base/kustomization.yaml`
- Create: `k8s/services/catalog-service/overlays/prod/kustomization.yaml`

- [ ] **Step 1: Namespace**

Create `k8s/services/catalog-service/base/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: catalog
  labels:
    name: catalog
```

- [ ] **Step 2: ConfigMap**

Create `k8s/services/catalog-service/base/configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: catalog-config
  namespace: catalog
data:
  DB_PORT: "3306"
  DB_NAME: "catalog_db"
  APP_PORT: "3000"
```

- [ ] **Step 3: ExternalSecret** (reuses the cluster-wide `aws-secretsmanager` `ClusterSecretStore` created by the existing `k8s/base/secrets/external-secret.yaml`, now actually functional after Task 0)

Create `k8s/services/catalog-service/base/external-secret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: catalog-db-secret
  namespace: catalog
spec:
  refreshInterval: 1h

  secretStoreRef:
    name: aws-secretsmanager
    kind: ClusterSecretStore

  target:
    name:           catalog-db-secret
    creationPolicy: Owner

  data:
    - secretKey: DB_USERNAME
      remoteRef:
        key:      /bookstore/catalog-db-credentials
        property: DB_USERNAME

    - secretKey: DB_PASSWORD
      remoteRef:
        key:      /bookstore/catalog-db-credentials
        property: DB_PASSWORD

    - secretKey: DB_HOST
      remoteRef:
        key:      /bookstore/catalog-db-credentials
        property: DB_HOST
```

- [ ] **Step 4: Deployment** (plain `Deployment`, not an Argo `Rollout` — canary deploys land in Plan 4 alongside the gateway cutover, to keep this plan focused)

Create `k8s/services/catalog-service/base/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalog-service
  namespace: catalog
  labels:
    app: catalog-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: catalog-service
  template:
    metadata:
      labels:
        app: catalog-service
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        runAsGroup: 1001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: catalog-service
          image: bookstore-catalog-service:latest
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
                secretKeyRef: { name: catalog-db-secret, key: DB_HOST }
            - name: DB_USERNAME
              valueFrom:
                secretKeyRef: { name: catalog-db-secret, key: DB_USERNAME }
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef: { name: catalog-db-secret, key: DB_PASSWORD }
            - name: DB_PORT
              valueFrom:
                configMapKeyRef: { name: catalog-config, key: DB_PORT }
            - name: DB_NAME
              valueFrom:
                configMapKeyRef: { name: catalog-config, key: DB_NAME }
            - name: APP_PORT
              valueFrom:
                configMapKeyRef: { name: catalog-config, key: APP_PORT }
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

- [ ] **Step 5: Service**

Create `k8s/services/catalog-service/base/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: catalog-service
  namespace: catalog
  labels:
    app: catalog-service
spec:
  selector:
    app: catalog-service
  ports:
    - name: http
      port: 80
      targetPort: 3000
  type: ClusterIP
```

- [ ] **Step 6: HPA**

Create `k8s/services/catalog-service/base/hpa.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: catalog-service-hpa
  namespace: catalog
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: catalog-service
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

- [ ] **Step 7: PDB**

Create `k8s/services/catalog-service/base/pdb.yaml`:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: catalog-service-pdb
  namespace: catalog
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: catalog-service
```

- [ ] **Step 8: NetworkPolicy** — default-deny plus explicit allows. No `gateway` namespace exists yet (that's Plan 4), so for now allow ingress only from the monitoring EC2 box (metrics scraping, once Plan 5 wires it up) and permit direct access during this plan's manual verification via `kubectl port-forward` (which bypasses NetworkPolicy entirely — port-forward talks straight to the pod, so no ingress rule is needed for it to work).

Create `k8s/services/catalog-service/base/network-policy.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: catalog
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: catalog-service-policy
  namespace: catalog
spec:
  podSelector:
    matchLabels:
      app: catalog-service
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

- [ ] **Step 9: Kustomize base**

Create `k8s/services/catalog-service/base/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: catalog

resources:
- namespace.yaml
- configmap.yaml
- external-secret.yaml
- deployment.yaml
- service.yaml
- hpa.yaml
- pdb.yaml
- network-policy.yaml
```

- [ ] **Step 10: Prod overlay** (image tag patched by CI, mirrors `k8s/overlays/prod/kustomization.yaml`'s placeholder-account-ID pattern)

Create `k8s/services/catalog-service/overlays/prod/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../../base

# Account ID is intentionally NOT hardcoded here.
# CI (deploy stage) overwrites this from secrets.AWS_ACCOUNT_ID every push:
#   kustomize edit set image bookstore-catalog-service=${ECR_REGISTRY}/bookstore-catalog-service:${SHA}
# Placeholder 000000000000 is replaced automatically on first CI deploy.
# For manual local deploy: replace 000000000000 with your real AWS account ID.
images:
- name: bookstore-catalog-service
  newName: 000000000000.dkr.ecr.us-west-1.amazonaws.com/bookstore-catalog-service
  newTag: latest
```

- [ ] **Step 11: Validate manifests render**

Run: `kubectl kustomize k8s/services/catalog-service/overlays/prod`
Expected: Rendered YAML for Namespace, ConfigMap, ExternalSecret, Deployment, Service, HPA, PDB, 2x NetworkPolicy — no errors.

- [ ] **Step 12: Commit**

```bash
git add k8s/services/catalog-service/base k8s/services/catalog-service/overlays
git commit -m "feat(catalog-service): add K8s manifests (namespace, deployment, service, hpa, pdb, netpol)"
```

---

### Task 7: ArgoCD ApplicationSet

**Files:**
- Create: `k8s/argocd/applicationset-microservices.yaml`

- [ ] **Step 1: Write the ApplicationSet with a one-entry list generator**

Future plans (2-5) append their service to the `elements` list — no other change needed per new service.

Create `k8s/argocd/applicationset-microservices.yaml`:

```yaml
# ─────────────────────────────────────────────────────────────────────────────
# ArgoCD ApplicationSet — Bookstore Microservices
#
# One Application per entry in the list generator below. Each new microservice
# plan (user-service, order-service, notification-service, api-gateway) adds
# one more element here instead of a hand-written Application manifest.
#
# targetRevision is pinned to the `observability` branch while this platform
# is under active development on that branch — switch to `main` (or delete
# this override and let it inherit) once the work merges and CI's gated
# deploy stage takes over image-tag bumps, matching k8s/argocd/application.yaml.
#
# Prerequisites: same as k8s/argocd/application.yaml (ArgoCD installed, repo
# credentials registered if private). Apply once:
#   kubectl apply -f k8s/argocd/applicationset-microservices.yaml
# ─────────────────────────────────────────────────────────────────────────────

apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: bookstore-microservices
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - service: catalog-service
            namespace: catalog

  template:
    metadata:
      name: '{{service}}'
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: default

      source:
        repoURL: https://github.com/KANDUKURIsaikrishna/aws_three_tier_code.git
        targetRevision: observability
        path: 'k8s/services/{{service}}/overlays/prod'
        kustomize: {}

      destination:
        server: https://kubernetes.default.svc
        namespace: '{{namespace}}'

      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
        retry:
          limit: 5
          backoff:
            duration: 5s
            factor: 2
            maxDuration: 3m
```

- [ ] **Step 2: Commit**

```bash
git add k8s/argocd/applicationset-microservices.yaml
git commit -m "feat(argocd): add ApplicationSet for microservices, seeded with catalog-service"
```

---

### Task 8: CI — build, scan, and push catalog-service

**Files:**
- Modify: `.github/workflows/ci-cd.yml`

- [ ] **Step 1: Add `observability` to the trigger branches**

Edit `.github/workflows/ci-cd.yml:1-4`, change:

```yaml
on:
  push:
    branches: [main, improvements]
  pull_request:
    branches: [main, improvements]
```

to:

```yaml
on:
  push:
    branches: [main, improvements, observability]
  pull_request:
    branches: [main, improvements, observability]
```

- [ ] **Step 2: Add a `CATALOG_REPO` env var**

Edit `.github/workflows/ci-cd.yml:14-19`, change:

```yaml
env:
  AWS_REGION:    us-west-1
  BACKEND_REPO:  bookstore-backend
  FRONTEND_REPO: bookstore-frontend
  EKS_CLUSTER:   bookstore-eks
  K8S_NAMESPACE: bookstore
```

to:

```yaml
env:
  AWS_REGION:    us-west-1
  BACKEND_REPO:  bookstore-backend
  FRONTEND_REPO: bookstore-frontend
  CATALOG_REPO:  bookstore-catalog-service
  EKS_CLUSTER:   bookstore-eks
  K8S_NAMESPACE: bookstore
```

- [ ] **Step 3: Run catalog-service's own tests in the `sast` job**

Edit `.github/workflows/ci-cd.yml`, in the `sast` job, after the existing "Run backend tests" step (and its "Install backend dependencies" step), add:

```yaml
      - name: Install catalog-service dependencies
        run: cd services/catalog-service && npm ci

      - name: Run catalog-service tests
        run: cd services/catalog-service && npm test

      - name: npm audit — catalog-service production deps (fail on high/critical CVEs)
        run: cd services/catalog-service && npm audit --audit-level=high --omit=dev
```

- [ ] **Step 4: Allow `build-and-push` to run on `observability`**

Edit the `build-and-push` job's `if` condition:

```yaml
    if: github.ref == 'refs/heads/main' || github.ref == 'refs/heads/improvements'
```

to:

```yaml
    if: github.ref == 'refs/heads/main' || github.ref == 'refs/heads/improvements' || github.ref == 'refs/heads/observability'
```

- [ ] **Step 5: Build, scan, and push the catalog-service image**

In the `build-and-push` job, after the existing "Push backend image" step and before the "Build frontend image" step, add:

```yaml
      # ── Catalog service image ────────────────────────────────────────────
      - name: Build catalog-service image (no push yet)
        uses: docker/build-push-action@10e90e3645eae34f1e60eeb005ba3a3d33f178e8  # v6
        with:
          context:   ./services/catalog-service
          push:      false
          load:      true
          tags:      ${{ env.ECR_REGISTRY }}/${{ env.CATALOG_REPO }}:${{ steps.tag.outputs.tag }}
          cache-from: type=gha
          cache-to:   type=gha,mode=max

      - name: Trivy — scan catalog-service (CRITICAL + HIGH = hard fail)
        uses: aquasecurity/trivy-action@915b19bbe73b92a6cf82a1bc12b087c9a19a5fe2  # v0.28.0
        with:
          image-ref:      ${{ env.ECR_REGISTRY }}/${{ env.CATALOG_REPO }}:${{ steps.tag.outputs.tag }}
          format:         sarif
          output:         trivy-catalog-service.sarif
          severity:       CRITICAL,HIGH
          exit-code:      "1"
          ignore-unfixed: true

      - name: Show catalog-service CVEs in CI log (diagnostic on failure)
        if: failure()
        run: |
          [ -f trivy-catalog-service.sarif ] && \
            jq -r '.runs[].results[] |
              "[" + (.level | ascii_upcase) + "] " + .ruleId +
              ": " + (.message.text | split("\n")[0])' \
            trivy-catalog-service.sarif \
          || echo "trivy-catalog-service.sarif not found"

      - name: Upload catalog-service Trivy SARIF to GitHub Security tab
        uses: github/codeql-action/upload-sarif@8aad20d150bbac5944a9f9d289da16a4b0d87c1e  # v4
        if: always()
        with:
          sarif_file: trivy-catalog-service.sarif
          category:   trivy-catalog-service

      - name: Push catalog-service image
        run: |
          docker push ${{ env.ECR_REGISTRY }}/${{ env.CATALOG_REPO }}:${{ steps.tag.outputs.tag }}
```

- [ ] **Step 6: Bump the catalog-service image tag in the `deploy` job** (still `main`-only, matching the existing gate — see Task 9 for how this branch deploys in the meantime)

In the `deploy` job's "Update image tags in kustomization.yaml" step, add a `kustomize edit` line for catalog-service:

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

      - name: Commit and push updated image tags
        env:
          TAG: ${{ needs.build-and-push.outputs.image-tag }}
        run: |
          git config user.email "ci-bot@github-actions"
          git config user.name "GitHub Actions"
          git add k8s/overlays/prod/kustomization.yaml k8s/services/catalog-service/overlays/prod/kustomization.yaml
          git diff --staged --quiet && echo "No image tag changes." && exit 0
          git commit -m "chore: bump image tags to ${TAG}"
          git push
```

(Replaces the existing "Update image tags in kustomization.yaml" and "Commit and push updated image tags" steps.)

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/ci-cd.yml
git commit -m "ci: build/scan/push catalog-service image, run on observability branch"
```

---

### Task 9: Manual verification (real `terraform apply`, real deploy, real curl)

No new files — this task exercises everything built above end-to-end.

- [ ] **Step 1: Apply the Terraform changes**

Run: `terraform plan -out=catalog.tfplan`
Review: should show the new `aws_iam_role.external_secrets`, `aws_iam_role_policy.external_secrets`, `aws_ecr_repository.this["bookstore-catalog-service"]`, `aws_secretsmanager_secret.catalog_db_credentials` (+ version), and the `helm_release.external_secrets` update (serviceAccount name/annotation change).

Run: `terraform apply catalog.tfplan`
Expected: Apply completes with no errors. Note the `catalog_service_repo_url` and `catalog_db_secret_arn` outputs.

- [ ] **Step 2: Confirm the ExternalSecrets fix actually works**

Run: `kubectl get serviceaccount external-secrets-sa -n external-secrets -o jsonpath='{.metadata.annotations}'`
Expected: contains `"eks.amazonaws.com/role-arn":"arn:aws:iam::<account>:role/bookstore-external-secrets"`.

Run: `kubectl get externalsecret db-secret -n bookstore`
Expected: `STATUS` column shows `SecretSynced` (previously would have shown an error/`SecretSyncedError`, since the SA had no valid IRSA identity).

- [ ] **Step 3: Apply the ApplicationSet and let ArgoCD deploy catalog-service**

Run:
```bash
kubectl apply -f k8s/argocd/applicationset-microservices.yaml
kubectl get applications -n argocd
```
Expected: an `Application` named `catalog-service` appears, `SYNC STATUS` eventually reaches `Synced`, `HEALTH STATUS` reaches `Healthy`. If images haven't been pushed yet (Task 8 CI hasn't run), the Deployment will show `ImagePullBackOff` until an image lands in ECR — push once by hand if needed: `docker build -t <catalog_service_repo_url>:manual services/catalog-service && docker push <catalog_service_repo_url>:manual`, then `cd k8s/services/catalog-service/overlays/prod && kustomize edit set image bookstore-catalog-service=<catalog_service_repo_url>:manual && git add -A && git commit -m "chore: manual catalog-service image for verification" && git push`.

- [ ] **Step 4: Bridge admin DB credentials into the `catalog` namespace, then run the schema bootstrap Job**

```bash
kubectl get secret db-secret -n bookstore -o json | \
  jq 'del(.metadata.namespace,.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.ownerReferences)' | \
  jq '.metadata.namespace="catalog"' | \
  kubectl apply -n catalog -f -

kubectl apply -f k8s/services/catalog-service/bootstrap/schema-init-job.yaml
kubectl wait --for=condition=complete job/catalog-schema-init -n catalog --timeout=60s
kubectl logs job/catalog-schema-init -n catalog
```
Expected: Job completes, logs show no MySQL errors. `catalog_db.books` now exists with the migrated rows.

Clean up the copied admin secret afterward (it was only needed for the bootstrap Job, not a standing credential in this namespace):
```bash
kubectl delete secret db-secret -n catalog
kubectl delete job catalog-schema-init -n catalog
```

- [ ] **Step 5: Curl the live service end-to-end (bypassing the public ingress — no cutover yet)**

```bash
kubectl port-forward -n catalog svc/catalog-service 8081:80
```
In another terminal:
```bash
curl -s http://localhost:8081/health
curl -s http://localhost:8081/books
curl -s http://localhost:8081/metrics | grep 'service="catalog-service"' | head -5
```
Expected: `/health` returns `{"status":"ok"}`; `/books` returns the migrated rows as JSON; `/metrics` shows `http_requests_total` / `http_request_duration_seconds` samples labeled `service="catalog-service"`.

- [ ] **Step 6: Final commit — mark this plan's outcome**

No code changes at this step; if any fixes were needed during verification (e.g. a manifest typo), commit those now with a clear message before moving to Plan 2.

---

## Plan Series Status

- [x] Design spec approved — `docs/superpowers/specs/2026-07-29-microservices-observability-design.md`
- [ ] **Plan 1 (this file) — catalog-service**
- [ ] Plan 2 — user-service (auth/JWT)
- [ ] Plan 3 — order-service + notification-service
- [ ] Plan 4 — api-gateway (routing, JWT enforcement, traffic cutover, old `backend/` removal)
- [ ] Plan 5 — observability (EC2 Prometheus scrape config, Grafana dashboards, Alertmanager rules)

Each subsequent plan gets written just before it's executed, once this plan's actual output (file paths, secret names, service conventions) is confirmed on disk — not guessed in advance.
