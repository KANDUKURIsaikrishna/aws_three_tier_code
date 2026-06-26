# Terraform Infrastructure — Complete Guide for Beginners

This document explains every piece of AWS infrastructure that Terraform creates for the Bookstore application. No prior cloud or DevOps knowledge assumed.

---

## What is Terraform?

Normally, to create AWS infrastructure, you'd click through the AWS web console — create a VPC here, add a subnet there, configure a database, etc. This is slow, error-prone, and impossible to reproduce exactly.

**Terraform** lets you describe your entire infrastructure in text files (`.tf` files), then automatically creates it in AWS. This is called **Infrastructure as Code (IaC)**.

Benefits:
- **Reproducible** — run the same code in 10 different AWS accounts, get identical results
- **Version controlled** — infrastructure changes are git commits with history, blame, and review
- **Auditable** — see exactly what changed, when, and who approved it
- **Reversible** — `terraform destroy` tears everything down cleanly

### How Terraform Works

```
.tf files (what you want)
        │
        ▼
terraform plan  → shows a diff: what will be CREATED / CHANGED / DESTROYED
        │
        ▼
terraform apply → actually creates resources in AWS
        │
        ▼
terraform.tfstate → file recording what currently exists (the "current state")
```

Terraform always compares **desired state** (your `.tf` files) with **current state** (what's actually in AWS) and only changes what's different.

---

## Project Structure

```
main.tf                    ← Root: wires all modules together
modules/
├── network/               ← VPC, subnets, routing
├── security/              ← Firewall rules (security groups)
├── acm/                   ← SSL/TLS certificate
├── rds/                   ← MySQL database
├── route53/               ← Internal DNS
├── ecr/                   ← Docker image registry
└── eks/                   ← Kubernetes cluster
scripts/
└── bootstrap-tf-state.sh  ← One-time setup: creates S3 bucket + DynamoDB table
```

### What is a Module?

A module is a reusable chunk of Terraform code. Instead of writing all 500+ lines in one file, this project splits infrastructure into logical modules. Each module has:
- `main.tf` — the actual resources to create
- `variables.tf` — inputs (like function arguments)
- `output.tf` — outputs (like return values, shared with other modules)

Think of modules like functions in programming. `main.tf` is the "main program" that calls those functions and passes arguments.

---

## Before You Run Terraform: Remote State (bootstrap-tf-state.sh)

Before the first `terraform init`, run this script once:

```bash
./scripts/bootstrap-tf-state.sh us-west-1
```

### Why is this needed?

Terraform records what infrastructure exists in a **state file** (`terraform.tfstate`). By default this is a local file on your laptop — which is a problem:
- If your laptop dies, you lose the state
- If two people run Terraform simultaneously, they corrupt each other's state

The bootstrap script creates two AWS resources to fix this:

#### 1. S3 Bucket — stores the state file remotely

```bash
BUCKET="bookstore-terraform-state-${ACCOUNT_ID}"
```

Configured with:
- **Versioning enabled** — every state change is saved, you can roll back
- **Encryption at rest (AES256)** — the state file contains sensitive info (like DB endpoints)
- **All public access blocked** — only your AWS account can read it

#### 2. DynamoDB Table — prevents simultaneous runs

```
TABLE="terraform-state-lock"
```

When `terraform apply` starts, it writes a **lock record** to this DynamoDB table. If a second person tries to run Terraform at the same time, they see the lock and are blocked with an error. When the first run finishes, the lock is released.

This prevents two engineers from applying conflicting changes simultaneously — like two people editing the same Google Doc without merging.

---

## Module 1: Network (`modules/network/`)

**What it creates:** The private network (VPC) inside AWS where everything lives.

### What is a VPC?

A **VPC** (Virtual Private Cloud) is your own isolated section of AWS's network. Think of AWS as a giant apartment building. Your VPC is your apartment — you own it, you decide the layout, and nothing from outside can enter unless you explicitly allow it.

```
VPC: 170.20.0.0/16  (65,536 possible IP addresses)
```

The `/16` is CIDR notation — it defines the size of the network. Don't worry about the math — `/16` means "large network."

### Subnets — Dividing the Network

Inside the VPC, the network is divided into **subnets** — smaller segments for different purposes:

```
VPC (170.20.0.0/16)
│
├── PUBLIC SUBNETS (2 subnets — reachable from internet)
│   ├── public-subnet-1  170.20.1.0/24  us-west-1a  ← Load balancer lives here
│   └── public-subnet-2  170.20.2.0/24  us-west-1c  ← Load balancer (backup AZ)
│
└── PRIVATE SUBNETS (6 subnets — NOT reachable from internet)
    ├── private-subnet-3  170.20.3.0/24  us-west-1a  ← EKS worker nodes
    ├── private-subnet-4  170.20.4.0/24  us-west-1c  ← EKS worker nodes
    ├── private-subnet-5  170.20.5.0/24  us-west-1a  ← EKS worker nodes
    ├── private-subnet-6  170.20.6.0/24  us-west-1c  ← EKS worker nodes
    ├── private-subnet-7  170.20.7.0/24  us-west-1a  ← RDS database
    └── private-subnet-8  170.20.8.0/24  us-west-1c  ← RDS database (backup AZ)
```

**Why two AZs?** AZ = Availability Zone = physically separate data centers within a region. If `us-west-1a` has a power outage, `us-west-1c` keeps running. Spreading across two AZs gives **high availability**.

**Why are app servers in private subnets?** Your Node.js backend and database should never be directly reachable from the internet. Only the load balancer (in public subnets) accepts internet traffic, and it forwards it to private subnets. This is a core security principle.

### Internet Gateway (IGW)

```
Internet → Internet Gateway → Public Subnet
```

The **Internet Gateway** is the door between the internet and your VPC's public subnets. Only things in public subnets can use it.

### NAT Gateway

```
Private Subnet → NAT Gateway (in public subnet) → Internet
```

Servers in private subnets can't receive traffic from the internet. But they still need to reach the internet to download updates, pull Docker images, call AWS APIs, etc.

The **NAT Gateway** sits in a public subnet and acts as a proxy. Private servers send traffic out through it, the response comes back to the NAT Gateway, and it forwards it back. The internet never sees the private server's IP address — it only sees the NAT Gateway's public IP (Elastic IP).

### Route Tables

A **route table** is like a road sign — it tells network traffic where to go.

```
Public Route Table:
  Destination: 0.0.0.0/0 (anywhere) → Go through Internet Gateway

Private Route Table:
  Destination: 0.0.0.0/0 (anywhere) → Go through NAT Gateway
```

Every subnet is associated with a route table. Public subnets use the public route table, private subnets use the private route table.

---

## Module 2: Security Groups (`modules/security/`)

**What it creates:** Firewall rules that control which traffic is allowed into each AWS resource.

A **Security Group** is a virtual firewall attached to an individual resource. Unlike traditional firewalls (which protect a network perimeter), security groups follow each resource around — even if you move a server to a different subnet, its firewall rules move with it.

### ALB Security Group (for the Load Balancer)

```
INGRESS (traffic coming IN):
  Port 80  (HTTP)  from 0.0.0.0/0  → allow anyone to visit the website over HTTP
  Port 443 (HTTPS) from 0.0.0.0/0  → allow anyone to visit the website over HTTPS

EGRESS (traffic going OUT):
  All ports, all destinations → allow outbound to forward requests to app servers
```

### RDS Security Group (for the Database)

```
INGRESS (traffic coming IN):
  Port 3306 (MySQL) from 170.20.0.0/16 → ONLY from within your VPC
                                          (not from the internet, not from other accounts)

EGRESS (traffic going OUT):
  All ports, all destinations → allow outbound responses
```

This is defense in depth — even if an attacker somehow reached your private subnet, the database still won't accept their connection because the security group only allows traffic from within your own VPC's IP range.

---

## Module 3: ACM Certificate (`modules/acm/`)

**What it creates:** An SSL/TLS certificate so your website loads over `https://`.

### Why HTTPS matters

When you visit a website over HTTP, all data (login forms, personal info) travels as plain text. Anyone between you and the server (your ISP, a coffee shop router) can read it.

HTTPS encrypts all traffic using a certificate. The certificate proves that `yourdomain.com` is actually your server, and encrypts everything between the user's browser and your load balancer.

### How it works here

```hcl
resource "aws_acm_certificate" "b17facebook_cert" {
  domain_name               = var.domain_name        # e.g. "example.com"
  validation_method         = "DNS"                  # prove ownership via DNS record
  subject_alternative_names = var.san_names          # also covers "*.example.com"
}
```

**DNS validation** — AWS asks you to add a specific DNS record to your domain. Once you add it, AWS confirms you own the domain and issues the certificate. Terraform's `create_before_destroy` lifecycle setting means when renewing the cert, the new one is created before the old one is destroyed — so there's no downtime.

---

## Module 4: RDS Database (`modules/rds/`)

**What it creates:** A managed MySQL 8.0 database hosted by AWS (RDS = Relational Database Service).

### Why use RDS instead of running MySQL yourself?

Running a database yourself on a server means you have to: install it, patch it, back it up, handle failures, set up replication for high availability. That's a full-time job.

RDS handles all of that for you. You just say "I want a MySQL 8.0 database with 25GB storage" and AWS runs it.

### Key features configured

#### Multi-AZ (High Availability)

```hcl
multi_az = true
```

RDS creates **two database instances** — a primary in `us-west-1a` and a standby in `us-west-1c`. They are kept in sync at all times.

If the primary fails (hardware failure, AZ outage), AWS automatically promotes the standby to primary. This failover takes about 60-120 seconds — your application automatically reconnects. No data is lost.

```
Normal:     App → Primary DB (us-west-1a) ← synchronously replicates → Standby (us-west-1c)
Failure:    Primary dies → Standby promoted to Primary → App reconnects → no data loss
```

#### Password managed by AWS Secrets Manager

```hcl
manage_master_user_password = true
```

No database password is written in Terraform code or stored in the state file. AWS generates a strong random password and stores it in **AWS Secrets Manager** — an encrypted secret vault. The application retrieves the password at runtime via the ExternalSecret Kubernetes resource. This means:
- Password never appears in git history
- Password can be rotated without code changes
- Access to the password is audited (CloudTrail logs every retrieval)

#### Encryption at rest

```hcl
storage_encrypted = true
```

The database files on disk are encrypted with AES-256. Even if someone physically removed the hard drive from AWS's data center, the data would be unreadable.

#### Automated Backups

```hcl
backup_retention_period = 7
backup_window           = "03:00-04:00"
```

AWS automatically backs up the database every day at 3 AM UTC. The last 7 days of backups are retained. You can restore to **any point in time within those 7 days** (Point-In-Time Recovery) — not just the daily snapshots, but any second within the window.

#### Enhanced Monitoring

```hcl
monitoring_interval = 60  # collect metrics every 60 seconds
enabled_cloudwatch_logs_exports = ["error", "general", "slowquery"]
```

RDS sends metrics (CPU, memory, connections, I/O) to CloudWatch every minute. It also exports MySQL logs — error logs for debugging, general logs for auditing, and **slowquery logs** for identifying queries that are taking too long.

#### Not publicly accessible

```hcl
publicly_accessible = false
```

The database has no public IP address. It can only be reached from within the VPC — specifically only from resources with the RDS security group rule satisfied.

---

## Module 5: Route53 — Internal DNS (`modules/route53/`)

**What it creates:** A private DNS zone inside your VPC so the app can reach the database by a friendly name.

### The Problem

When RDS creates your database, it gives it an address like:
```
bookstore-db.c7abc123xyz.us-west-1.rds.amazonaws.com
```

This address changes if you ever recreate the database (e.g., after `terraform destroy` and `terraform apply`). If your app has this address hardcoded, it breaks every time you recreate the DB.

### The Solution

Create a stable internal DNS alias:
```
db.internal  →  bookstore-db.c7abc123xyz.us-west-1.rds.amazonaws.com
```

Now the app connects to `db.internal`. When you recreate the database and its address changes, you only update the Route53 CNAME record — the app doesn't need to change.

This DNS zone is **private** — it only works from inside the VPC. Nobody outside can look up `db.internal`.

---

## Module 6: ECR — Docker Image Registry (`modules/ecr/`)

**What it creates:** Two private repositories to store Docker images.

### What is ECR?

**ECR** (Elastic Container Registry) is AWS's private version of Docker Hub. Instead of pushing images to `hub.docker.com` (public), you push to your private ECR registry that only your AWS account can access.

```
CI Pipeline builds image → pushes to ECR → EKS pulls from ECR to run pods
```

Two repositories are created:
- `bookstore-frontend` — the React/Nginx image
- `bookstore-backend` — the Node.js/Express image

### Key settings

#### Immutable tags

```hcl
image_tag_mutability = "IMMUTABLE"
```

Once an image is pushed with tag `abc123de`, that tag can never be overwritten with a different image. If you try to push a different image with the same tag, it fails.

Why? Immutable tags guarantee that when you say "run version `abc123de`", Kubernetes runs **exactly** that image — not a silently replaced one. This prevents supply chain attacks where someone overwrites a trusted image tag with malicious content.

#### Scan on push

```hcl
image_scanning_configuration {
  scan_on_push = true
}
```

Every time an image is pushed to ECR, ECR automatically scans it for known CVEs (vulnerabilities) using Amazon Inspector. This is in addition to the Trivy scan done in the CI pipeline — a second layer of defense.

#### Lifecycle policy

```hcl
"Keep last 10 images"
```

Without a lifecycle policy, every image ever pushed accumulates forever, and ECR charges for storage. This policy automatically deletes images older than the last 10, keeping costs controlled.

#### Encryption

```hcl
encryption_configuration {
  encryption_type = "AES256"
}
```

Images stored in ECR are encrypted at rest.

---

## Module 7: EKS — Kubernetes Cluster (`modules/eks/`)

**What it creates:** A fully managed Kubernetes cluster where your containers actually run.

### What is Kubernetes?

When you have one container to run, you just do `docker run`. But in production you have many containers, need to restart failed ones, scale up when traffic spikes, do zero-downtime updates, and spread load across multiple servers.

**Kubernetes** automates all of that. It's an orchestration system — you tell it what to run and how many, and it figures out where and manages their lifecycle.

**EKS** (Elastic Kubernetes Service) is AWS's managed Kubernetes — AWS handles the control plane (the brain of Kubernetes), you just manage the worker nodes (the machines that actually run containers).

### What gets created

#### Cluster IAM Role

```hcl
resource "aws_iam_role" "cluster" {
  # Allows the EKS control plane to call AWS APIs on your behalf
  # (e.g., create load balancers, attach network interfaces)
}
```

AWS services need permission to do things. This IAM Role tells AWS: "The EKS control plane is allowed to manage VPC networking and node resources."

Two policies are attached:
- `AmazonEKSClusterPolicy` — core permissions for EKS to function
- `AmazonEKSVPCResourceController` — allows EKS to manage security groups and ENIs for pods

#### EKS Cluster

```hcl
resource "aws_eks_cluster" "this" {
  name    = "bookstore-eks"
  version = "1.31"

  vpc_config {
    subnet_ids              = [4 private subnets]
    endpoint_private_access = true   # cluster API reachable from within VPC
    endpoint_public_access  = true   # also reachable from internet (for kubectl from your laptop)
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}
```

All 5 Kubernetes control plane log types are enabled — these go to CloudWatch Logs:
- **api** — every API call made to the cluster
- **audit** — who did what, when (security audit trail)
- **authenticator** — IAM auth events
- **controllerManager** — how pods are scheduled and managed
- **scheduler** — scheduling decisions

#### OIDC Provider for EKS (IRSA)

```hcl
resource "aws_iam_openid_connect_provider" "eks" { ... }
```

This enables **IRSA** (IAM Roles for Service Accounts) — a way for individual Kubernetes pods to have their own AWS permissions without sharing credentials.

Example: The External Secrets pod (which reads from Secrets Manager) needs permission to call `secretsmanager:GetSecretValue`. Without IRSA, you'd give that permission to ALL pods on the node (over-permissioned). With IRSA, only the External Secrets pod gets that permission, and only when it runs inside your EKS cluster.

#### Node Group IAM Role

```hcl
resource "aws_iam_role" "node_group" {
  # Allows EC2 instances (the worker nodes) to join the EKS cluster
}
```

Four policies attached to worker nodes:
- `AmazonEKSWorkerNodePolicy` — allows nodes to connect to EKS control plane
- `AmazonEKS_CNI_Policy` — allows the networking plugin to set up pod networking
- `AmazonEC2ContainerRegistryReadOnly` — allows nodes to pull images from ECR
- `AmazonEBSCSIDriverPolicy` — allows nodes to attach EBS volumes (used by the EBS CSI driver add-on)

#### Managed Node Group

```hcl
resource "aws_eks_node_group" "this" {
  instance_types = ["t3.medium"]   # 2 vCPU, 4GB RAM each node
  ami_type       = "AL2_x86_64"   # Amazon Linux 2

  scaling_config {
    min_size     = 1   # never go below 1 node
    max_size     = 4   # auto-scale up to 4 nodes under load
    desired_size = 2   # normally run 2 nodes
  }

  update_config {
    max_unavailable = 1   # during node updates, only 1 node offline at a time
  }
}
```

**Managed** node group means AWS handles:
- Provisioning the EC2 instances
- OS patching
- Node upgrades (when you bump the Kubernetes version)
- Rolling out node replacements without downtime

**Auto-scaling:** When traffic increases and pods are waiting for resources, the Cluster Autoscaler (a Kubernetes add-on) tells AWS to add more nodes (up to `max_size = 4`). When traffic drops, it removes idle nodes (down to `min_size = 1`), saving cost.

---

## GitHub Actions OIDC Role (in main.tf)

**What it creates:** An IAM role that the CI/CD pipeline can assume without storing any AWS credentials.

This is covered in detail in [CICD_EXPLAINED.md](CICD_EXPLAINED.md) under "How Authentication Works." The Terraform code here creates the IAM role and attaches a policy that allows pushing to ECR repositories named `bookstore-*`.

```hcl
resource "aws_iam_role" "github_oidc" {
  # Trust policy: only GitHub Actions running on YOUR repo can assume this role
  Condition = {
    StringLike = {
      "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
    }
  }
}
```

The condition `repo:${var.github_repo}:*` means the role can only be assumed by workflows running inside your specific GitHub repository — not by workflows in other repos.

---

## How Modules Connect Together

Modules share data through outputs and inputs. Here's the dependency chain:

```
network module
   └── outputs: vpc_id, private_subnet_ids[], public_subnet_ids[]
         │
         ├──► security module (receives vpc_id)
         │       └── outputs: alb_sg_id, rds_sg_id
         │
         ├──► rds module (receives private_subnet_ids[4], [5] + rds_sg_id)
         │       └── outputs: rds_endpoint, master_user_secret_arn
         │
         ├──► eks module (receives vpc_id + private_subnet_ids[0-3])
         │       └── outputs: cluster_name, cluster_endpoint, oidc_provider_arn
         │
         └──► route53 module (receives vpc_id + rds_endpoint)

ecr module (standalone — no VPC dependency)
   └── outputs: frontend_repo_url, backend_repo_url

acm module (standalone — just needs domain name)
   └── outputs: acm_certificate_arn
```

This dependency graph matters — Terraform uses it to determine the order of resource creation. It won't try to attach the RDS security group before the security group exists. It builds the dependency tree from your code automatically.

---

## Complete Infrastructure Map

When `terraform apply` finishes, here's everything that exists in AWS:

```
AWS Account
└── VPC (170.20.0.0/16)
    │
    ├── Public Subnets (us-west-1a, us-west-1c)
    │   └── NAT Gateway (with Elastic IP)
    │   └── [Load Balancer — created by Kubernetes Ingress controller]
    │
    ├── Private Subnets — EKS (4 subnets across 2 AZs)
    │   └── EKS Worker Nodes (t3.medium × 2, scales to 4)
    │       └── Bookstore pods (frontend, backend, ArgoCD, etc.)
    │
    ├── Private Subnets — RDS (2 subnets across 2 AZs)
    │   └── RDS MySQL 8.0 — Primary (us-west-1a)
    │   └── RDS MySQL 8.0 — Standby (us-west-1c) [Multi-AZ]
    │
    ├── Internet Gateway (public traffic in)
    ├── Route Tables (public → IGW, private → NAT)
    └── Security Groups (ALB: 80/443 open, RDS: 3306 VPC-only)

├── ECR Repositories (outside VPC — regional service)
│   ├── bookstore-frontend (immutable tags, encrypted, scan on push)
│   └── bookstore-backend  (immutable tags, encrypted, scan on push)
│
├── ACM Certificate (covers domain + *.domain)
│
├── Route53 Private Zone (db.internal → RDS endpoint, VPC-only)
│
├── Secrets Manager (auto-managed RDS master password)
│
├── S3 Bucket (Terraform state file, versioned, encrypted)
├── DynamoDB Table (Terraform state lock)
│
└── IAM
    ├── EKS Cluster Role
    ├── EKS Node Group Role
    ├── RDS Monitoring Role
    └── GitHub Actions OIDC Role (ECR push only)
```

---

## Security Design Decisions

| Decision | Why |
|----------|-----|
| App servers in private subnets | Cannot be reached directly from internet — must go through load balancer |
| RDS in private subnets | Database has no public IP address, only reachable inside VPC |
| RDS security group: MySQL only from VPC CIDR | Even inside VPC, only traffic from your own address space reaches the DB |
| `manage_master_user_password = true` | No plaintext DB password anywhere in code, state, or git |
| `storage_encrypted = true` on RDS | Data unreadable if physical disk ever extracted |
| ECR `IMMUTABLE` tags | Image tags cannot be overwritten; prevents supply chain attacks |
| GitHub OIDC role with repo scope | Only YOUR repo's GitHub Actions can push images — no static AWS keys |
| IRSA for pod permissions | Each pod gets only the AWS permissions it needs, not the whole node's permissions |
| Multi-AZ RDS | Survives a full availability zone outage with automatic failover |
| Nodes across multiple AZs | EKS node group spans 4 subnets in 2 AZs — one AZ failure doesn't take down the cluster |

---

## Key Terms Glossary

| Term | Plain English |
|------|---------------|
| **VPC** | Your private isolated network inside AWS |
| **Subnet** | A segment of the VPC network for a specific purpose |
| **CIDR block** | Notation for a range of IP addresses (e.g. 170.20.0.0/16) |
| **Availability Zone (AZ)** | Physically separate data center within a region |
| **Internet Gateway** | Door between the internet and your public subnets |
| **NAT Gateway** | Lets private subnets reach the internet without being reachable from it |
| **Route Table** | Rules that direct network traffic within a VPC |
| **Security Group** | Virtual firewall rules attached to individual AWS resources |
| **Ingress** | Traffic coming INTO a resource |
| **Egress** | Traffic going OUT FROM a resource |
| **RDS** | AWS managed relational database service (MySQL, Postgres, etc.) |
| **Multi-AZ** | Primary + standby database across two AZs for automatic failover |
| **Point-in-Time Recovery** | Ability to restore database to any second within the backup window |
| **ECR** | AWS private Docker image registry |
| **Immutable tag** | Image tag that cannot be overwritten once pushed |
| **EKS** | AWS managed Kubernetes service |
| **Node Group** | A set of EC2 instances that run your Kubernetes workloads |
| **IAM Role** | AWS identity with specific permissions, assumed by services or users |
| **OIDC** | Authentication protocol — GitHub Actions uses it to get temporary AWS credentials |
| **IRSA** | IAM Roles for Service Accounts — per-pod AWS permissions in Kubernetes |
| **ACM** | AWS Certificate Manager — provisions and renews SSL/TLS certs |
| **Route53** | AWS DNS service — translates domain names to IP addresses |
| **Secrets Manager** | AWS encrypted vault for secrets like database passwords |
| **Terraform state** | Record of what infrastructure currently exists, used to compute diffs |
| **Remote state** | Storing the state file in S3 instead of locally, so teams share it |
| **State lock** | DynamoDB prevents two Terraform runs from conflicting |
| **Module** | Reusable chunk of Terraform code (like a function) |
| **Output** | Value exported from a module so other modules can use it |
