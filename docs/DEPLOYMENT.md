# Deployment

How to actually stand this project up, end to end, from a fresh AWS account. This is the "nothing exists yet" path — the one this project is actually in right now on `observability` (verified 2026-07-31: `aws eks describe-cluster --name bookstore-eks` returns `ResourceNotFoundException` — nothing is running, despite a stale local `kubectl` context suggesting otherwise. Always verify against AWS directly, never trust a cached kubeconfig).

## Before you start

- AWS credentials configured (`aws sts get-caller-identity` should work) with sufficient permissions to create VPCs, EKS clusters, RDS instances, IAM roles, etc.
- `terraform` >= 1.7.0, `kubectl`, `helm`, `aws` CLI
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

`primary_alb_dns` and `secondary_alb_dns` stay empty on this first apply — the load balancer doesn't exist until EKS + ingress-nginx are up, and Terraform can't create a Route53 record pointing at a DNS name that doesn't exist yet. This is why the full stack needs **two applies**, not one (see Step 4).

## Step 3 — First apply: everything except app-level Route53 records

```bash
terraform plan -out=tfplan
# review it — expect ~100 resources on a genuinely fresh account:
#   VPC + subnets + NAT + IGW, security groups, ACM cert, RDS instance,
#   private Route53 zone, ECR repos, EKS cluster + node group + OIDC provider,
#   eks-addons (cert-manager, ESO, ingress-nginx, ArgoCD, Argo Rollouts),
#   monitoring EC2 + EIP, CloudTrail, GuardDuty, GitHub OIDC role
terraform apply tfplan
```

RDS (~10-15 min) and EKS (~15-20 min) are the slow parts and provision concurrently since neither depends on the other directly (both depend on `network`/`security`, not on each other). The `eks-addons` Helm releases run after the cluster is up — expect this stage to take a few more minutes; if any single Helm release times out, see TROUBLESHOOTING TF-001/TF-006 before assuming something is broken.

## Step 4 — Get the ingress NLB hostname, second apply

Once `eks-addons` has installed ingress-nginx, AWS provisions a real NLB as a side effect (invisible to Terraform — it's a Kubernetes-cloud-controller action, not an AWS API call Terraform made):

```bash
aws eks update-kubeconfig --name bookstore-eks --region us-west-1
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Put that value into `terraform.tfvars` as `primary_alb_dns`, then:

```bash
terraform apply
```

This second apply creates the public Route53 record pointing traffic at the real NLB. Point your domain registrar's nameservers at the values in `terraform output route53_public_name_servers` if you haven't already (only needs doing once, ever).

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

kubectl get externalsecret db-secret -n bookstore
# STATUS column should show SecretSynced, not an error
```

## Step 7 — Deploy the app (old monolith)

```bash
kubectl apply -f k8s/argocd/application.yaml
```

ArgoCD reconciles `k8s/overlays/prod` within 3 minutes. Watch it:

```bash
kubectl get applications -n argocd
kubectl get pods -n bookstore
```

If images haven't been built/pushed by CI yet (first-ever deploy, before any CI run has landed on `main`), pods will sit in `ImagePullBackOff` until real images exist in ECR — either wait for CI, or push once by hand:

```bash
docker build -t <backend_repo_url>:manual backend/
docker push <backend_repo_url>:manual
# then kustomize edit set image + commit + push, same pattern CI uses
```

## Step 8 — Deploy catalog-service (new microservice)

```bash
kubectl apply -f k8s/argocd/applicationset-microservices.yaml
kubectl get applications -n argocd   # catalog-service should appear
```

Then run the schema bootstrap — this is a **manual, one-time** step, not something ArgoCD or Terraform does for you:

```bash
# 1. Copy admin DB credentials into the catalog namespace (needed only for this bootstrap)
kubectl get secret db-secret -n bookstore -o json | \
  jq 'del(.metadata.namespace,.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.ownerReferences)' | \
  jq '.metadata.namespace="catalog"' | \
  kubectl apply -n catalog -f -

# 2. Run the bootstrap Job
kubectl apply -f k8s/services/catalog-service/bootstrap/schema-init-job.yaml
kubectl wait --for=condition=complete job/catalog-schema-init -n catalog --timeout=60s
kubectl logs job/catalog-schema-init -n catalog

# 3. Clean up — this secret copy and Job were only needed for the bootstrap
kubectl delete secret db-secret -n catalog
kubectl delete job catalog-schema-init -n catalog
```

Verify it end-to-end (catalog-service has no public ingress yet — traffic hasn't cut over):

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

## Related

- [`TERRAFORM.md`](TERRAFORM.md) — what every module actually creates
- [`KUBERNETES.md`](KUBERNETES.md) — manifest layout and ArgoCD wiring
- [`CICD.md`](CICD.md) — what happens after this initial stand-up
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — real errors from real applies, and their fixes
