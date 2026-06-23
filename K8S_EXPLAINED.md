# Kubernetes (`k8s/`) Folder — Plain English Guide

> **Who this is for:** Someone who understands the bookstore app (React website + Node.js API + MySQL database) but is new to Kubernetes.
> Think of Kubernetes as **a smart manager for Docker containers**. You tell it what you want running, and it makes sure it stays running — even if a server crashes.

---

## The Big Picture First

Your bookstore app has **three pieces**:

```
User's Browser
      │  (visits bookstore.b17facebook.xyz)
      ▼
 ┌──────────────────────────────────────────────────────────────┐
 │                   Nginx Ingress (the front door)             │
 │             routes traffic to the right place                │
 └──────────┬────────────────────────────┬─────────────────────┘
            │                            │
            ▼                            ▼
   bookstore.b17facebook.xyz     api.bookstore.b17facebook.xyz
            │                            │
   ┌────────────────┐          ┌─────────────────────┐
   │  Frontend Pods │          │   Backend Pods       │
   │  React website │          │   Node.js REST API   │
   │  served by     │          │   reads/writes books │
   │  Nginx         │          │   from the database  │
   └────────────────┘          └──────────┬──────────┘
                                          │
                               ┌──────────▼──────────┐
                               │    MySQL Pod         │
                               │    (dev only)  OR    │
                               │    RDS on AWS        │
                               │    (production)      │
                               └─────────────────────┘
```

Everything inside the dashed box lives **inside Kubernetes**, on your EKS cluster on AWS.

---

## What is a Namespace?

A **namespace** is like a folder inside Kubernetes. It keeps resources separated so different apps don't interfere with each other.

Your cluster has these namespaces:

| Namespace | What lives there | Who created it |
|---|---|---|
| `bookstore` | Your actual app — frontend, backend, MySQL | You (via `namespace.yaml`) |
| `argocd` | ArgoCD — the GitOps deployment tool | Helm chart |
| `ingress-nginx` | Nginx Ingress Controller — the front door | Helm chart |
| `cert-manager` | Automatic TLS/HTTPS certificates | Helm chart |
| `external-secrets` | Syncs passwords from AWS Secrets Manager | Helm chart |
| `kube-system` | Kubernetes' own internals (DNS, networking) | AWS EKS |

The `k8s/` folder in this repo **only manages the `bookstore` namespace**. The others are installed separately via Helm.

---

## Folder Structure

```
k8s/
├── kustomization.yaml          ← Master list: tells ArgoCD which files to deploy
├── namespace.yaml              ← Creates the "bookstore" namespace
│
├── configmaps/
│   └── backend-config.yaml    ← Non-secret config for the backend (DB host, port, etc.)
│
├── secrets/
│   ├── external-secret.yaml   ← PRODUCTION: pulls DB password from AWS Secrets Manager
│   └── db-secret.yaml         ← LOCAL DEV ONLY: hardcoded placeholder (never commit real values)
│
├── database/
│   ├── mysql-init-configmap.yaml   ← SQL script to create the books table + sample data
│   ├── mysql-service.yaml          ← Internal DNS name for MySQL ("mysql-service")
│   └── mysql-statefulset.yaml      ← The MySQL container itself (dev/local only)
│
├── backend/
│   ├── deployment.yaml         ← Runs the Node.js API containers
│   ├── service.yaml            ← Internal DNS name for the API ("backend-service")
│   └── hpa.yaml                ← Auto-scaling rules for the API
│
├── frontend/
│   ├── deployment.yaml         ← Runs the React+Nginx containers
│   ├── service.yaml            ← Internal DNS name for the website ("frontend-service")
│   └── hpa.yaml                ← Auto-scaling rules for the website
│
├── ingress/
│   └── ingress.yaml            ← The front door: routes domain names → services
│
├── network-policy/
│   └── network-policy.yaml     ← Firewall rules between pods
│
├── pdb/
│   └── pdb.yaml                ← Ensures at least 1 pod stays alive during maintenance
│
└── argocd/
    └── application.yaml        ← Tells ArgoCD: "watch this git repo and keep the cluster in sync"
```

---

## File-by-File Breakdown

---

### `kustomization.yaml` — The Master List

Think of this as the **table of contents**. ArgoCD reads this file first to know which other files to apply.

It also controls **which Docker image version gets deployed**. When your CI/CD pipeline builds a new Docker image, it updates the image tag here, commits it to git, and ArgoCD automatically rolls out the new version.

```
images:
  bookstore-backend  → <account>.dkr.ecr.us-west-1.amazonaws.com/bookstore-backend:<sha8>
  bookstore-frontend → <account>.dkr.ecr.us-west-1.amazonaws.com/bookstore-frontend:<sha8>
```

The `<sha8>` tag is the first 8 characters of the git commit SHA. The CI pipeline updates these values automatically via `kustomize edit set image` after every successful build.

---

### `namespace.yaml` — The Folder Creator

Creates a namespace called `bookstore` inside Kubernetes. Everything your app needs lives inside this namespace.

```
Kind: Namespace
Name: bookstore
```

Without this, Kubernetes wouldn't know where to put your app's resources.

---

## The `configmaps/` Folder — Non-Secret Configuration

### `configmaps/backend-config.yaml`

A **ConfigMap** is like a `.env` file but stored inside Kubernetes. It holds configuration values that are **not secret** — things you're happy for any developer to see.

| Setting | Value | What it means |
|---|---|---|
| `DB_HOST` | `mysql-service` | The DNS name of the MySQL pod inside the cluster |
| `DB_PORT` | `3306` | MySQL's standard port number |
| `DB_NAME` | `test` | The database name |
| `APP_PORT` | `3000` | The port the Node.js API listens on |

The backend pods read these values as environment variables when they start.

---

## The `secrets/` Folder — Passwords and Credentials

### `secrets/external-secret.yaml` — Production Secret Management

This is **how production handles passwords**. Instead of storing the database password in git (dangerous!), this file tells a controller called **External Secrets Operator (ESO)** to go fetch the password from **AWS Secrets Manager** and create a Kubernetes Secret automatically.

It has two parts:

**Part 1 — ClusterSecretStore**: Tells ESO "connect to AWS Secrets Manager in us-west-1 using this service account."

**Part 2 — ExternalSecret**: Says "go to `/bookstore/db-credentials` in Secrets Manager, pull `DB_USERNAME` and `DB_PASSWORD`, and create a Kubernetes Secret called `db-secret` in the `bookstore` namespace."

The result is a native Kubernetes Secret that gets **refreshed every hour** automatically. No password ever touches git or the CI pipeline.

```
AWS Secrets Manager ──(ESO fetches)──► Kubernetes Secret "db-secret"
                                              │
                             ┌────────────────┴────────────┐
                             ▼                             ▼
                     backend pods                   mysql pods
                  (DB_USERNAME, DB_PASSWORD env vars)
```

### `secrets/db-secret.yaml` — Local Development Only

This is a **placeholder** for running the app on your laptop. It has fake base64-encoded values. **Never put real passwords here and never commit this file with real values.** In production, the `external-secret.yaml` above takes care of creating the `db-secret` automatically.

---

## The `database/` Folder — MySQL (Dev / Local Only)

> In **production on AWS**, your app talks to **RDS MySQL** (a managed AWS database), not these pods. These files are for running the full stack locally or for testing.

### `database/mysql-init-configmap.yaml` — Database Schema

A ConfigMap that holds a SQL script. When MySQL starts for the first time, it runs this script automatically to:
1. Create the `test` database
2. Create the `books` table with columns: `id`, `title`, `desc`, `price`, `cover`
3. Insert 2 sample books (The Great Gatsby and To Kill a Mockingbird)

### `database/mysql-service.yaml` — MySQL's Internal Phone Number

A **headless Service** (no load balancing, `clusterIP: None`) that gives MySQL a stable DNS name inside the cluster: `mysql-service.bookstore.svc.cluster.local`.

The backend pod looks up `mysql-service` to find MySQL. Without this, the backend would need to know MySQL's IP address, which changes every time the pod restarts.

### `database/mysql-statefulset.yaml` — The MySQL Container

A **StatefulSet** (not a Deployment) because databases need stable storage that survives pod restarts.

Key details:
- **Image**: `mysql:8.0` — official MySQL 8 container
- **1 replica** — one MySQL pod
- **Storage**: 10 GB EBS volume (`gp3` type) attached to the pod — data survives if the pod restarts
- **Passwords**: read from the `db-secret` Kubernetes Secret (no hardcoded passwords)
- **Health checks**: runs `mysqladmin ping` every 10 seconds to confirm MySQL is alive
- **Resources**: requests 250m CPU + 512MB RAM; can use up to 1 CPU + 1GB RAM

---

## The `backend/` Folder — Node.js API

### `backend/deployment.yaml` — The API Containers

A **Deployment** tells Kubernetes: "keep 2 copies of the backend API running at all times."

Key details:

| Setting | Value | Why |
|---|---|---|
| Replicas | 2 | So one can restart without downtime |
| Image | `bookstore-backend:<sha8>` | The Docker image built by your CI pipeline, tagged with git SHA |
| Port | 3000 | Node.js Express listens here |
| User | UID 1001 (non-root) | Security — can't escalate to root |
| Root filesystem | Read-only | Security — container can't write to its own disk |
| Capabilities | ALL dropped | Security — container has minimal Linux privileges |
| `/tmp` volume | emptyDir | Writable scratch space (needed because root FS is read-only) |

**Environment variables** injected from two places:
- Non-secret config (`DB_HOST`, `DB_PORT`, `DB_NAME`, `APP_PORT`) → from `backend-config` ConfigMap
- Secrets (`DB_USERNAME`, `DB_PASSWORD`) → from `db-secret` Kubernetes Secret

**Health checks**:
- **Readiness probe**: hits `GET /` on port 3000. Kubernetes only sends traffic to a pod after this passes.
- **Liveness probe**: hits `GET /` on port 3000. If this fails 3 times, Kubernetes restarts the pod.

### `backend/service.yaml` — The API's Internal Phone Number

A **ClusterIP Service** named `backend-service`. It gives the backend pods a stable internal DNS name and load-balances traffic across all 2 backend pods.

```
frontend pod  →  backend-service:80  →  (one of) backend pod 1 or 2  →  port 3000
```

The frontend never talks directly to a pod IP. It always goes through the service.

### `backend/hpa.yaml` — Auto-Scaling for the API

A **HorizontalPodAutoscaler** watches CPU and memory usage and automatically adds or removes backend pods:

| Setting | Value |
|---|---|
| Minimum pods | 2 |
| Maximum pods | 10 |
| Scale up when CPU > | 70% |
| Scale up when Memory > | 80% |

Example: if Black Friday traffic spikes CPU to 90%, Kubernetes automatically adds more backend pods (up to 10). When traffic drops, it scales back down to 2.

---

## The `frontend/` Folder — React Website

### `frontend/deployment.yaml` — The Website Containers

Same pattern as the backend but for the React app served by Nginx.

| Setting | Value | Why |
|---|---|---|
| Replicas | 2 | Redundancy |
| Image | `bookstore-frontend:<sha8>` | Built by CI pipeline, tagged with git SHA |
| Port | 8080 | Nginx listens here (not 80 — non-root can't bind port 80) |
| User | UID 101 (non-root) | Security |
| Root filesystem | Read-only | Security |
| `/tmp`, `/var/cache/nginx`, `/var/run` | emptyDir volumes | Nginx needs to write to these paths; emptyDir provides writable scratch space |

**Health check**: hits `GET /health` on port 8080. Nginx serves a simple health endpoint.

### `frontend/service.yaml` — The Website's Internal Phone Number

A **ClusterIP Service** named `frontend-service`. Routes external traffic (from the Ingress) to the frontend pods.

```
Ingress (bookstore.b17facebook.xyz:443)  →  frontend-service:80  →  frontend pod:8080
```

### `frontend/hpa.yaml` — Auto-Scaling for the Website

| Setting | Value |
|---|---|
| Minimum pods | 2 |
| Maximum pods | 5 |
| Scale up when CPU > | 70% |

The frontend is cheaper to run (static files + Nginx), so the max is only 5 (vs 10 for the backend).

---

## The `ingress/` Folder — The Front Door

### `ingress/ingress.yaml` — Traffic Routing Rules

The **Ingress** is the only entry point from the internet into your cluster. It sits in front of both services and routes based on the domain name.

**Routing rules:**

| Domain | Goes to | What it serves |
|---|---|---|
| `bookstore.b17facebook.xyz` | `frontend-service:80` | React website |
| `api.bookstore.b17facebook.xyz` | `backend-service:80` | Node.js API |

**TLS (HTTPS):**
- `cert-manager` sees this Ingress and automatically requests a Let's Encrypt certificate for both domains
- The certificate is stored in a Kubernetes Secret called `bookstore-tls`
- Any HTTP request is **force-redirected to HTTPS** (the `ssl-redirect: "true"` annotation)

The Ingress is handled by **Nginx Ingress Controller** (installed via Helm in the `ingress-nginx` namespace). It exposes a **Network Load Balancer** on AWS that gets the public IP address you point your DNS to.

---

## The `network-policy/` Folder — Pod Firewall Rules

### `network-policy/network-policy.yaml`

By default, any pod in Kubernetes can talk to any other pod — that's a security risk. NetworkPolicies act like **firewall rules** between pods.

This file defines 4 policies:

**Policy 1 — Default Deny All**
```
Block ALL traffic in and out of every pod in the bookstore namespace.
Then the policies below open only what's needed.
```

**Policy 2 — Frontend Policy**
```
Frontend pods CAN receive from:  Nginx Ingress Controller (port 8080)
Frontend pods CAN send to:       Backend pods (port 3000)
                                 DNS server (port 53) — to look up "backend-service"
Frontend pods CANNOT talk to:    MySQL, the internet, or anything else
```

**Policy 3 — Backend Policy**
```
Backend pods CAN receive from:   Frontend pods (port 3000)
                                 Nginx Ingress Controller (port 3000) — for direct API calls
Backend pods CAN send to:        MySQL pods (port 3306)
                                 DNS server (port 53) — to look up "mysql-service"
Backend pods CANNOT talk to:     The internet, or anything else
```

**Policy 4 — MySQL Policy**
```
MySQL pods CAN receive from:     Backend pods only (port 3306)
MySQL pods CAN send to:          DNS server (port 53)
MySQL pods CANNOT talk to:       Anything else — completely isolated
```

Visual summary:
```
Internet
   │
   ▼
Nginx Ingress ──► Frontend (8080) ──► Backend (3000) ──► MySQL (3306)
                      ✗                    ✗                  ✗
               can't reach MySQL      can't reach      completely locked
               or internet            internet              down
```

---

## The `pdb/` Folder — Maintenance Protection

### `pdb/pdb.yaml` — Pod Disruption Budgets

A **PodDisruptionBudget** (PDB) tells Kubernetes: "when you're doing maintenance (like upgrading a node), don't take down ALL pods of a type at once — always keep at least 1 running."

| PDB | Protects | Rule |
|---|---|---|
| `backend-pdb` | Backend Deployment | At least 1 backend pod must stay running |
| `frontend-pdb` | Frontend Deployment | At least 1 frontend pod must stay running |

Without PDBs, a node upgrade could briefly take all pods offline. With PDBs, Kubernetes drains nodes one at a time, ensuring zero downtime.

---

## The `argocd/` Folder — Automatic Deployment

### `argocd/application.yaml` — GitOps Sync Config

This file tells ArgoCD what to watch and where to deploy it.

| Setting | Value | Meaning |
|---|---|---|
| Source repo | `https://github.com/YOUR_GITHUB_USERNAME/aws_three_tier_code.git` | Watch this git repo |
| Branch | `main` | Watch the `main` branch |
| Path | `k8s/` | Look at the `k8s/` folder specifically |
| Destination | `https://kubernetes.default.svc` | Deploy to this cluster |
| Namespace | `bookstore` | Deploy into the `bookstore` namespace |
| Auto-prune | `true` | If you delete a file from git, ArgoCD deletes the resource from the cluster |
| Self-heal | `true` | If someone manually changes something in the cluster, ArgoCD reverts it back to match git |
| Retry | 5 times with exponential backoff | If a sync fails, retry automatically |

**How deployment works end-to-end:**
```
1. You push code to GitHub
2. GitHub Actions pipeline runs:
   - Builds new Docker images
   - Pushes them to AWS ECR
   - Updates the image tag in k8s/kustomization.yaml
   - Commits that change to git
3. ArgoCD notices the new commit (polls every 3 minutes)
4. ArgoCD runs `kustomize build k8s/` to render all manifests
5. ArgoCD applies the changes to the cluster
6. Kubernetes does a rolling update — new pods start, old pods stop
7. Zero downtime
```

---

## Summary: All Kubernetes Resources in One Place

### Namespaces

| Namespace | Purpose |
|---|---|
| `bookstore` | Your application |
| `argocd` | GitOps deployment controller |
| `ingress-nginx` | Nginx reverse proxy (front door) |
| `cert-manager` | Automatic HTTPS certificates |
| `external-secrets` | AWS Secrets Manager sync |

---

### Deployments (stateless, auto-replaced on crash)

| Name | Namespace | Pods | Image | Port |
|---|---|---|---|---|
| `frontend` | `bookstore` | 2–5 | `bookstore-frontend:<sha8>` | 8080 |
| `backend` | `bookstore` | 2–10 | `bookstore-backend:<sha8>` | 3000 |

---

### StatefulSets (stateful, keeps data on disk)

| Name | Namespace | Pods | Image | Port | Storage |
|---|---|---|---|---|---|
| `mysql` | `bookstore` | 1 | `mysql:8.0` | 3306 | 10 GB EBS |

---

### Services (internal DNS + load balancing)

| Name | Namespace | Type | Port | Routes to |
|---|---|---|---|---|
| `frontend-service` | `bookstore` | ClusterIP | 80 → 8080 | frontend pods |
| `backend-service` | `bookstore` | ClusterIP | 80 → 3000 | backend pods |
| `mysql-service` | `bookstore` | Headless (None) | 3306 | mysql pod |

---

### Ingress (external traffic routing)

| Name | Namespace | Domain | Backend Service |
|---|---|---|---|
| `bookstore-ingress` | `bookstore` | `bookstore.b17facebook.xyz` | `frontend-service:80` |
| `bookstore-ingress` | `bookstore` | `api.bookstore.b17facebook.xyz` | `backend-service:80` |

---

### ConfigMaps (non-secret configuration)

| Name | Namespace | Contents |
|---|---|---|
| `backend-config` | `bookstore` | DB_HOST, DB_PORT, DB_NAME, APP_PORT |
| `mysql-init` | `bookstore` | SQL script to create schema + seed data |

---

### Secrets (sensitive values)

| Name | Namespace | How created | Contains |
|---|---|---|---|
| `db-secret` | `bookstore` | By ESO from AWS Secrets Manager (prod) or manually (dev) | DB_USERNAME, DB_PASSWORD |
| `bookstore-tls` | `bookstore` | By cert-manager automatically | TLS certificate + private key |

---

### HorizontalPodAutoscalers (auto-scaling)

| Name | Namespace | Target | Min | Max | Scale trigger |
|---|---|---|---|---|---|
| `frontend-hpa` | `bookstore` | `frontend` Deployment | 2 | 5 | CPU > 70% |
| `backend-hpa` | `bookstore` | `backend` Deployment | 2 | 10 | CPU > 70% or Memory > 80% |

---

### PodDisruptionBudgets (maintenance protection)

| Name | Namespace | Protects | Rule |
|---|---|---|---|
| `frontend-pdb` | `bookstore` | frontend pods | min 1 always available |
| `backend-pdb` | `bookstore` | backend pods | min 1 always available |

---

### NetworkPolicies (pod firewall)

| Name | Namespace | Who it applies to | Effect |
|---|---|---|---|
| `default-deny-all` | `bookstore` | All pods | Block everything by default |
| `frontend-policy` | `bookstore` | frontend pods | Allow in from ingress-nginx; allow out to backend + DNS |
| `backend-policy` | `bookstore` | backend pods | Allow in from frontend + ingress; allow out to mysql + DNS |
| `mysql-policy` | `bookstore` | mysql pod | Allow in from backend only; allow out to DNS only |

---

## How It All Connects — The Full Request Journey

```
User types bookstore.b17facebook.xyz in browser
    │
    ▼
AWS Network Load Balancer (public IP)
    │  (created automatically by Nginx Ingress Controller)
    ▼
Nginx Ingress Controller pod  (namespace: ingress-nginx)
    │  reads ingress.yaml rules
    │  terminates TLS using bookstore-tls certificate
    ▼
frontend-service  (ClusterIP, port 80)
    │  load balances across 2 frontend pods
    ▼
frontend pod  (React app served by Nginx, port 8080)
    │  browser loads the React SPA (single-page app)
    │
    │  user clicks "View Books" → browser calls api.bookstore.b17facebook.xyz
    ▼
Nginx Ingress Controller  (sees api.bookstore.b17facebook.xyz)
    ▼
backend-service  (ClusterIP, port 80)
    │  load balances across 2 backend pods
    ▼
backend pod  (Node.js Express API, port 3000)
    │  reads DB_HOST=mysql-service from ConfigMap
    │  reads DB_USERNAME, DB_PASSWORD from db-secret
    ▼
mysql-service  (headless, port 3306)
    ▼
mysql pod  (MySQL 8.0, port 3306)
    │  queries the books table
    ▼
Returns JSON list of books back up the chain to the browser
```

---

## Quick Reference: Useful `kubectl` Commands

```bash
# See everything running in the bookstore namespace
kubectl get all -n bookstore

# See pod logs (live)
kubectl logs -f deployment/backend -n bookstore
kubectl logs -f deployment/frontend -n bookstore

# See why a pod is not starting
kubectl describe pod -n bookstore -l app=backend

# Check auto-scaling status
kubectl get hpa -n bookstore

# Check network policies
kubectl get networkpolicy -n bookstore

# Check if the secret was synced from AWS
kubectl get secret db-secret -n bookstore -o jsonpath='{.data.DB_USERNAME}' | base64 -d

# Check ArgoCD sync status
kubectl get application bookstore -n argocd

# Port-forward the frontend locally (no ingress needed)
kubectl port-forward svc/frontend-service 8080:80 -n bookstore
# Then open http://localhost:8080
```
