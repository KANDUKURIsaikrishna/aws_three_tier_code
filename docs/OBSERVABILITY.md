# Observability

Every tool this project uses to see what's actually happening — metrics, logs, alerts, deploy health, canary safety, and AWS-account-level audit — how each is wired, and how to use it.

**Philosophy:** the monitoring stack (Prometheus/Grafana/Loki/Alertmanager/kube-state-metrics) does **not** run inside the EKS cluster. It runs as Docker Compose on a standalone EC2 instance (`modules/monitoring-ec2`). This was a deliberate move (see `TERRAFORM.md` TF-006) — it keeps monitoring alive and queryable even if the cluster itself is unhealthy or being torn down, and keeps EKS node capacity for application pods instead of a `kube-prometheus-stack` footprint. The tradeoff: nothing on the EC2 side auto-discovers Kubernetes the way an in-cluster Prometheus Operator would — node lists, scrape targets, and kubeconfigs are all refreshed on a timer instead of via the Kubernetes API watch.

## Tool inventory

| Tool | Where it runs | What it does | Wired via |
|---|---|---|---|
| Prometheus | Docker Compose, monitoring EC2 | Scrapes metrics, evaluates alert rules | `modules/monitoring-ec2/user-data.sh.tftpl` |
| Grafana | Docker Compose, monitoring EC2 | Dashboards over Prometheus + Loki + Alertmanager | same |
| Loki | Docker Compose, monitoring EC2 | Log storage | same |
| Alertmanager | Docker Compose, monitoring EC2 | Alert routing/grouping | same |
| kube-state-metrics | Docker container, monitoring EC2 | Kubernetes object-state metrics (pod status, restarts, etc.) | same, talks to EKS API over the network |
| node-exporter | systemd service, on every EKS node | Host-level metrics (CPU/mem/disk) | `modules/eks/node-user-data.sh.tftpl` |
| kubelet cAdvisor | built into kubelet, every EKS node | Real per-pod/per-container CPU + memory **usage** (not just requests/limits) | Prometheus scrapes `:10250/metrics/cadvisor` directly, `observability-rbac.tf` |
| Fluent Bit | systemd service, on every EKS node | Ships container logs to Loki | same |
| prom-client | In-process, every Node.js service | Exposes `/metrics` (HTTP counters/histograms) | `services/*/app.js`, `backend/app.js` — scraped via API server pod-proxy, `observability-rbac.tf` |
| Argo Rollouts AnalysisTemplate | In-cluster, `bookstore` namespace | Canary error-rate gate, queries EC2 Prometheus | `k8s/base/monitoring/analysis-template.yaml` |
| ArgoCD | In-cluster | GitOps sync/health status per service | `k8s/argocd/*.yaml` |
| AWS CloudTrail | AWS-native | Multi-region API audit trail → S3 | `cloudtrail.tf` |
| AWS GuardDuty | AWS-native | Threat detection (S3, EKS audit logs, EC2 malware scan) | `guardduty.tf` |
| VPC Flow Logs | AWS-native | Network traffic logs → CloudWatch Logs | `modules/network/main.tf` |

## How it's wired

```
EKS nodes (each one)                         Monitoring EC2 (Docker Compose)
┌─────────────────────────┐                  ┌──────────────────────────────────┐
│ node_exporter (systemd)  │◄── scrape :9100 ─┤ Prometheus                       │
│  :9100                   │    (file_sd,      │  scrapes: itself, node-exporter, │
│                           │     ips refreshed │  kube-state-metrics             │
│ fluent-bit (systemd)     │    every 5 min)   │  evaluates: rules/bookstore.yml  │
│  tails /var/log/containers│                  │  alerts →                       │
│  ──push logs (3100)──────┼─────────────────►│ Alertmanager :9093               │
└─────────────────────────┘                  │  (webhook route, unconfigured    │
                                               │   receiver by default)           │
EKS API server                                │                                  │
┌─────────────────────────┐                  │ kube-state-metrics container     │
│ AmazonEKSViewPolicy       │◄── kubeconfig ───┤  static bearer token, refreshed  │
│ access entry (monitoring  │    (cron every    │  every 10 min via cron          │
│ EC2's IAM role)            │    10 min)       │  :8080 ── scraped by Prometheus │
└─────────────────────────┘                  │                                  │
                                               │ Loki :3100 ◄── Grafana datasource│
                                               │ Grafana :3000                    │
                                               │  datasources: Prometheus, Loki,  │
                                               │  Alertmanager (all provisioned)  │
                                               └──────────────────────────────────┘

Argo Rollouts (in-cluster, canary steps for the old `backend` Rollout)
  → queries EC2 Prometheus directly over HTTP for nginx_ingress_controller_requests
  → gates promote/abort on the error-rate AnalysisTemplate

ArgoCD (in-cluster)
  → polls git every 3 min, reports Sync/Health per Application — this is your
    deployment observability, separate from the metrics/logs stack above
```

**Why systemd instead of DaemonSets:** node-exporter and Fluent Bit run as systemd services baked into the EKS node launch template (`modules/eks/node-user-data.sh.tftpl`), not as Kubernetes DaemonSets. Since there's no in-cluster Prometheus Operator to manage DaemonSets against, and the monitoring stack lives outside the cluster anyway, this avoids adding a Kubernetes-native monitoring layer for a monitoring stack that isn't Kubernetes-native itself.

**Why a Docker container reaching the EKS API instead of a ServiceAccount:** kube-state-metrics runs on the monitoring EC2, outside the cluster, so it can't use an in-cluster ServiceAccount token. Instead the EC2's IAM role has an EKS access entry (`AmazonEKSViewPolicy`, cluster-scoped, read-only) and a cron job (`refresh-kube-token.sh`) writes a fresh bearer-token kubeconfig every 10 minutes (EKS tokens are short-lived — this is the same "refresh on a timer" pattern used for the node IP list).

## How to use each tool

### Grafana — dashboards

```bash
terraform output grafana_url        # http://<monitoring-EIP>:3000
```
Login: `admin` / the password in Secrets Manager (`/bookstore/grafana-admin`), auto-provisioned as the `GF_SECURITY_ADMIN_PASSWORD` on first boot. Two dashboards auto-import in the background on first launch (Grafana community IDs `1860` "Node Exporter Full" and `315` "Kubernetes cluster monitoring") into a `Bookstore` folder — give it a couple minutes after `terraform apply` if they're not there yet (`monitoring-logs` tails the import log, see below).

### Prometheus — raw metrics + alert rule status

```bash
terraform output prometheus_url     # http://<monitoring-EIP>:9090
```
Useful pages: `/targets` (confirms all 3 scrape jobs are `up`), `/alerts` (current alert state), `/graph` for ad-hoc PromQL. Current alert rules (`modules/monitoring-ec2/user-data.sh.tftpl`'s `rules/bookstore.yml`): `NodeDown`, `HighCPUUsage` (>80% for 10m), `HighMemoryUsage` (>85% for 10m), `PodCrashLooping`, `KubeStateMetricsDown`.

### Alertmanager — alert routing

```bash
terraform output alertmanager_url   # http://<monitoring-EIP>:9093
```
Routes `severity=critical` and `severity=warning` to separate repeat intervals (1h / 6h). **The actual receivers are unconfigured webhooks pointing at `localhost:5001`** (`modules/monitoring-ec2/user-data.sh.tftpl`'s `alertmanager.yml`) — alerts fire and show up in the Alertmanager UI, but nothing external (Slack/PagerDuty/email) is notified yet. The config has commented-out Slack and email blocks ready to fill in.

### Loki — logs

No standalone Loki UI — query it through Grafana's **Explore** view (top-left compass icon), select the `Loki` datasource, and filter by label, e.g. `{job="eks-containers", cluster="bookstore-eks"}`. Fluent Bit tags every line with `job=eks-containers,cluster=<cluster_name>` and pulls the Kubernetes namespace/pod/container out of the CRI log format automatically.

### Real per-pod CPU/memory usage (kubelet cAdvisor)

Prometheus scrapes `https://<node-ip>:10250/metrics/cadvisor` directly on every node (job `kubelet-cadvisor`), giving real usage — `container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`, etc. — labeled by `namespace`/`pod`/`container`. This is distinct from kube-state-metrics, which only ever has *requests/limits* and *status*, never actual usage. Wired via:
- `modules/monitoring-ec2/main.tf`'s `aws_security_group_rule.monitoring_scrape_kubelet` (port 10250 on the shared cluster SG, same pattern as the node-exporter rule)
- `observability-rbac.tf` — a `ClusterRole`/`ClusterRoleBinding` granting `get` on `nodes/proxy`, `nodes/metrics`, `nodes/stats`, bound to the `monitoring-metrics-readers` group set on the monitoring EC2's EKS access entry (a stable group, not the raw IAM principal ARN, which would break on every instance replacement)
- The refresh cron also writes a plain bearer-token file (`/opt/monitoring/kube/token`) that Prometheus's `bearer_token_file` re-reads on every scrape — no restart needed here, unlike kube-state-metrics (see OBS-042)

### App-level metrics (`prom-client`)

Every Node.js service (`api-gateway`, `catalog-service`, `user-service`, `order-service`, `notification-service`, and the old `backend`) exposes `GET /metrics` via `prom-client` — default process metrics (`collectDefaultMetrics`) plus custom HTTP request counters/histograms keyed by the route prefixes in `KNOWN_PREFIXES` (`/books`, `/auth`, `/users`, `/orders`, `/cart`, `/health`, `/metrics`). You can curl it directly against any pod for a live sanity check:
```bash
kubectl exec -n gateway deploy/api-gateway -- curl -s localhost:PORT/metrics | head -30
```
Scraped by the EC2 Prometheus's `app-metrics` job via the API server's pod-proxy — pod IPs and ClusterIPs aren't reachable from outside the cluster network the way node-hosted processes are, so this reuses the existing 443 route to the API server instead of a new SG rule. Only pods with a `prometheus.io/scrape: "true"` annotation are scraped (set on all 6 service pod templates); any other pod in the cluster carrying that same annotation gets picked up too — e.g. cert-manager's own pod, which ships one by default in its upstream chart. Query in Prometheus with `job="app-metrics"`.

### Canary safety (Argo Rollouts)

The old `backend` deploys via an Argo Rollouts canary strategy. Check its live state:
```bash
kubectl get rollout backend -n bookstore
kubectl argo rollouts get rollout backend -n bookstore --watch   # needs the argo-rollouts kubectl plugin
```
Each canary step is gated by the `error-rate` `AnalysisTemplate` (`k8s/base/monitoring/analysis-template.yaml`), which queries the EC2 Prometheus for `nginx_ingress_controller_requests` 5xx rate and fails the rollout if it exceeds 1% over a 2-minute window. **This gate is currently a no-op that always passes** — see Gaps below.

### SSH / raw access to the monitoring EC2

```bash
make monitoring-key      # pulls the auto-generated SSH key from Terraform state
make monitoring-logs     # tails /var/log/monitoring-init.log + the Grafana dashboard-import log
make monitoring-status   # docker ps on the box — confirms all 5 containers are Up
```

### Deployment health (ArgoCD)

Not metrics/logs, but the fastest way to see "is the last deploy actually healthy":
```bash
kubectl get applications -n argocd
kubectl describe application <name> -n argocd   # sync phase, last operation result, resource-level errors
```

### AWS-native audit trail

```bash
# Search for a specific API event (e.g. who deleted something)
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=DeleteSecurityGroup

# Current GuardDuty findings
aws guardduty list-findings --detector-id $(aws guardduty list-detectors --query 'DetectorIds[0]' --output text)

# VPC flow logs (network-level: who talked to whom, accepted/rejected)
aws logs tail /aws/vpc/flowlogs/bookstore --follow
```

## Known gaps

- **The canary's error-rate gate always passes, regardless of real error rate.** `nginx_ingress_controller_requests` (the metric the `AnalysisTemplate` queries) is never scraped — ingress-nginx's pod doesn't carry the `prometheus.io/scrape` annotation the way the 6 app services now do, so it isn't picked up by the `app-metrics` job either. The query's `or vector(0)`/`or vector(1)` fallbacks mean it silently returns "0% errors" forever instead of erroring loudly, so this is easy to miss in practice. Fixable the same way app-metrics was: add the annotation to ingress-nginx's pod template (via `helm_release` values in `modules/eks-addons`). See `docs/FUTURE_IMPROVEMENTS.md` gap #11 and `docs/TROUBLESHOOTING.md` OBS-016.
- **The `AnalysisTemplate`'s Prometheus address is a hardcoded literal EIP**, not templated from `terraform output prometheus_url`. A full destroy/recreate allocates a new Elastic IP every time, silently staling this address until someone notices canary rollouts failing with connection timeouts and hand-edits the file. See `docs/TROUBLESHOOTING.md` OBS-032.
- **Alertmanager has no real receiver** — alerts route correctly (critical vs. warning, grouping, inhibition) but land on an unconfigured `localhost:5001` webhook. Nobody gets paged. Slack/email config is commented-out and ready to fill in in `modules/monitoring-ec2/user-data.sh.tftpl`.
- **`k8s/base/monitoring/prometheus-rules.yaml` exists but is dead code.** It's a `PrometheusRule` CRD (`monitoring.coreos.com/v1`) from the era before monitoring moved to EC2 — deliberately excluded from `k8s/base/kustomization.yaml` (see the comment there) since there's no Prometheus Operator in-cluster to consume it. Safe to delete, or keep as a reference for what rules *would* look like if the stack ever moves back in-cluster.

## Related

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — where the monitoring EC2 sits in the overall network/infra picture
- [`TERRAFORM.md`](TERRAFORM.md) — TF-006, the decision to move monitoring out of the cluster
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — OBS-016, OBS-027, OBS-032, OBS-033, OBS-034 (every real incident that's hit this stack)
- [`FUTURE_IMPROVEMENTS.md`](FUTURE_IMPROVEMENTS.md) — gap #11 (ingress metrics not scraped), gap #14 (hardcoded EIP)
