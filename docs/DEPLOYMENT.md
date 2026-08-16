# Deployment

How to actually stand this project up, end to end, from a fresh AWS account. This is the "nothing exists yet" path — the one this project is actually in right now on `observability` (verified 2026-07-31: `aws eks describe-cluster --name bookstore-eks` returns `ResourceNotFoundException` — nothing is running, despite a stale local `kubectl` context suggesting otherwise. Always verify against AWS directly, never trust a cached kubeconfig).

## Before you start

- AWS credentials configured (`aws sts get-caller-identity` should work) with sufficient permissions to create VPCs, EKS clusters, RDS instances, IAM roles, etc.
- `terraform` >= 1.10.0 (native S3 state locking needs it), `kubectl`, `aws` CLI — all three need to be on `PATH` on whatever machine runs `terraform apply`, not just for your own convenience: `null_resource` provisioners in this Terraform config now shell out to `kubectl`/`aws` directly (ALB hostname discovery, the destroy-time Ingress/log-group cleanup). `helm` itself isn't needed on your machine — the `helm` Terraform provider talks to the Helm API directly, no CLI required.
- A domain you control (for `terraform.tfvars`' `domain` value — ACM DNS validation needs it)
- **Expect this to take roughly 20-30 minutes** and to cost real money the moment RDS/EKS/the monitoring EC2 exist. Don't run `terraform apply` on the full stack "just to see what happens." (This branch removed some unnecessary serialization in the Terraform graph — RDS/EKS already ran concurrently, but `eks-addons`'s 5 Helm charts now all install concurrently instead of partly one-after-another, and `monitoring-ec2` no longer waits on all of `eks-addons` to finish. See [`ARCHITECTURE.md`](ARCHITECTURE.md#terraform-module-graph). This hasn't been verified against a real apply yet — if Helm installs start timing out (TF-001-shaped failures), see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) for the rollback.)

## Step 1 — Fill in your config, generate `terraform.tfvars`

```bash
cp config.env.example config.env
# edit config.env: AWS_ACCOUNT_ID, AWS_REGION, DOMAIN, GITHUB_REPO, ALERT_EMAIL
python3 scripts/configure.py
```

Do this **before** Step 2 — Step 2's backend bootstrap reads `AWS_REGION` from this same `config.env` file, so it needs to exist first (see Step 2's own notes on region resolution).

`terraform.tfvars` is **generated**, not hand-written — `scripts/configure.py` is the only supported way to produce it (this is also stated directly on `alert_email`'s own description in `variables.tf`: "don't hand-edit it here directly"). The script does two things:

1. Writes `terraform.tfvars` with the 4 variables that have no safe default (`aws_region`, `domain`, `github_repo`, `alert_email`) — everything else in `variables.tf` ships with a working default (see [`TERRAFORM.md`](TERRAFORM.md)); leave `primary_alb_dns` and `secondary_alb_dns` out of `config.env` entirely. `primary_alb_dns` is auto-discovered within the same apply now (see Step 4) — only set it in `terraform.tfvars` by hand afterward if you want to override discovery and point DNS at a different/manually-managed load balancer. `secondary_alb_dns` stays empty until a secondary-region EKS cluster actually exists (it doesn't yet — see [`ARCHITECTURE.md`](ARCHITECTURE.md#region-layout)).
2. Stamps your real domain/repo/account ID/region over placeholder values (`YOUR_DOMAIN_HERE.com`, `YOUR_GITHUB_USERNAME/aws_three_tier_code`, `ACCOUNT_ID`, `AWS_REGION_HERE`) in five files that are otherwise still git's checked-in template content: `k8s/base/ingress/ingress.yaml`, `k8s/services/api-gateway/base/configmap.yaml` (`FRONTEND_URL`, used for CORS), `k8s/argocd/application.yaml`, `k8s/overlays/prod/kustomization.yaml`, `k8s/base/secrets/external-secret.yaml` (the shared `ClusterSecretStore`'s `region` field — every service's `ExternalSecret` references this one by name, so a wrong region here breaks secret sync cluster-wide).

**Commit and push those 5 stamped files before your first ArgoCD sync matters** — ArgoCD deploys `k8s/base` and `k8s/services` content straight from git, not from whatever's sitting on your local disk. Skip this and the very first sync deploys the literal placeholder strings, not your real domain:

```bash
git add k8s/base/ingress/ingress.yaml k8s/services/api-gateway/base/configmap.yaml \
        k8s/argocd/application.yaml k8s/overlays/prod/kustomization.yaml \
        k8s/base/secrets/external-secret.yaml
git commit -m "chore: configure for <your-domain>"
git push
```

(`k8s/argocd/application.yaml` itself is read directly off local disk by `argocd.tf`'s `kubectl_manifest` resource at `terraform apply` time — pushing it isn't strictly required for that one apply to pick up the right value, but commit it anyway so the checked-in file matches what's actually running.)

`config.env` and `terraform.tfvars` are both gitignored — never commit either one.

## Step 2 — Bootstrap Terraform state (once per AWS account)

```bash
./scripts/init-backend.sh
```

Creates the S3 bucket, patches `versions.tf` in place with the real bucket name *and region*, runs `terraform init`. State locking is native S3 conditional-write locking (`use_lockfile = true`, no DynamoDB table). Skipping this step means Terraform silently uses local state — `terraform plan` will look like it wants to create everything from scratch even if a cluster is already running elsewhere, because local state has no idea what exists. **If a `terraform plan` ever shows a suspiciously large "to add" count, check `terraform state list` and confirm the backend is actually configured before doing anything else.**

Region resolution here is layered, in priority order: an explicit CLI arg (`./scripts/init-backend.sh us-west-2`, if you want to override), then `AWS_REGION` from `config.env` (the normal path, since Step 1 already created it), then `us-west-1` as a last-resort default if neither is set. The Terraform backend block in `versions.tf` genuinely cannot reference `var.aws_region` at all — Terraform resolves backend configuration before any variables are evaluated, a real HCL limitation, not an oversight — so this script patching the literal value in is the only way that field ever stays correct.

## Step 3 — Bootstrap the domain (once per domain, ever)

```bash
./scripts/init-domain.sh
```

Creates the public Route53 hosted zone for `DOMAIN` (from `config.env`) if it doesn't already exist, and prints the 4 NS values to set at your registrar (GoDaddy, Namecheap, etc.). **Do this now, before Step 4** — Terraform reads this zone via a `data` lookup, it never creates or destroys it (see [`TERRAFORM.md`](TERRAFORM.md#backend-state) and [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) OBS-058), so the registrar update only ever needs to happen once for this domain's whole lifetime — not once per apply/destroy cycle. Set the NS values now and give them a few minutes to propagate while Step 4 works through the rest of the stack; if `aws_acm_certificate_validation.ingress` still hangs in Step 4, the NS records haven't propagated yet.

## Step 4 — One apply, everything

```bash
terraform plan -out=tfplan
# review it — expect ~140 resources on a genuinely fresh account:
#   VPC + subnets + NAT + IGW + S3 endpoint, security groups, 2 ACM certs
#   (CloudFront's, off by default, + the real one the ALB uses), RDS instance,
#   private Route53 zone (the public zone is looked up, not created — see Step 3),
#   ECR repos, EKS cluster + node group + OIDC provider,
#   eks-addons (ESO, AWS Load Balancer Controller, ArgoCD, Argo Rollouts),
#   monitoring EC2 + EIP, CloudTrail, GuardDuty, GitHub OIDC role,
#   the ArgoCD AppProject + Application + ApplicationSet (kubectl_manifest, see below)
terraform apply tfplan
```

This used to need a second apply — Terraform couldn't create the public Route53 record until it knew the ingress load balancer's hostname, and that didn't exist until after `eks-addons` finished, so you had to check it by hand, paste it into `terraform.tfvars`, and apply again. `argocd.tf`'s `data "kubernetes_ingress_v1" "bookstore"` now reads that hostname within the same apply, gated behind a `null_resource` that first polls for the `bookstore-ingress` Ingress object to exist at all (it's deployed by ArgoCD, asynchronously — not created directly by this apply the way ingress-nginx's Helm-installed Service used to be), then `kubectl wait --for=jsonpath=...` for the AWS Load Balancer Controller to finish provisioning the real ALB and populate its hostname. One apply, start to finish, just with a wider safety-margin timeout than the old single-stage wait needed.

`argocd.tf` also applies `k8s/argocd/appproject.yaml`, `k8s/argocd/application.yaml`, and `k8s/argocd/applicationset-microservices.yaml` directly (via the `kubectl_manifest` resource, `gavinbunney/kubectl` provider) — no more manual `kubectl apply -f k8s/argocd/...` after the fact. All three wait on `module.eks_addons` (they need ArgoCD's CRDs to exist); the Application and ApplicationSet additionally wait on the AppProject, since ArgoCD rejects either one naming a project that doesn't exist. (`appproject.yaml` was missing from this list for a while — see OBS-058.)

RDS (~10-15 min) and EKS (~15-20 min) are the slow parts and provision concurrently since neither depends on the other directly (both depend on `network`/`security`, not on each other). The `eks-addons` Helm releases run after the cluster is up, now fully concurrently with each other too (see [`ARCHITECTURE.md`](ARCHITECTURE.md#terraform-module-graph)) — if any single Helm release times out, see TROUBLESHOOTING TF-001/TF-006/OBS-006 before assuming something is broken. As long as Step 3's NS records were set and have propagated, `aws_acm_certificate_validation.ingress` resolves on its own within a few minutes — no manual registrar step here anymore (that used to be required after *every* destroy+recreate cycle, since the public zone was Terraform-managed and got brand-new NS values each time it was recreated; it's now a `data` lookup instead, see Step 3 and OBS-058).

## Step 5 — Import known-conflicting Secrets Manager entries (if re-deploying)

Only needed if this isn't a truly fresh account — repeated destroy/apply cycles can leave Secrets Manager entries Terraform's state doesn't know about:

```bash
make import
```

Safe no-op on a genuinely fresh account (`|| echo already imported` on both).

## Step 6 — Confirm the ExternalSecrets IRSA fix actually took

This bit silently broke every secret sync in the cluster until fixed on this branch (see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)) — don't skip verifying it:

```bash
kubectl get serviceaccount external-secrets-sa -n external-secrets -o jsonpath='{.metadata.annotations}'
# should contain: "eks.amazonaws.com/role-arn":"arn:aws:iam::<account>:role/bookstore-external-secrets"

kubectl get clustersecretstore aws-secretsmanager -o jsonpath='{.status.conditions[0]}'
# should show "status":"True","type":"Ready" -- if this isn't Ready, every
# ExternalSecret below will fail regardless of anything else being correct,
# since they all reference this one ClusterSecretStore by name

kubectl get externalsecret admin-db-secret -n catalog
# STATUS column should show SecretSynced, not an error -- every microservice
# (catalog/user/order/notification/gateway) has its own admin-db-secret,
# this one's just picked as the first to check
```

## Step 7 — Watch all apps come up

Both `k8s/argocd/application.yaml` (the `bookstore` Application — the React frontend and its shared namespace resources: storage class, secrets bootstrap, network policy, PDB, quota) and `k8s/argocd/applicationset-microservices.yaml` (all 5 backend microservices: catalog, user, order, notification, api-gateway, one ArgoCD `Application` each) were already applied by Terraform in Step 4 — nothing to `kubectl apply` here. There is no backend monolith anymore; the original single frontend/backend pair was fully replaced by these 5 microservices, and `application.yaml` deploys frontend only. Just watch ArgoCD reconcile, within 3 minutes of the apply finishing:

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

If images haven't been built/pushed by CI yet (first-ever deploy, before any CI run has landed), all 6 pods (`frontend` + the 5 microservices) will sit in `ImagePullBackOff` until real images exist in their ECR repos — **this is expected on a genuinely fresh account**, not a sign anything is broken. Either wait for a CI run to land on `observability` (fastest — just push any commit), or push once by hand per service:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.us-west-1.amazonaws.com"
aws ecr get-login-password --region us-west-1 | docker login --username AWS --password-stdin "$REGISTRY"

# Frontend
docker build -t "$REGISTRY/bookstore-frontend:manual" client/
docker push "$REGISTRY/bookstore-frontend:manual"
(cd k8s/overlays/prod && kustomize edit set image bookstore-frontend="$REGISTRY/bookstore-frontend:manual")

# Each of the 5 microservices follows the identical pattern -- swap the name:
docker build -t "$REGISTRY/bookstore-catalog-service:manual" services/catalog-service/
docker push "$REGISTRY/bookstore-catalog-service:manual"
(cd k8s/services/catalog-service/overlays/prod && kustomize edit set image bookstore-catalog-service="$REGISTRY/bookstore-catalog-service:manual")
# ...repeat for user-service, order-service, notification-service, api-gateway

git add k8s/overlays/prod/kustomization.yaml k8s/services/*/overlays/prod/kustomization.yaml
git commit -m "chore: manual image push for first deploy" && git push
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
terraform output prometheus_url     # Prometheus, also user "admin" -- see OBS-063
terraform output alertmanager_url   # Alertmanager, also user "admin" -- see OBS-063
aws secretsmanager get-secret-value --secret-id /bookstore/grafana-admin --query SecretString --output text
aws secretsmanager get-secret-value --secret-id /bookstore/monitoring-basic-auth --query SecretString --output text
```

`Makefile` has `make monitoring-status` (Docker Compose status on the box) and `make monitoring-logs` (tails the init/dashboard-import logs) — both auto-fetch an auto-generated SSH key from Terraform state via a `monitoring-key` prerequisite target (saved locally as `.monitoring-ssh-key.pem`, gitignored), no manual key management needed.

## Tearing it down

```bash
terraform destroy
```

`module.route53.aws_route53_zone.public` no longer carries a `prevent_destroy` lifecycle block (removed deliberately — see OBS-018 for why it existed and OBS-058 for why it was removed) — `terraform destroy` tears down the public zone along with everything else, no refusal. The real consequence: the next `apply` creates a **brand-new zone with brand-new, randomly-assigned nameserver values**, and your domain registrar needs to be re-pointed at them again before ACM certificate validation (and anything depending on it, like the ALB's TLS listener) can complete — see OBS-058 for the exact symptom if this step gets missed or done too late. Grab `terraform output route53_public_name_servers` and update the registrar as early in the apply as possible, not after it finishes — DNS propagation can take anywhere from minutes to hours, and doing it early lets that time overlap with RDS/EKS provisioning (~20-30 min) instead of adding to the total.

This project's Terraform has real destroy-safety automation baked in (Ingress/ALB release before VPC teardown, force-delete on the flow-log CloudWatch group, `recovery_window_in_days = 0` on Secrets Manager entries, `force_destroy = true` on the CloudTrail S3 bucket) specifically because this stack gets destroyed and recreated often during development — see TROUBLESHOOTING TF-015/TF-017 for what used to go wrong here. `make destroy` runs it with `-auto-approve`; use the plain command if you want the interactive confirmation.

Since `argocd.tf`'s `kubectl_manifest` resources are now what created the ArgoCD `Application`/`ApplicationSet` objects, `terraform destroy` also deletes them — and both carry `resources-finalizer.argocd.argoproj.io`, so ArgoCD deletes everything it manages (all of `k8s/overlays/prod` and every `k8s/services/*/overlays/prod`) before the `Application` object itself actually goes away. This happens automatically, in the right order, before `eks-addons`/`eks` get torn down (Terraform destroys in reverse-dependency order).

## Related

- [`TERRAFORM.md`](TERRAFORM.md) — what every module actually creates
- [`KUBERNETES.md`](KUBERNETES.md) — manifest layout and ArgoCD wiring
- [`CICD.md`](CICD.md) — what happens after this initial stand-up
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — real errors from real applies, and their fixes
