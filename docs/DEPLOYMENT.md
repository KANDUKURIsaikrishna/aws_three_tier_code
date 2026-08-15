# Deployment

How to actually stand this project up, end to end, from a fresh AWS account. This is the "nothing exists yet" path — the one this project is actually in right now on `observability` (verified 2026-07-31: `aws eks describe-cluster --name bookstore-eks` returns `ResourceNotFoundException` — nothing is running, despite a stale local `kubectl` context suggesting otherwise. Always verify against AWS directly, never trust a cached kubeconfig).

## Before you start

- AWS credentials configured (`aws sts get-caller-identity` should work) with sufficient permissions to create VPCs, EKS clusters, RDS instances, IAM roles, etc.
- `terraform` >= 1.7.0, `kubectl`, `aws` CLI — all three need to be on `PATH` on whatever machine runs `terraform apply`, not just for your own convenience: `null_resource` provisioners in this Terraform config now shell out to `kubectl`/`aws` directly (ALB hostname discovery, the destroy-time Ingress/log-group cleanup). `helm` itself isn't needed on your machine — the `helm` Terraform provider talks to the Helm API directly, no CLI required.
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
# review it — expect ~140 resources on a genuinely fresh account:
#   VPC + subnets + NAT + IGW + S3 endpoint, security groups, 2 ACM certs
#   (CloudFront's, off by default, + the real one the ALB uses), RDS instance,
#   private + public Route53 zones, ECR repos, EKS cluster + node group + OIDC provider,
#   eks-addons (ESO, AWS Load Balancer Controller, ArgoCD, Argo Rollouts),
#   monitoring EC2 + EIP, CloudTrail, GuardDuty, GitHub OIDC role,
#   the ArgoCD Application + ApplicationSet (kubectl_manifest, see below)
terraform apply tfplan
```

This used to need a second apply — Terraform couldn't create the public Route53 record until it knew the ingress load balancer's hostname, and that didn't exist until after `eks-addons` finished, so you had to check it by hand, paste it into `terraform.tfvars`, and apply again. `argocd.tf`'s `data "kubernetes_ingress_v1" "bookstore"` now reads that hostname within the same apply, gated behind a `null_resource` that first polls for the `bookstore-ingress` Ingress object to exist at all (it's deployed by ArgoCD, asynchronously — not created directly by this apply the way ingress-nginx's Helm-installed Service used to be), then `kubectl wait --for=jsonpath=...` for the AWS Load Balancer Controller to finish provisioning the real ALB and populate its hostname. One apply, start to finish, just with a wider safety-margin timeout than the old single-stage wait needed.

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

## Step 6 — Watch all apps come up

Both `k8s/argocd/application.yaml` (the old monolith) and `k8s/argocd/applicationset-microservices.yaml` (all 5 microservices: catalog, user, order, notification, api-gateway) were already applied by Terraform in Step 3 — nothing to `kubectl apply` here. Just watch ArgoCD reconcile, within 3 minutes of the apply finishing:

```bash
kubectl get applications -n argocd
kubectl get applicationsets -n argocd
kubectl get pods -n bookstore
kubectl get pods -n catalog
kubectl get pods -n user
kubectl get pods -n order
kubectl get pods -n notification
kubectl get pods -n gateway
```

For catalog-service/user-service/order-service/notification-service, ArgoCD's sync also runs each service's own `<service>-schema-init` PreSync hook Job automatically (creates its schema, creates its own DB user) — no manual secret-copying, no manual Job apply. Each reads its own admin credentials from an `admin-db-secret` ExternalSecret, which pulls the same `/bookstore/db-credentials` entry the old monolith already uses, materialized into that service's namespace by ESO. `api-gateway` has no schema-init Job — it's stateless. Watch any service's hook if you want to confirm it ran cleanly:

```bash
kubectl get jobs -n catalog
kubectl logs job/catalog-schema-init -n catalog   # only exists briefly — hook-delete-policy removes it after success
```

`api-gateway` has a real public `Ingress` for `api.bookstore.<domain>` — the old monolith's ingress no longer declares that host (the collision described in earlier revisions of this doc is resolved), so `api.bookstore.<domain>` reaching `api-gateway` is the live, working path, not something to route around:

```bash
curl -s https://api.bookstore.<domain>/health
```

If you'd rather bypass DNS/ingress entirely (e.g. verifying straight after an apply, before DNS has propagated), `kubectl port-forward` still works the same as always:

```bash
kubectl port-forward -n gateway svc/gateway-service 8082:80
curl -s http://localhost:8082/health
```

If images haven't been built/pushed by CI yet (first-ever deploy, before any CI run has landed on `main`), pods will sit in `ImagePullBackOff` until real images exist in ECR — either wait for CI, or push once by hand:

```bash
docker build -t <backend_repo_url>:manual backend/
docker push <backend_repo_url>:manual
# then kustomize edit set image + commit + push, same pattern CI uses
```

Verify catalog-service directly (bypassing the gateway, useful for isolating whether a problem is in the service itself or in the gateway/ingress path):

```bash
kubectl port-forward -n catalog svc/catalog-service 8081:80
# in another terminal:
curl -s http://localhost:8081/health
curl -s http://localhost:8081/books
curl -s http://localhost:8081/metrics | grep 'service="catalog-service"'
```

### Verify the frontend end-to-end (real UI, not just curl)

The React app at `bookstore.<domain>` has a real login/cart/checkout/order-history flow wired to `api-gateway` — worth clicking through after any deploy that touches `client/` or the gateway:

1. Open `https://bookstore.<domain>` — should show the book catalog (public, no login needed).
2. Register a new account, then log in.
3. Click "Add to Cart" on a book, go to Cart, adjust quantity, proceed to Checkout, place the order.
4. Check Orders — the placed order should show with status `pending`.
5. Log out, confirm `/cart`, `/checkout`, `/orders` all redirect to `/login` when visited directly while logged out.

Equivalent via `curl` if you don't have browser access (e.g. testing from a box without a display):

```bash
curl -s https://api.bookstore.<domain>/auth/register -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"testpass123"}'
TOKEN=$(curl -s https://api.bookstore.<domain>/auth/login -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"testpass123"}' | jq -r .token)
curl -s https://api.bookstore.<domain>/cart -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{"book_id":1,"quantity":1}'
curl -s -X POST https://api.bookstore.<domain>/orders/checkout -H "Authorization: Bearer $TOKEN"
curl -s https://api.bookstore.<domain>/orders -H "Authorization: Bearer $TOKEN"
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

`Makefile` has `make monitoring-status` (Docker Compose status on the box) and `make monitoring-logs` (tails the init/dashboard-import logs) — both auto-fetch an auto-generated SSH key from Terraform state via a `monitoring-key` prerequisite target (saved locally as `.monitoring-ssh-key.pem`, gitignored), no manual key management needed.

## Tearing it down

```bash
terraform destroy
```

This will refuse to destroy `module.route53.aws_route53_zone.public` (`prevent_destroy` — see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) OBS-018) if the domain's NS records have already been manually delegated to it at your registrar. Everything else still tears down. If you genuinely want to destroy and re-delegate the zone too, remove that `lifecycle` block first — see OBS-018 for the exact steps.

This project's Terraform has real destroy-safety automation baked in (Ingress/ALB release before VPC teardown, force-delete on the flow-log CloudWatch group, `recovery_window_in_days = 0` on Secrets Manager entries, `force_destroy = true` on the CloudTrail S3 bucket) specifically because this stack gets destroyed and recreated often during development — see TROUBLESHOOTING TF-015/TF-017 for what used to go wrong here. `make destroy` runs it with `-auto-approve`; use the plain command if you want the interactive confirmation.

Since `argocd.tf`'s `kubectl_manifest` resources are now what created the ArgoCD `Application`/`ApplicationSet` objects, `terraform destroy` also deletes them — and both carry `resources-finalizer.argocd.argoproj.io`, so ArgoCD deletes everything it manages (all of `k8s/overlays/prod` and every `k8s/services/*/overlays/prod`) before the `Application` object itself actually goes away. This happens automatically, in the right order, before `eks-addons`/`eks` get torn down (Terraform destroys in reverse-dependency order).

## Related

- [`TERRAFORM.md`](TERRAFORM.md) — what every module actually creates
- [`KUBERNETES.md`](KUBERNETES.md) — manifest layout and ArgoCD wiring
- [`CICD.md`](CICD.md) — what happens after this initial stand-up
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — real errors from real applies, and their fixes
