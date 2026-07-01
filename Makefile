.PHONY: init import plan apply destroy monitoring-status monitoring-logs

# ── Setup ─────────────────────────────────────────────────────────────────────

init:
	terraform init

# Import pre-existing secrets that Terraform can't create (state lost due to S3 backend).
# Run once per fresh state. || true prevents failure if already imported.
import:
	terraform import \
	  module.rds.aws_secretsmanager_secret.db_credentials \
	  /bookstore/db-credentials 2>/dev/null || echo "db-credentials already in state"
	terraform import \
	  module.eks_addons.aws_secretsmanager_secret.grafana_admin \
	  /bookstore/grafana-admin 2>/dev/null || echo "grafana-admin already in state"

plan: init
	terraform plan

# Full automated deploy: init → import known conflicts → apply
apply: init import
	terraform apply -auto-approve

destroy:
	terraform destroy -auto-approve

# ── Monitoring helpers ────────────────────────────────────────────────────────

MONITORING_IP = $(shell terraform output -raw grafana_url 2>/dev/null | sed 's|http://||' | cut -d: -f1)

# Tail the cloud-init log on the monitoring EC2 (requires SSH key in agent)
monitoring-logs:
	@echo "Tailing /var/log/monitoring-init.log on $(MONITORING_IP)"
	ssh -o StrictHostKeyChecking=no ubuntu@$(MONITORING_IP) \
	  "tail -f /var/log/monitoring-init.log /var/log/grafana-dashboard-import.log 2>/dev/null"

# Show Docker Compose status on the monitoring EC2
monitoring-status:
	@echo "Docker Compose status on $(MONITORING_IP)"
	ssh -o StrictHostKeyChecking=no ubuntu@$(MONITORING_IP) \
	  "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
