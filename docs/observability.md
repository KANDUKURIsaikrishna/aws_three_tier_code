# Observability — How It Works

> **Architecture principle:** Zero monitoring pods inside EKS. All observability tooling runs on a dedicated `t3.small` EC2 instance (Docker Compose). EKS worker nodes run `node-exporter` and `Fluent Bit` as systemd services — not as Kubernetes pods.

### Why Docker Compose (not systemd binaries, not Kubernetes)?

Five services need to call each other internally:

```
Grafana     → http://prometheus:9090
Grafana     → http://loki:3100
Grafana     → http://alertmanager:9093
Prometheus  → http://kube-state-metrics:8080
Prometheus  → http://alertmanager:9093
```

Docker Compose gives a private Docker network with hostname-based DNS for free. Without it, you'd wire everything manually via `localhost` ports or hardcoded IPs and write 5 separate systemd units that reference each other by port number.

`restart: unless-stopped`, named volumes, `depends_on`, and a single `docker compose up -d` handle lifecycle — no custom init logic needed.

**Why not the alternatives?**

| Option | Verdict for this project |
|---|---|
| Systemd binaries directly | Works for single binaries (node-exporter is already done this way). Falls apart for 5 services that need inter-service DNS. |
| Prometheus in EKS (Helm) | Explicitly avoided — saturates the single `t3.medium` node (~950 MB RAM). See TF-006 in troubleshooting. |
| Amazon Managed Prometheus + Managed Grafana | Right call for production. Eliminates EC2 entirely, auto-scales, no ops burden. ~$10–30/month extra at this scale. |
| CloudWatch Metrics + Logs Insights | Viable if all-in on AWS native. No Grafana, no PromQL, less flexible dashboards. |

Docker Compose is the right fit here: multi-service stack, inter-service calls, demo/small scale, single EC2 node.

---

## Table of Contents

1. [Stack Overview](#1-stack-overview)
2. [How Each Component Works](#2-how-each-component-works)
3. [How It Is Deployed (Fully Automated)](#3-how-it-is-deployed-fully-automated)
4. [Accessing the Dashboards](#4-accessing-the-dashboards)
5. [Alertmanager — Routing Alerts](#5-alertmanager--routing-alerts)
6. [Alerting Rules Reference](#6-alerting-rules-reference)
7. [Logs — Loki + Grafana Explore](#7-logs--loki--grafana-explore)
8. [How to Add a Custom Alert](#8-how-to-add-a-custom-alert)
9. [How to Configure a Real Alert Destination](#9-how-to-configure-a-real-alert-destination)
10. [Health Checks & Diagnostics](#10-health-checks--diagnostics)

---

## 1. Stack Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│  Monitoring EC2 (t3.small, Ubuntu 22.04, Elastic IP)                 │
│                                                                      │
│  Docker Compose services:                                            │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────────────┐ │
│  │ Prometheus   │  │  Grafana     │  │  Alertmanager              │ │
│  │ :9090        │  │  :3000       │  │  :9093                     │ │
│  │              │  │              │  │                            │ │
│  │ scrapes:     │  │ reads:       │  │ receives fired alerts from │ │
│  │  node-exp.   │◄─┤  Prometheus  │  │ Prometheus, routes to:     │ │
│  │  KSM         │  │  Loki        │  │  webhook / Slack / email   │ │
│  │  Prometheus  │  │  Alertmanager│  │                            │ │
│  └──────────────┘  └──────────────┘  └────────────────────────────┘ │
│  ┌──────────────┐  ┌──────────────────────────────────────────────┐  │
│  │    Loki      │  │  kube-state-metrics                          │  │
│  │    :3100     │  │  (reads EKS API via kubeconfig + access entry│  │
│  │              │  │   exposes cluster metrics on :8080)          │  │
│  │  receives    │  └──────────────────────────────────────────────┘  │
│  │  logs from   │                                                    │
│  │  Fluent Bit  │  /opt/monitoring/                                  │
│  └──────────────┘    ├── prometheus/                                 │
│                      │     ├── prometheus.yml                        │
│                      │     ├── targets/ne.json  ← updated by cron   │
│                      │     └── rules/bookstore.yml                  │
│                      ├── alertmanager/alertmanager.yml               │
│                      ├── grafana/provisioning/                       │
│                      └── loki/config.yaml                            │
└──────────────────────────────────────────────────────────────────────┘
        │                                    │
        │ scrapes :9100 via VPC              │ receives logs :3100
        ▼                                    │
EKS node group (AL2 t3.medium)              │
  ├── node-exporter  (systemd, :9100)       │
  └── Fluent Bit     (systemd, push ───────►┘
        tails /var/log/containers/*.log
        sends to Loki on monitoring EC2)
```

**Data retention:**
- Prometheus: 15 days (TSDB on EBS gp3)
- Loki: no expiry configured (filesystem, EBS gp3, 20 GB root volume)
- Alertmanager: 120 hours (silences + notification log)

---

## 2. How Each Component Works

### Prometheus
Pulls (scrapes) metrics on a 30-second interval from three targets:

| Job | Target | What it measures |
|---|---|---|
| `prometheus` | `localhost:9090` | Self-monitoring |
| `kube-state-metrics` | `kube-state-metrics:8080` (Docker network) | K8s object state: pod restarts, deployment replicas, job completions |
| `node-exporter` | EKS node IPs `:9100` via `file_sd_configs` | Hardware metrics: CPU, memory, disk I/O, network per node |

Target discovery for `node-exporter` is dynamic. A cron job runs every 5 minutes:
```
update-prom-targets.sh
  └─ aws ec2 describe-instances
       --filters "Name=tag:eks:cluster-name,Values=bookstore-eks"
                 "Name=instance-state-name,Values=running"
  └─ writes /opt/monitoring/prometheus/targets/ne.json
Prometheus hot-reloads the file automatically (no restart needed)
```

This means new EKS nodes are discovered within 5 minutes of joining the cluster. Terminated nodes are removed on the next refresh.

### kube-state-metrics
Runs as a Docker Compose service on the monitoring EC2. It connects to the EKS API using `/root/.kube/config` (generated at boot via `aws eks update-kubeconfig`). An **EKS access entry** grants the monitoring EC2 IAM role `AmazonEKSViewPolicy` (read-only). kube-state-metrics exposes cluster-level metrics on port 8080, which Prometheus scrapes over the Docker Compose internal network.

### Grafana
Reads from Prometheus (metrics), Loki (logs), and Alertmanager (alert state). Two dashboards are auto-imported at first boot:

| Dashboard | ID | What it shows |
|---|---|---|
| Node Exporter Full | 1860 | Per-node CPU, memory, disk, network, filesystem |
| Kubernetes cluster monitoring | 315 | Pod counts, deployment health, namespace resource usage |

Password is retrieved from AWS Secrets Manager at boot — no plaintext on disk or in git.

### Alertmanager
Receives fired alerts from Prometheus, groups them, applies inhibit rules, and routes them to configured receivers (Slack, email, webhook, PagerDuty, etc.). Ships pre-configured with:
- Route for `critical` alerts: 1-hour repeat interval
- Route for `warning` alerts: 6-hour repeat interval
- Inhibit rule: critical alert for an instance suppresses warning alerts for the same instance

The default receiver sends to `http://localhost:5001/` (a no-op placeholder). Replace with your real destination — see [Section 9](#9-how-to-configure-a-real-alert-destination).

### Loki
Receives log streams pushed by Fluent Bit running as a systemd service on each EKS worker node. Fluent Bit tails `/var/log/containers/*.log` (all container stdout/stderr) and streams them to `http://<monitoring-eip>:3100` (Loki port). Logs are queryable in Grafana → Explore with LogQL.

### node-exporter (on EKS nodes)
Installed as a systemd service via the EKS managed node group launch template (`modules/eks/node-user-data.sh.tftpl`). Runs as user `node_exporter` with no Kubernetes involvement. Port 9100 is exposed to the monitoring EC2 security group only (SG rule in `modules/monitoring-ec2/main.tf`).

### Fluent Bit (on EKS nodes)
Installed from the official Amazon Linux 2 yum repository as a systemd service. Reads Kubernetes container log files and forwards them to Loki. The Loki endpoint URL (`http://<EIP>:3100`) is baked in at node boot time via the Terraform `loki_url` variable.

---

## 3. How It Is Deployed (Fully Automated)

Everything is automated by `terraform apply` — no manual steps for observability.

### What Terraform does

| Step | Resource | What happens |
|---|---|---|
| 1 | `aws_eip.monitoring` (root) | Allocates Elastic IP before any module runs → IP is known at plan time |
| 2 | `module.eks_addons.aws_secretsmanager_secret.grafana_admin` | Generates 24-char random password, stores at `/bookstore/grafana-admin` |
| 3 | `module.eks.aws_launch_template.nodes` | Bakes EIP into Fluent Bit config in node user-data; installs node-exporter + Fluent Bit via MIME multipart |
| 4 | `module.monitoring_ec2.aws_eks_access_entry.monitoring` | Grants monitoring EC2 IAM role read-only EKS API access |
| 5 | `module.monitoring_ec2.aws_instance.monitoring` | EC2 boots, runs user-data.sh.tftpl |
| 6 | user-data (runtime, ~2-3 min) | Installs Docker, creates all config files, runs `docker compose up -d` |
| 7 | user-data (background, ~3-5 min) | `import-grafana-dashboards.sh` polls Grafana health, then imports dashboards 1860 + 315 |

### Timeline after `terraform apply` completes

```
t=0    terraform outputs printed (grafana_url, prometheus_url, alertmanager_url)
t=2m   EC2 up, Docker Compose started, Prometheus + Alertmanager + Loki healthy
t=3m   kubeconfig generated, kube-state-metrics connected to EKS API
t=5m   first cron run: node targets written, Prometheus scraping EKS nodes
t=8m   Grafana healthy, dashboards auto-imported
t=10m  all alerting rules loaded, Alertmanager firing/resolving
```

### How to verify the automation ran

```bash
# 1. SSH to monitoring EC2 (get IP from terraform output)
MONITORING_IP=$(terraform output -raw alertmanager_url | sed 's|http://||;s|:9093||')

# 2. Check init log
ssh ubuntu@$MONITORING_IP "sudo tail -50 /var/log/monitoring-init.log"

# 3. Check Docker Compose services
ssh ubuntu@$MONITORING_IP "cd /opt/monitoring && sudo docker compose ps"
# Expected: prometheus, kube-state-metrics, loki, alertmanager, grafana — all Up

# 4. Check dashboard import log
ssh ubuntu@$MONITORING_IP "sudo cat /var/log/grafana-dashboard-import.log"

# 5. Check cron target discovery
ssh ubuntu@$MONITORING_IP "cat /opt/monitoring/prometheus/targets/ne.json"
# Expected: JSON array of EKS node IPs at port 9100
```

Or use the Makefile shortcuts:
```bash
make monitoring-status   # docker compose ps
make monitoring-logs     # tail /var/log/monitoring-init.log
```

---

## 4. Accessing the Dashboards

### Get URLs from Terraform

```bash
terraform output grafana_url        # http://<EIP>:3000
terraform output prometheus_url     # http://<EIP>:9090
terraform output alertmanager_url   # http://<EIP>:9093
```

### Get Grafana password

```bash
aws secretsmanager get-secret-value \
  --secret-id /bookstore/grafana-admin \
  --region us-west-1 \
  --query SecretString \
  --output text
```

### Grafana login

1. Open `http://<EIP>:3000` in a browser
2. Username: `admin`
3. Password: from command above
4. Go to **Dashboards** → **Bookstore** folder → select a dashboard

### What you'll see

**Node Exporter Full (dashboard 1860)**
- CPU usage per core and total
- Memory available / used / cached
- Disk I/O and filesystem usage
- Network traffic per interface

**Kubernetes cluster monitoring (dashboard 315)**
- Total pods running vs desired
- Pod restart counts (identifies crash-looping pods)
- Namespace resource usage
- Deployment health

### Prometheus targets

Open `http://<EIP>:9090/targets` to see all scrape targets and their state:
- `node-exporter` — should show one entry per EKS node, state `UP`
- `kube-state-metrics` — should show `UP`
- `prometheus` — self-monitoring, always `UP`

### Alertmanager status

Open `http://<EIP>:9093` to see:
- Currently firing alerts
- Silences
- Alert routing configuration

---

## 5. Alertmanager — Routing Alerts

### How alerts flow

```
Prometheus evaluates rule every 30s
  │
  │ rule fires (condition true for `for:` duration)
  ▼
Alertmanager receives alert via HTTP (port 9093)
  │
  ├── group_wait: 30s   (collect other alerts before firing)
  ├── group_by: alertname, severity, cluster
  │
  ▼
Route matching:
  severity=critical → 'critical-webhook' receiver (repeat every 1h)
  severity=warning  → 'default-webhook' receiver  (repeat every 6h)
  │
  ▼
Inhibit rule: if critical fires for an instance → suppress warnings for same instance
  │
  ▼
Receiver sends notification (webhook / Slack / email / PagerDuty)
  │
  ▼ when alert resolves
Alertmanager sends resolution notification (send_resolved: true)
```

### Alertmanager config location

On the monitoring EC2: `/opt/monitoring/alertmanager/alertmanager.yml`

To update the config without re-running Terraform:
```bash
ssh ubuntu@$MONITORING_IP "sudo nano /opt/monitoring/alertmanager/alertmanager.yml"
# edit the file, then reload without restart:
ssh ubuntu@$MONITORING_IP "sudo docker exec alertmanager \
  kill -HUP 1"
# or use the API:
curl -X POST http://<EIP>:9093/-/reload
```

---

## 6. Alerting Rules Reference

Rules file on EC2: `/opt/monitoring/prometheus/rules/bookstore.yml`

| Alert | Condition | Severity | For | Fires when |
|---|---|---|---|---|
| `NodeDown` | `up{job="node-exporter"} == 0` | critical | 5m | EKS node stopped sending metrics for 5+ minutes |
| `HighCPUUsage` | avg CPU idle < 20% (CPU > 80%) | warning | 10m | Node sustained >80% CPU for 10 minutes |
| `HighMemoryUsage` | available memory < 15% | warning | 10m | Node sustained >85% memory use for 10 minutes |
| `PodCrashLooping` | pod restart rate > 3 in 15m | warning | 5m | Any pod restarts 3+ times in a 15-minute window |
| `KubeStateMetricsDown` | `up{job="kube-state-metrics"} == 0` | critical | 5m | kube-state-metrics unreachable (no cluster metrics) |

To see currently pending or firing rules:
```
http://<EIP>:9090/alerts
```

---

## 7. Logs — Loki + Grafana Explore

### How to query logs in Grafana

1. Open Grafana → **Explore** (compass icon in left sidebar)
2. Select datasource: **Loki**
3. Use LogQL queries:

```logql
# All logs from the bookstore namespace
{namespace="bookstore"}

# Backend container logs only
{namespace="bookstore", container="backend"}

# Logs containing "error" (case-insensitive)
{namespace="bookstore"} |= "error" | lower |= "error"

# Backend request logs, last 1 hour
{namespace="bookstore", container="backend"} | json

# All logs from a specific pod
{pod="backend-xxxx-yyyy"}
```

### How Fluent Bit labels logs

Fluent Bit tails `/var/log/containers/*.log` on each EKS node and extracts Kubernetes metadata from the filename pattern:
```
/var/log/containers/<pod-name>_<namespace>_<container-name>-<id>.log
```

Labels attached to each log stream:
- `job` = `fluent-bit`
- `cluster` = cluster name
- `pod` = pod name
- `namespace` = Kubernetes namespace
- `container` = container name

---

## 8. How to Add a Custom Alert

Edit the rules file on the monitoring EC2 and reload Prometheus. No Terraform re-apply needed.

```bash
ssh ubuntu@$MONITORING_IP

# Edit the rules file
sudo nano /opt/monitoring/prometheus/rules/bookstore.yml

# Validate syntax before reloading
docker exec prometheus promtool check rules /etc/prometheus/rules/bookstore.yml

# Hot-reload Prometheus config (no restart, no data loss)
curl -X POST http://localhost:9090/-/reload

# Verify the new alert appears
curl http://localhost:9090/api/v1/rules | jq '.data.groups[].rules[].name'
```

### Example: add alert for backend HTTP 5xx rate

```yaml
- alert: BackendHighErrorRate
  expr: |
    rate(http_requests_total{job="backend",status=~"5.."}[5m])
    /
    rate(http_requests_total{job="backend"}[5m]) > 0.01
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "Backend error rate > 1%: {{ $value | printf \"%.2f\" }}%"
    description: "Backend is returning HTTP 5xx errors above 1% over the last 5 minutes."
```

> The backend exposes `http_requests_total` labelled by `method`, `route`, and `status` via `prom-client`. Query it at `http://<api.domain>/metrics`.

### To make rule changes permanent (survive EC2 replacement)

Add your rule to `modules/monitoring-ec2/user-data.sh.tftpl` inside the `bookstore.yml` heredoc. On next `terraform apply` that replaces the instance, the rule will be baked in.

---

## 9. How to Configure a Real Alert Destination

Edit `/opt/monitoring/alertmanager/alertmanager.yml` on the monitoring EC2 and reload.

### Slack

```yaml
global:
  slack_api_url: 'https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK'

receivers:
  - name: 'default-webhook'
    slack_configs:
      - channel: '#bookstore-alerts'
        title: '[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}*{{ .Annotations.summary }}*\n{{ end }}'
        send_resolved: true
        color: '{{ if eq .Status "firing" }}danger{{ else }}good{{ end }}'

  - name: 'critical-webhook'
    slack_configs:
      - channel: '#bookstore-oncall'
        title: ':fire: [CRITICAL] {{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.summary }}\n{{ end }}'
        send_resolved: true
```

### Email (Gmail)

```yaml
global:
  smtp_smarthost: 'smtp.gmail.com:587'
  smtp_from: 'alertmanager@yourdomain.com'
  smtp_auth_username: 'alertmanager@yourdomain.com'
  smtp_auth_password: 'YOUR_APP_PASSWORD'   # Gmail App Password, not account password
  smtp_require_tls: true

receivers:
  - name: 'default-webhook'
    email_configs:
      - to: 'team@yourdomain.com'
        subject: '[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}'
        body: |
          {{ range .Alerts }}
          Alert: {{ .Annotations.summary }}
          Severity: {{ .Labels.severity }}
          {{ end }}
        send_resolved: true
```

### PagerDuty

```yaml
receivers:
  - name: 'critical-webhook'
    pagerduty_configs:
      - routing_key: 'YOUR_PAGERDUTY_INTEGRATION_KEY'
        description: '{{ .GroupLabels.alertname }}: {{ range .Alerts }}{{ .Annotations.summary }}{{ end }}'
        severity: '{{ .CommonLabels.severity }}'
```

### After editing

```bash
# Reload Alertmanager (no restart needed)
curl -X POST http://<EIP>:9093/-/reload

# Verify the new config was loaded
curl http://<EIP>:9093/api/v2/status | jq '.config.original'

# Test a receiver (replace receiver-name)
curl -X POST http://<EIP>:9093/api/v2/alerts -H "Content-Type: application/json" -d '[
  {
    "labels": {"alertname":"TestAlert","severity":"warning"},
    "annotations": {"summary":"This is a test alert"}
  }
]'
```

To make the config permanent, update `user-data.sh.tftpl` in the Terraform module.

---

## 10. Health Checks & Diagnostics

### Quick status check

```bash
# All monitoring services running?
make monitoring-status
# Expected: prometheus, kube-state-metrics, loki, alertmanager, grafana — all Up

# Init log (runs once at first boot)
make monitoring-logs

# Node targets discovered?
MONITORING_IP=$(terraform output -raw prometheus_url | sed 's|http://||;s|:9090||')
ssh ubuntu@$MONITORING_IP "cat /opt/monitoring/prometheus/targets/ne.json | jq '.[].targets'"

# Prometheus API — all targets UP?
curl -s http://<EIP>:9090/api/v1/targets | jq '.data.activeTargets[] | {job:.labels.job, health:.health}'

# Alertmanager healthy?
curl -s http://<EIP>:9093/-/healthy

# Currently firing alerts
curl -s http://<EIP>:9093/api/v2/alerts | jq '.[].labels'
```

### Restart a service

```bash
ssh ubuntu@$MONITORING_IP

# Restart single service
sudo docker restart prometheus
sudo docker restart alertmanager
sudo docker restart grafana

# Restart all
cd /opt/monitoring && sudo docker compose restart

# View logs for a service
sudo docker logs prometheus --tail 50
sudo docker logs alertmanager --tail 50
```

### Force update Prometheus targets immediately

```bash
ssh ubuntu@$MONITORING_IP "sudo /usr/local/bin/update-prom-targets.sh"
# Then hot-reload Prometheus
curl -X POST http://<EIP>:9090/-/reload
```

### Common problems

| Symptom | Check |
|---|---|
| Grafana shows "No data" | `http://<EIP>:9090/targets` — are node-exporter targets UP? |
| No logs in Loki Explore | `sudo journalctl -u fluent-bit` on EKS node — check Fluent Bit is running |
| Alert firing but no notification | `http://<EIP>:9093/api/v2/alerts` — check receiver config and reload |
| kube-state-metrics stuck | `sudo docker logs kube-state-metrics` — check kubeconfig / EKS access entry |
| Dashboard not imported | `sudo cat /var/log/grafana-dashboard-import.log` — network or Grafana health issue |
| Prometheus targets file empty | Cron not run yet — run `update-prom-targets.sh` manually |
