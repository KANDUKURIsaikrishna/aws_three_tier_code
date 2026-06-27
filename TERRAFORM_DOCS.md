# Terraform Infrastructure — Deep Dive

This document explains every Terraform file and module in this project: what each resource does, why it exists, and how the pieces connect.

---

## Entry Points

### `versions.tf` — Provider Requirements and State Backend

```hcl
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws  = { source = "hashicorp/aws",  version = "~> 5.0" }
    helm = { source = "hashicorp/helm", version = "~> 2.0" }
  }
  backend "s3" {
    bucket         = ""          # fill after running scripts/bootstrap-tf-state.sh
    key            = "prod/terraform.tfstate"
    region         = "us-west-1"
    dynamodb_table = ""          # fill after bootstrap
    encrypt        = true
  }
}
```

**Why `~> 5.0` for AWS provider?** The tilde-arrow constraint means "5.x but not 6.x". Locks major version to avoid breaking changes while allowing patch updates.

**Why S3 backend with DynamoDB?** Local `terraform.tfstate` is dangerous — it can be lost, can't be shared across team members, and doesn't prevent two people running `terraform apply` simultaneously. S3 stores the state file remotely. DynamoDB provides a lock: when anyone runs `terraform apply`, it writes a lock entry to the table. A second simultaneous apply fails with a "lock" error rather than corrupting state.

**Why `encrypt = true`?** Terraform state contains sensitive values (RDS endpoint, secret ARNs). Encryption at rest ensures the S3 object is unreadable without AWS KMS access.

**Bootstrap process:** Run `scripts/bootstrap-tf-state.sh us-west-1` once. It creates the S3 bucket (versioning on, encryption on) and DynamoDB table, then prints the values to paste into this file. Then run `terraform init -migrate-state` to upload local state to S3.

---

### `variables.tf` — Input Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `aws_region` | string | `us-west-1` | Region for all resources |
| `environment` | string | `prod` | Applied as `Environment` tag on every resource via `default_tags` |
| `domain` | string | *(required)* | Primary domain for ACM cert and Ingress host rules |
| `github_repo` | string | *(required)* | `owner/repo` format — scopes the OIDC trust policy to this exact repo |

**Why no default for `domain` and `github_repo`?** These are environment-specific with no safe default. Terraform forces you to set them in `terraform.tfvars` or via `-var` flag, preventing accidental deployment with wrong values.

**`terraform.tfvars` (actual values):**
```hcl
aws_region  = "us-west-1"
domain      = "b17facebook.xyz"
github_repo = "KANDUKURIsaikrishna/aws_three_tier_code"
```

---

### `main.tf` — Root Module Wiring

This file contains the provider configuration and calls every module. No resources are defined here directly — all resources live inside modules.

**AWS provider `default_tags` block:**
```hcl
default_tags {
  tags = {
    Project     = "bookstore"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
```
Every resource automatically inherits these tags. This means you can filter all bookstore resources in the AWS console with `Project=bookstore`, or set up cost allocation tags without tagging each resource manually.

**Helm provider exec auth:**
```hcl
provider "helm" {
  kubernetes {
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}
```
The Helm provider needs to authenticate with the EKS cluster to install charts. Instead of embedding a static kubeconfig, it runs `aws eks get-token` at apply time to get a short-lived token. This requires the machine running Terraform (or GitHub Actions runner) to have AWS credentials — the same role used for all other Terraform operations.

---

### `outputs.tf` — Root Outputs

Outputs expose values that are useful after `terraform apply` without requiring you to dig through state.

| Output | Sensitive | What to use it for |
|--------|-----------|-------------------|
| `vpc_id` | No | Pass to other tools, verify in AWS console |
| `rds_endpoint` | No | Connect to RDS manually for debugging |
| `rds_secret_arn` | **Yes** | ARN of `/bookstore/db-credentials` — contains DB_USERNAME, DB_PASSWORD, DB_HOST |
| `frontend_repo_url` | No | Build and push Docker images manually |
| `backend_repo_url` | No | Build and push Docker images manually |
| `eks_cluster_name` | No | Run `aws eks update-kubeconfig` |
| `eks_cluster_endpoint` | No | API server URL for kubectl |
| `eks_oidc_provider_arn` | No | Create IRSA roles for service accounts |
| `github_oidc_role_arn` | No | Paste into `AWS_ROLE_ARN` GitHub Secret |

**Why `sensitive = true` on `rds_secret_arn`?** The ARN reveals your account ID and secret name. Marking it sensitive prevents Terraform from printing it in plan/apply output and CI logs.

---

### `iam.tf` — GitHub Actions OIDC Role

This file solves the "how does GitHub Actions authenticate with AWS?" problem without ever creating a static access key.

**How OIDC works:**

```
GitHub Actions runner starts job
         │
         ▼
GitHub mints a short-lived OIDC token (JWT)
signed by https://token.actions.githubusercontent.com
         │
         ▼
GitHub Actions step calls aws-actions/configure-aws-credentials
which sends the JWT to AWS STS: "I want to assume this role"
         │
         ▼
AWS STS validates the JWT signature against the OIDC provider
checks the trust policy conditions (audience, repo subject)
         │
         ▼
STS returns temporary credentials (expire in ~1 hour)
Pipeline uses them for the rest of the job
```

**Trust policy conditions:**
```hcl
Condition = {
  StringEquals = {
    "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
  }
  StringLike = {
    "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
  }
}
```
The `sub` (subject) claim in the JWT is `repo:owner/name:ref:refs/heads/main` or similar. Using `StringLike` with a wildcard allows any branch/tag of the repo to assume the role, but no other repository can.

**Why `bookstore-*` in the ECR policy resource ARN?**
```hcl
Resource = "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/bookstore-*"
```
The role can only push to ECR repositories whose names start with `bookstore-`. Even if the credentials were somehow leaked, they cannot be used to push to any other ECR repository in the account.

**Prerequisite (one-time, outside Terraform):** The GitHub OIDC provider must be registered in AWS IAM before Terraform can reference it. Terraform creates the IAM role that trusts the provider, but it cannot create the provider itself without a chicken-and-egg problem. Run this once per AWS account:
```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

---

## Modules

### `modules/network/` — VPC and Subnets

**What it creates:**

```
VPC  170.20.0.0/16
 │
 ├── Public Subnet [0]  170.20.1.0/24  us-west-1a  ─┐
 ├── Public Subnet [1]  170.20.2.0/24  us-west-1c  ─┤── Internet Gateway
 │                                                   ┘   (route 0.0.0.0/0 → IGW)
 │
 ├── Private Subnet [0]  170.20.3.0/24  us-west-1a  ─┐
 ├── Private Subnet [1]  170.20.4.0/24  us-west-1c  ─┤── EKS nodes
 ├── Private Subnet [2]  170.20.5.0/24  us-west-1a  ─┤
 ├── Private Subnet [3]  170.20.6.0/24  us-west-1c  ─┘
 │                                                      (route 0.0.0.0/0 → NAT)
 ├── Private Subnet [4]  170.20.7.0/24  us-west-1a  ─┐
 └── Private Subnet [5]  170.20.8.0/24  us-west-1c  ─┘── RDS (isolated, no NAT needed)
```

**Resources:**

| Resource | Purpose |
|----------|---------|
| `aws_vpc.main` | Container for all network resources. `enable_dns_support` + `enable_dns_hostnames` are required for EKS nodes to resolve AWS service endpoints and for RDS to get DNS names. |
| `aws_subnet.public` | Created with `map_public_ip_on_launch = true` so instances get a public IP automatically. The NLB (ingress-nginx) lives here. |
| `aws_subnet.private` | No public IPs. EKS nodes and RDS live here. Outbound traffic goes through NAT. |
| `aws_internet_gateway.igw` | Attaches the VPC to the internet. Required for the public subnets to be reachable. |
| `aws_eip.nat` | A static public IP assigned to the NAT Gateway. Outbound traffic from private subnets appears to come from this IP. |
| `aws_nat_gateway.nat` | Placed in public subnet[0]. Allows private subnet resources (EKS nodes) to reach the internet (to pull images, call AWS APIs) without being reachable from the internet. **Single NAT** — cost optimized; for HA you'd add one per AZ. |
| `aws_route_table.public` | Routes `0.0.0.0/0` → IGW. Associated with both public subnets. |
| `aws_route_table.private` | Routes `0.0.0.0/0` → NAT. Associated with all 6 private subnets. |

**Why is the CIDR `170.20.0.0/16`?** Standard RFC 1918 private ranges are 10.x, 172.16–31.x, and 192.168.x. `170.20.0.0/16` is technically a public range but is used here for the private VPC to avoid conflicts with VPNs and peered networks that might use common 10.x addresses. The `/16` gives 65,536 IPs — far more than this project needs but common practice.

**Why 4 private subnets for EKS and only 2 for RDS?** EKS needs subnets in multiple AZs for the managed node group to schedule pods across AZs. 4 subnets (2 AZs × 2 subnets each) give the cluster room to grow without subnet IP exhaustion. RDS Multi-AZ only needs one subnet per AZ — 2 is the minimum.

---

### `modules/security/` — Security Groups

Two security groups control network access at the AWS level (before Kubernetes NetworkPolicies even apply).

**`alb_frontend` Security Group (used by ingress-nginx NLB):**

| Rule | Direction | Port | Source | Reason |
|------|-----------|------|--------|--------|
| `alb_http_in` | Ingress | 80 | 0.0.0.0/0 | Accept HTTP — Nginx Ingress redirects to HTTPS |
| `alb_https_in` | Ingress | 443 | 0.0.0.0/0 | Accept HTTPS from any browser |
| `alb_egress` | Egress | all | 0.0.0.0/0 | NLB forwards to EKS nodes on any port |

**`rds` Security Group (used by RDS MySQL):**

| Rule | Direction | Port | Source | Reason |
|------|-----------|------|--------|--------|
| `rds_mysql_in` | Ingress | 3306 | VPC CIDR `170.20.0.0/16` | Only EKS nodes inside the VPC can connect |
| `rds_egress` | Egress | all | 0.0.0.0/0 | RDS needs outbound for backups, monitoring |

**Why VPC CIDR as source for RDS instead of the EKS node security group?** Using the VPC CIDR is a deliberate simplification for this demo — it means any resource inside the VPC can reach RDS on port 3306, not just EKS nodes. For production, you'd reference the EKS node security group ID directly (`from_port=3306, source_security_group_id = module.eks.node_sg_id`) to tightly scope access.

**Why are security group rules separate resources instead of inline?** AWS security group rules defined inline in the `aws_security_group` resource conflict when two modules reference each other's SGs (circular dependency). Separate `aws_security_group_rule` resources avoid this.

---

### `modules/acm/` — TLS Certificate

```hcl
resource "aws_acm_certificate" "this" {
  domain_name               = var.domain_name          # "b17facebook.xyz"
  subject_alternative_names = var.san_names            # ["*.b17facebook.xyz"]
  validation_method         = "DNS"
  lifecycle { create_before_destroy = true }
}
```

**Why DNS validation instead of email?** DNS validation creates a CNAME record in Route 53. Once the record exists, ACM renews the certificate automatically before it expires — no human action required. Email validation requires someone to click a link every 13 months.

**Why `*.b17facebook.xyz` as a SAN?** The wildcard covers `bookstore.b17facebook.xyz` (frontend) and `api.bookstore.b17facebook.xyz` (backend API) with a single certificate. Adding more subdomains later requires no certificate changes.

**Why `create_before_destroy = true`?** If you change the domain and Terraform needs to replace the certificate, it creates the new one first, then destroys the old one. Without this lifecycle rule, Terraform destroys the old cert first — but the NLB listener still references it, causing a brief outage.

**Manual step after `terraform apply`:** You must add the validation CNAME records to your DNS provider. ACM creates the CNAME values but cannot add them to your domain registrar. Check `terraform output` or the ACM console for the exact CNAME name and value.

---

### `modules/rds/` — MySQL Database

```hcl
resource "random_password" "db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}?"
}

resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "/bookstore/db-credentials"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    DB_USERNAME = var.db_username
    DB_PASSWORD = random_password.db_password.result
    DB_HOST     = aws_db_instance.db.endpoint
  })
}

resource "aws_db_instance" "db" {
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = "db.t3.micro"

  username = var.db_username
  password = random_password.db_password.result

  multi_az                    = true   # standby replica in second AZ
  storage_encrypted           = true   # AES-256 via KMS

  backup_retention_period = 7          # 7 days of point-in-time recovery
  skip_final_snapshot     = true       # no snapshot on destroy (dev convenience)
  deletion_protection     = false      # intentional for demo — enable for prod
  publicly_accessible     = false      # no public endpoint

  monitoring_interval = 60             # Enhanced Monitoring every 60 seconds
  enabled_cloudwatch_logs_exports = ["error", "general", "slowquery"]
}
```

**`random_password`** — Generates a 32-char cryptographically random password at `terraform apply` time. Stored in TF state (encrypted at rest in S3). For higher security, swap for Vault or AWS Secrets Manager rotation — but for this demo level the trade-off is acceptable.

**`aws_secretsmanager_secret` at `/bookstore/db-credentials`** — Created by Terraform in the same apply as RDS. Holds all three connection values: `DB_USERNAME`, `DB_PASSWORD`, and `DB_HOST` (the RDS endpoint). ESO reads this path directly — no manual secret creation needed.

To inspect after apply:
```bash
aws secretsmanager get-secret-value \
  --secret-id /bookstore/db-credentials \
  --region us-west-1 \
  --query SecretString --output text | jq
```

**`multi_az = true`** — RDS maintains a synchronous standby replica in a different AZ. If the primary fails (AZ outage, hardware failure), RDS automatically promotes the standby. Failover typically takes 60–120 seconds. The endpoint DNS name stays the same — your application reconnects automatically.

**`storage_encrypted = true`** — Encrypts the EBS volume backing RDS with a KMS key. Data at rest is unreadable without the key. Required for most compliance frameworks (SOC 2, HIPAA, PCI-DSS).

**Enhanced Monitoring IAM role** — RDS Enhanced Monitoring runs an agent on the DB host that collects OS-level metrics (CPU, memory, I/O per process) at intervals as short as 1 second. It needs its own IAM role (`monitoring.rds.amazonaws.com`) with the `AmazonRDSEnhancedMonitoringRole` policy to publish metrics to CloudWatch Logs.

**Why `skip_final_snapshot = true`?** For a demo you repeatedly destroy and recreate the database. A final snapshot would fail on the second `terraform destroy` because a snapshot with the same name already exists. For production, set this to `false` so RDS takes a final backup before deletion.

---

### `modules/ecr/` — Container Registries

```hcl
locals {
  repos = ["bookstore-frontend", "bookstore-backend"]
}

resource "aws_ecr_repository" "this" {
  for_each             = toset(local.repos)
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration    { encryption_type = "AES256" }
}

resource "aws_ecr_lifecycle_policy" "this" {
  # Keep last 10 images, expire older ones
}
```

**`image_tag_mutability = "IMMUTABLE"`** — Once an image is pushed with tag `abc12345`, that tag cannot be overwritten with a different image. This is critical for GitOps: the image tag in `kustomization.yaml` must always refer to exactly the image that was scanned and approved. Without immutability, someone could push a different image under the same tag and bypass the Trivy scan.

**`scan_on_push = true`** — ECR runs a basic CVE scan (using Clair) every time an image is pushed. This is in addition to the Trivy scan in the CI pipeline. Two independent scan sources.

**`encryption_type = "AES256"`** — Images at rest in ECR are encrypted with AES-256 using an AWS-managed key. For stricter key control you'd use `encryption_type = "KMS"` with your own KMS key.

**`force_delete = true`** — Normally ECR refuses to delete a non-empty repository. `force_delete = true` allows `terraform destroy` to delete the repositories even if they contain images. Necessary for this demo project.

**Lifecycle policy** — Without this, ECR storage grows forever. The policy keeps only the 10 most recent images (by count) and deletes older ones. With 2 images per deploy (frontend + backend), you keep ~5 deploys of history.

---

### `modules/eks/` — Kubernetes Cluster

This is the most complex module. It creates the EKS control plane, OIDC provider, and worker node group — plus all the IAM roles and policies they need.

#### Cluster IAM Role

```hcl
resource "aws_iam_role" "cluster" {
  # Trust: eks.amazonaws.com can assume this role
  # Policy: AmazonEKSClusterPolicy + AmazonEKSVPCResourceController
}
```

EKS control plane needs permission to call AWS APIs on your behalf — to manage ENIs for pods (VPC CNI), to create load balancers for Services, to describe EC2 instances. The `AmazonEKSClusterPolicy` grants these permissions. `AmazonEKSVPCResourceController` allows EKS to manage network interfaces for security groups for pods.

#### EKS Cluster Resource

```hcl
resource "aws_eks_cluster" "this" {
  name    = "bookstore-eks"
  version = "1.31"

  vpc_config {
    subnet_ids              = var.subnet_ids      # private subnets [0-3]
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}
```

**`endpoint_private_access = true`** — Nodes inside the VPC communicate with the Kubernetes API server over a private endpoint (stays inside AWS network, faster, no internet hop).

**`endpoint_public_access = true`** — You can run `kubectl` from your laptop. For maximum security you'd set this to `false` and require a VPN or bastion host, but for a dev/learning project public access is convenient.

**`enabled_cluster_log_types`** — Sends EKS control plane logs to CloudWatch Logs. These logs are essential for debugging authentication failures, API server errors, and scheduler decisions. Without them you're blind when something goes wrong at the cluster level.

#### OIDC Provider

```hcl
resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}
```

This enables **IRSA (IAM Roles for Service Accounts)** — the mechanism that lets Kubernetes pods assume AWS IAM roles without access keys.

How it works:
1. EKS has a built-in OIDC issuer endpoint that issues JWTs for service accounts
2. This resource registers that endpoint as a trusted identity provider in AWS IAM
3. When a pod with the right service account annotation calls AWS APIs, it presents its service account JWT to STS
4. STS validates the JWT against the OIDC provider and returns temporary credentials

The External Secrets Operator uses IRSA to assume a role that can read from Secrets Manager.

#### Node Group IAM Role

```hcl
resource "aws_iam_role" "node_group" {
  # Trust: ec2.amazonaws.com
  # Policies:
  #   AmazonEKSWorkerNodePolicy  — describe cluster, register with control plane
  #   AmazonEKS_CNI_Policy       — manage ENIs for VPC CNI networking
  #   AmazonEC2ContainerRegistryReadOnly — pull images from ECR
}
```

Every EKS worker node needs these three policies. Without `AmazonEC2ContainerRegistryReadOnly`, nodes cannot pull your container images from ECR and every pod would fail to start.

#### Managed Node Group

```hcl
resource "aws_eks_node_group" "this" {
  instance_types = ["t3.medium"]   # 2 vCPU, 4 GB RAM
  ami_type       = "AL2_x86_64"   # Amazon Linux 2, x86_64

  scaling_config {
    min_size     = 1
    max_size     = 2
    desired_size = 1
  }

  update_config {
    max_unavailable = 1   # rolling update — always keep N-1 nodes running
  }
}
```

**Why `t3.medium`?** The smallest instance that can comfortably run all add-ons (cert-manager, ESO, ingress-nginx, ArgoCD, Prometheus, Grafana, Argo Rollouts) plus the application pods simultaneously. Smaller types (t3.small, t3.micro) run out of memory with this many pods.

**`max_unavailable = 1` in update_config** — During a node group version update (e.g., upgrading Kubernetes), EKS drains and terminates nodes one at a time. With max 2 nodes, this means you always have at least 1 node running.

**`ami_type = "AL2_x86_64"`** — Specifies Amazon Linux 2 for x86_64. Required when EKS managed node groups are used — without this, Terraform rejects the configuration.

---

### `modules/eks-addons/` — Helm Releases

This module installs all Kubernetes add-ons via Terraform's Helm provider. Previously these were installed manually by `eks_bootstrap.py`.

#### EBS CSI Driver

```hcl
resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  role       = var.node_role_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  addon_name = "aws-ebs-csi-driver"
  depends_on = [aws_iam_role_policy_attachment.ebs_csi_policy]
}
```

**Why EBS CSI driver?** The default Kubernetes in-tree volume plugin for EBS is deprecated since Kubernetes 1.23. The CSI driver is the supported replacement. It allows Kubernetes PersistentVolumeClaims to provision EBS volumes dynamically. The MySQL StatefulSet uses a PVC — without the CSI driver, the MySQL pod would be stuck `Pending` because no volume can be created.

**Why attach policy to node role instead of using IRSA here?** The EBS CSI driver DaemonSet runs on every node. Using node IAM role is simpler for a demo. Production deployments use IRSA for least-privilege isolation.

#### cert-manager

Installs the cert-manager controller into the `cert-manager` namespace. cert-manager watches for `Certificate` and `ClusterIssuer` resources and automatically provisions TLS certificates from Let's Encrypt (or other CAs). It handles ACME challenge (DNS-01), certificate rotation, and stores certs as Kubernetes Secrets. The Ingress annotation `cert-manager.io/cluster-issuer: letsencrypt-prod` tells cert-manager to issue a cert for that Ingress automatically.

#### External Secrets Operator (ESO)

ESO bridges AWS Secrets Manager and Kubernetes Secrets. It watches `ExternalSecret` CRDs and periodically fetches the referenced secret from AWS, then writes it as a Kubernetes Secret. This means database credentials never appear in git, in the CI pipeline, or in Kubernetes YAML — they are fetched at runtime from Secrets Manager using IRSA permissions.

#### ingress-nginx

Installs the Nginx Ingress Controller as a Deployment with a Kubernetes Service of type `LoadBalancer`. AWS automatically provisions a Network Load Balancer (NLB) for that Service. The NLB is the single public entry point for all HTTP/HTTPS traffic. The controller reads `Ingress` resources and configures Nginx accordingly.

`controller.replicaCount = 1` — Single controller replica for cost. Production deployments would run 2+ replicas.

#### kube-prometheus-stack

Installs Prometheus (metrics collection), Grafana (dashboards), and all supporting CRDs (`ServiceMonitor`, `PodMonitor`, etc.) in a single Helm chart.

Settings applied:
- `alertmanager.enabled = false` — AlertManager is a separate system (email/Slack alerts). Skipped for demo.
- `grafana.persistence.enabled = false` — Grafana dashboards are ephemeral. Persist to EBS for production.
- `prometheus.prometheusSpec.retention = 24h` — 24-hour metric retention. Reduces disk usage dramatically on a single node. Production: 15d–30d with EBS storage.

The backend exposes `/metrics` in Prometheus text format via `prom-client`. A `ServiceMonitor` in `k8s/base/monitoring/` tells Prometheus to scrape that endpoint.

#### Argo Rollouts

Progressive delivery controller. Replaces Kubernetes `Deployment` with `Rollout` CRD that supports canary, blue/green, and analysis-based deployments. The backend uses a canary strategy: 10% traffic → 30s pause → 50% → 30s pause → 100%. If any step fails a health check, Argo Rollouts automatically rolls back to the previous stable version.

#### ArgoCD

GitOps continuous delivery engine. ArgoCD watches the `k8s/overlays/prod/` directory in the GitHub repo. When the CI pipeline commits a new image tag to `kustomization.yaml`, ArgoCD detects the change (poll interval ~3 minutes) and applies the diff to the `bookstore` namespace. `selfHeal: true` ensures manual `kubectl` edits are reverted — the git repo is the single source of truth.

---

### `modules/route53/` — Private DNS Zone

```hcl
resource "aws_route53_zone" "rds_private" {
  name = "rds.com"           # internal-only zone
  vpc { vpc_id = var.vpc_id }
}

resource "aws_route53_record" "rds_endpoint" {
  name    = "book.rds.com"
  type    = "CNAME"
  records = [var.rds_endpoint]   # e.g. bookstore-db.xxx.us-west-1.rds.amazonaws.com
}
```

**Why a private hosted zone?** The RDS endpoint (`bookstore-db.xxx.us-west-1.rds.amazonaws.com`) is long and environment-specific. A private CNAME `book.rds.com` is short and stable — if the RDS instance is replaced, only the CNAME record changes, not the application config.

**Why `rds.com` as zone name?** A real domain isn't needed for a private zone — it only resolves within the VPC. Using `rds.com` is an arbitrary choice. The zone is private: DNS resolution for `book.rds.com` only works from resources inside the VPC.

**Current state:** The application ConfigMap still uses `DB_HOST: "mysql-service"` (in-cluster MySQL). To switch to RDS, update `k8s/base/configmaps/backend-config.yaml` to `DB_HOST: "book.rds.com"`.

---

## Dependency Graph

```
versions.tf
    │
main.tf
    │
    ├── module.network
    │       └─── outputs: vpc_id, public_subnet_ids, private_subnet_ids
    │
    ├── module.security_groups (needs vpc_id)
    │       └─── outputs: rds_sg_id, alb_sg_id
    │
    ├── module.acm (independent)
    │
    ├── module.rds (needs rds_sg_id, private_subnet_ids[4,5])
    │       └─── outputs: rds_endpoint, db_credentials_secret_arn
    │
    ├── module.route53 (needs vpc_id, rds_endpoint)
    │
    ├── module.ecr (independent)
    │       └─── outputs: frontend_repo_url, backend_repo_url
    │
    ├── module.eks (needs vpc_id, private_subnet_ids[0-3])
    │       └─── outputs: cluster_name, cluster_endpoint, oidc_provider_arn, node_role_name
    │
    ├── module.eks_addons (needs cluster_name, oidc_provider_arn, node_role_name)
    │       depends_on = [module.eks]
    │
    └── aws_iam_role.github_oidc (needs data.aws_caller_identity)
            └─── outputs: github_oidc_role_arn
```

Terraform resolves this graph automatically and parallelizes independent modules. `module.acm`, `module.ecr`, and the security groups all start in parallel. `module.eks_addons` waits until `module.eks` completes.

---

## How to Use

### First-time setup

```bash
# 1. Create S3 + DynamoDB for remote state
./scripts/bootstrap-tf-state.sh us-west-1

# 2. Fill in versions.tf backend block with the printed values
# Then:
terraform init

# 3. Preview what will be created
terraform plan

# 4. Create all infrastructure (~20 minutes)
terraform apply
```

### After apply — key outputs

```bash
terraform output eks_cluster_name       # bookstore-eks
terraform output eks_cluster_endpoint   # https://...
terraform output rds_endpoint           # bookstore-db.xxx.us-west-1.rds.amazonaws.com
terraform output -raw rds_secret_arn    # arn:aws:secretsmanager:...
terraform output github_oidc_role_arn   # paste into AWS_ROLE_ARN GitHub Secret
```

### Configure kubectl

```bash
aws eks update-kubeconfig --name bookstore-eks --region us-west-1
kubectl get nodes   # verify connection
```

### Destroy everything

```bash
terraform destroy
# Warning: this deletes VPC, EKS, RDS (no final snapshot — skip_final_snapshot=true)
```
