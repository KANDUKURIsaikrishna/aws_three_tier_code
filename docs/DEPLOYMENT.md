# Deployment

How to actually stand this project up, end to end, from a fresh AWS account. This is the "nothing exists yet" path — the one this project is actually in right now on `observability` (verified 2026-07-31: `aws eks describe-cluster --name bookstore-eks` returns `ResourceNotFoundException` — nothing is running, despite a stale local `kubectl` context suggesting otherwise. Always verify against AWS directly, never trust a cached kubeconfig).

## Before you start

- AWS credentials configured (`aws sts get-caller-identity` should work) with sufficient permissions to create VPCs, EKS clusters, RDS instances, IAM roles, etc.
- `terraform` >= 1.7.0, `kubectl`, `aws` CLI — all three need to be on `PATH` on whatever machine runs `terraform apply`, not just for your own convenience: `null_resource` provisioners in this Terraform config now shell out to `kubectl`/`aws` directly (NLB hostname discovery, the pre-existing destroy-time NLB/log-group cleanup). `helm` itself isn't needed on your machine — the `helm` Terraform provider talks to the Helm API directly, no CLI required.
- A domain you control (for `terraform.tfvars`' `domain` value — ACM DNS validation needs it)
- **Expect this to take roughly 20-30 minutes** and to cost real money the moment RDS/EKS/the monitoring EC2 exist. Don't run `terraform apply` on the full stack "just to see what happens." (This branch removed some unnecessary serialization in the Terraform graph — RDS/EKS already ran concurrently, but `eks-addons`'s 5 Helm charts now all install concurrently instead of partly one-after-another, and `monitoring-ec2` no longer waits on all of `eks-addons` to finish. See [`ARCHITECTURE.md`](ARCHITECTURE.md#terraform-module-graph). This hasn't been verified against a real apply yet — if Helm installs start timing out (TF-001-shaped failures), see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) for the rollback.)

## Step 1 — Bootstrap Terraform state (once per AWS account)

```bash
./scripts/init-backend.sh us-west-1
```

Creates the S3 bucket + DynamoDB lock table, patches `versions.tf` in place with the real bucket/table names, runs `terraform init`. Skipping this step means Terraform silently uses local state — `terraform plan` will look like it wants to create everything from scratch even if a cluster is already running elsewhere, because local state has no idea what exists. **If a `terraform plan` ever shows a suspiciously large "to add" count, check `terraform state list` and confirm the backend is actually configured before doing anything else.**

## Step 2 — Fill in `terraform.tfvars`

```hcl
aws_region  = "us-west-1"
domain      = "your-domain.example"
github_repo = "your-org/your-repo"
```

Leave `primary_alb_dns` and `secondary_alb_dns` empty. `primary_alb_dns` is auto-discovered within the same apply now (see Step 3) — only set it by hand if you want to override discovery and point DNS at a different/manually-managed load balancer. `secondary_alb_dns` stays empty until a secondary-region EKS cluster actually exists (it doesn't yet — see [`ARCHITECTURE.md`](ARCHITECTURE.md#region-layout)).

## Step 3 — One apply, everything

```bash
terraform plan -out=tfplan
# review it — expect ~100 resources on a genuinely fresh account:
#   VPC + subnets + NAT + IGW, security groups, ACM cert, RDS instance,
#   private + public Route53 zones, ECR repos, EKS cluster + node group + OIDC provider,
#   eks-addons (cert-manager, ESO, ingress-nginx, ArgoCD, Argo Rollouts),
#   monitoring EC2 + EIP, CloudTrail, GuardDuty, GitHub OIDC role,
#   the ArgoCD Application + ApplicationSet (kubectl_manifest, see below)
terraform apply tfplan
```

This used to need a second apply — Terraform couldn't create the public Route53 record until it knew the ingress NLB's hostname, and that didn't exist until after `eks-addons` finished, so you had to `kubectl get svc`, paste the hostname into `terraform.tfvars`, and apply again. `argocd.tf`'s `data "kubernetes_service" "ingress_nginx"` now reads that hostname within the same apply (gated behind a `null_resource` that runs `kubectl wait --for=jsonpath=...` first, since `helm_release`'s own `wait` only waits for pods, not for AWS to finish provisioning the NLB — that can lag another 1-3 minutes behind). One apply, start to finish.

`argocd.tf` also applies `k8s/argocd/application.yaml` and `k8s/argocd/applicationset-microservices.yaml` directly (via the `kubectl_manifest` resource, `gavinbunney/kubectl` provider) — no more manual `kubectl apply -f k8s/argocd/...` after the fact. Both wait on `module.eks_addons` (they need ArgoCD's CRDs to exist).

RDS (~10-15 min) and EKS (~15-20 min) are the slow parts and provision concurrently since neither depends on the other directly (both depend on `network`/`security`, not on each other). The `eks-addons` Helm releases run after the cluster is up, now fully concurrently with each other too (see [`ARCHITECTURE.md`](ARCHITECTURE.md#terraform-module-graph)) — if any single Helm release times out, see TROUBLESHOOTING TF-001/TF-006/OBS-006 before assuming something is broken. Point your domain registrar's nameservers at the values in `terraform output route53_public_name_servers` once, ever, after this apply.

## Step 4 — Import known-conflicting Secrets Manager entries (if re-deploying)

Only needed if this isn't a truly fresh account — repeated destroy/apply cycles can leave Secrets Manager entries Terraform's state doesn't know about:

```bash
make import
```

Safe no-op on a genuinely fresh account (`|| echo already imported` on both).

## Step 5 — Confirm the ExternalSecrets IRSA fix actually took

This bit silently broke every secret sync in the cluster until fixed on this branch (see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)) — don't skip verifying it:

```bash
kubectl get serviceaccount external-secrets-sa -n external-secrets -o jsonpath='{.metadata.annotations}'
# should contain: "eks.amazonaws.com/role-arn":"arn:aws:iam::<account>:role/bookstore-external-secrets"

kubectl get externalsecret db-secret -n bookstore
# STATUS column should show SecretSynced, not an error
```

## Step 6 — Watch both apps come up

Both `k8s/argocd/application.yaml` (the old monolith) and `k8s/argocd/applicationset-microservices.yaml` (catalog-service) were already applied by Terraform in Step 3 — nothing to `kubectl apply` here. Just watch ArgoCD reconcile, within 3 minutes of the apply finishing:

```bash
kubectl get applications -n argocd
kubectl get pods -n bookstore
kubectl get pods -n catalog
```

For catalog-service, ArgoCD's sync also runs the `catalog-schema-init` PreSync hook Job automatically (creates the `catalog_db` schema, migrates `books` rows, creates `catalog_user`) — no manual secret-copying, no manual Job apply. It reads its own admin credentials from the `admin-db-secret` ExternalSecret, which pulls the same `/bookstore/db-credentials` entry the old monolith already uses, materialized into the `catalog` namespace by ESO. Watch it if you want to confirm it ran cleanly:

```bash
kubectl get jobs -n catalog
kubectl logs job/catalog-schema-init -n catalog   # only exists briefly — hook-delete-policy removes it after success
```

If images haven't been built/pushed by CI yet (first-ever deploy, before any CI run has landed on `main`), pods will sit in `ImagePullBackOff` until real images exist in ECR — either wait for CI, or push once by hand:

```bash
docker build -t <backend_repo_url>:manual backend/
docker push <backend_repo_url>:manual
# then kustomize edit set image + commit + push, same pattern CI uses
```

Verify catalog-service end-to-end (it has no public ingress yet — traffic hasn't cut over):

```bash
kubectl port-forward -n catalog svc/catalog-service 8081:80
# in another terminal:
curl -s http://localhost:8081/health
curl -s http://localhost:8081/books
curl -s http://localhost:8081/metrics | grep 'service="catalog-service"'
```

## Ongoing deploys (once the initial stand-up is done)

You almost never run `kubectl apply` for app changes after this point — push to `main`, let CI build/scan/push the image, approve the `deploy` job's manual gate, and ArgoCD picks it up within 3 minutes. See [`CICD.md`](CICD.md).

## Monitoring access

```bash
terraform output grafana_url        # Grafana, default user "admin"
terraform output prometheus_url
terraform output alertmanager_url
aws secretsmanager get-secret-value --secret-id /bookstore/grafana-admin --query SecretString --output text
```

`Makefile` has `make monitoring-status` (Docker Compose status on the box) and `make monitoring-logs` (tails the init/dashboard-import logs) — both need SSH access to the monitoring EC2.

## Tearing it down

```bash
terraform destroy
```

This project's Terraform has real destroy-safety automation baked in (NLB release before VPC teardown, force-delete on the flow-log CloudWatch group, `recovery_window_in_days = 0` on Secrets Manager entries, `force_destroy = true` on the CloudTrail S3 bucket) specifically because this stack gets destroyed and recreated often during development — see TROUBLESHOOTING TF-015/TF-017 for what used to go wrong here. `make destroy` runs it with `-auto-approve`; use the plain command if you want the interactive confirmation.

Since `argocd.tf`'s `kubectl_manifest` resources are now what created the ArgoCD `Application`/`ApplicationSet` objects, `terraform destroy` also deletes them — and both carry `resources-finalizer.argocd.argoproj.io`, so ArgoCD deletes everything it manages (all of `k8s/overlays/prod` and every `k8s/services/*/overlays/prod`) before the `Application` object itself actually goes away. This happens automatically, in the right order, before `eks-addons`/`eks` get torn down (Terraform destroys in reverse-dependency order).

## Related

- [`TERRAFORM.md`](TERRAFORM.md) — what every module actually creates
- [`KUBERNETES.md`](KUBERNETES.md) — manifest layout and ArgoCD wiring
- [`CICD.md`](CICD.md) — what happens after this initial stand-up
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — real errors from real applies, and their fixes
