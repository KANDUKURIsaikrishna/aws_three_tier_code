.PHONY: init import plan apply destroy monitoring-status monitoring-logs monitoring-key

# ── Setup ─────────────────────────────────────────────────────────────────────

init:
	terraform init

# Import pre-existing secrets that Terraform can't create (state lost due to S3 backend).
# Run once per fresh state. || true prevents failure if already imported.
#
# aws_iam_role.cluster (the EKS cluster's own IAM role) deliberately isn't
# imported here, even though it can orphan the same way -- terraform import
# always resolves every configured provider up front, including the
# kubectl/helm/kubernetes ones, and those depend on module.eks.cluster_endpoint
# etc., which don't exist yet on exactly the kind of from-scratch apply where
# this role is most likely to be orphaned (a previous attempt died after
# creating the role but before the cluster itself came up). Importing it here
# would fail with "Invalid provider configuration" in that exact scenario.
# See TROUBLESHOOTING.md for the real recovery: delete the orphaned role via
# AWS CLI and let Terraform recreate an identical one -- nothing about an EKS
# cluster role's identity is worth preserving via import.
import:
	terraform import \
	  module.rds.aws_secretsmanager_secret.db_credentials \
	  /bookstore/db-credentials 2>/dev/null || echo "db-credentials already in state"
	terraform import \
	  module.eks_addons.aws_secretsmanager_secret.grafana_admin \
	  /bookstore/grafana-admin 2>/dev/null || echo "grafana-admin already in state"
	terraform import \
	  aws_secretsmanager_secret.jwt_secret \
	  /bookstore/jwt-secret 2>/dev/null || echo "jwt-secret already in state"

plan: init
	terraform plan

# Full automated deploy: init → import known conflicts → apply
apply: init import
	terraform apply -auto-approve

destroy:
	terraform destroy -auto-approve

# ── Monitoring helpers ────────────────────────────────────────────────────────

MONITORING_IP = $(shell terraform output -raw grafana_url 2>/dev/null | sed 's|http://||' | cut -d: -f1)
MONITORING_KEY = .monitoring-ssh-key.pem

# Fetch the auto-generated SSH private key from Terraform state and save it
# locally (mode 400, required by ssh/scp). Re-run any time it goes missing —
# idempotent, just re-reads the same state-stored key, doesn't regenerate it.
monitoring-key:
	@rm -f $(MONITORING_KEY)
	terraform output -raw monitoring_ssh_private_key > $(MONITORING_KEY)
	chmod 400 $(MONITORING_KEY)

# Tail the cloud-init log on the monitoring EC2
monitoring-logs: monitoring-key
	@echo "Tailing /var/log/monitoring-init.log on $(MONITORING_IP)"
	ssh -o StrictHostKeyChecking=no -i $(MONITORING_KEY) ubuntu@$(MONITORING_IP) \
	  "tail -f /var/log/monitoring-init.log /var/log/grafana-dashboard-import.log 2>/dev/null"

# Show Docker Compose status on the monitoring EC2
monitoring-status: monitoring-key
	@echo "Docker Compose status on $(MONITORING_IP)"
	ssh -o StrictHostKeyChecking=no -i $(MONITORING_KEY) ubuntu@$(MONITORING_IP) \
	  "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
