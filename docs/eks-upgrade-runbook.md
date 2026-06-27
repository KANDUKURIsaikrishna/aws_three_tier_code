# EKS Cluster Upgrade Runbook

## Overview

EKS minor version support window is ~14 months. After that, AWS forces an upgrade.
EKS blocks skipping versions — must upgrade one minor version at a time (1.31 → 1.32 → 1.33).

| Version | GA | End of Support (approx) |
|---------|-----|--------------------------|
| 1.31 | 2024-09 | 2026-11 |
| 1.32 | 2025-01 | 2027-03 |
| 1.33 | 2025-04 | 2027-06 |

**Set a calendar reminder 3 months before EOL.**

---

## Pre-Upgrade Checklist

- [ ] Check add-on compatibility: [EKS add-on versions](https://docs.aws.amazon.com/eks/latest/userguide/add-ons-compatibility.html)
- [ ] Check Helm chart compatibility (cert-manager, nginx, ArgoCD, Prometheus)
- [ ] Verify `kubectl` client version ≤ 1 minor version away from server
- [ ] Confirm all pods healthy: `kubectl get pods -A | grep -v Running | grep -v Completed`
- [ ] Snapshot RDS before touching anything
- [ ] Run `terraform plan` to confirm no unrelated drift before starting

---

## Step 1 — Upgrade Control Plane

Update the version in Terraform:

```hcl
# modules/eks/main.tf  (or main.tf module block)
cluster_version = "1.32"   # was 1.31
```

Apply — EKS upgrades control plane only, nodes stay on old version temporarily:

```bash
terraform apply -target=module.eks
```

Wait for control plane to finish (10-20 min):

```bash
aws eks wait cluster-active --name bookstore-eks --region us-west-1

# Confirm version
aws eks describe-cluster --name bookstore-eks \
  --query 'cluster.version' --output text
```

---

## Step 2 — Upgrade Managed Node Group

EKS drains one node at a time, respecting PodDisruptionBudgets:

```bash
aws eks update-nodegroup-version \
  --cluster-name bookstore-eks \
  --nodegroup-name bookstore-nodes \
  --region us-west-1

# Watch progress (takes 5-15 min per node)
aws eks wait nodegroup-active \
  --cluster-name bookstore-eks \
  --nodegroup-name bookstore-nodes \
  --region us-west-1
```

Verify new node version:

```bash
kubectl get nodes -o wide
```

---

## Step 3 — Upgrade EKS Managed Add-ons

`aws-ebs-csi-driver` is managed by EKS (not Helm). Upgrade it:

```bash
aws eks update-addon \
  --cluster-name bookstore-eks \
  --addon-name aws-ebs-csi-driver \
  --resolve-conflicts OVERWRITE \
  --region us-west-1
```

---

## Step 4 — Upgrade Helm Add-ons

Update chart versions in `modules/eks-addons/main.tf` for:

| Add-on | Typical check |
|--------|--------------|
| cert-manager | [cert-manager releases](https://github.com/cert-manager/cert-manager/releases) |
| ingress-nginx | [ingress-nginx releases](https://github.com/kubernetes/ingress-nginx/releases) |
| kube-prometheus-stack | [kube-prometheus-stack releases](https://github.com/prometheus-community/helm-charts/releases) |
| argo-cd | [ArgoCD releases](https://github.com/argoproj/argo-cd/releases) |
| argo-rollouts | [Argo Rollouts releases](https://github.com/argoproj/argo-rollouts/releases) |
| external-secrets | [ESO releases](https://github.com/external-secrets/external-secrets/releases) |

After updating chart versions:

```bash
terraform apply -target=module.eks_addons
```

---

## Step 5 — Verify

```bash
# All pods running
kubectl get pods -A | grep -v Running | grep -v Completed

# ArgoCD in sync
kubectl get applications -n argocd

# Canary rollout healthy
kubectl argo rollouts get rollout backend -n bookstore

# Certs still valid
kubectl get certificate -n bookstore

# ESO secret syncing
kubectl describe externalsecret -n bookstore db-secret | grep "Sync Status"
```

---

## Rollback

EKS control plane upgrades are **not reversible**. Node group rollback is possible:

```bash
# Roll nodes back to previous AMI (rarely needed)
aws eks update-nodegroup-version \
  --cluster-name bookstore-eks \
  --nodegroup-name bookstore-nodes \
  --release-version <previous-ami-release-version> \
  --region us-west-1
```

Get previous AMI release version from:
```bash
aws eks describe-nodegroup \
  --cluster-name bookstore-eks \
  --nodegroup-name bookstore-nodes \
  --query 'nodegroup.releaseVersion' --output text
```

---

## Notes

- `t3.medium` (4GB RAM) is tight with all add-ons. If upgrade causes OOMKilled pods, scale node group to 2 nodes temporarily.
- PodDisruptionBudgets (`minAvailable: 1`) protect frontend and backend during node drain.
- ArgoCD will automatically re-sync any add-on that drifts during the upgrade.
