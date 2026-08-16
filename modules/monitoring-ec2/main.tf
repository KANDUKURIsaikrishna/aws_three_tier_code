locals {
  # Bare host:port for the app-metrics job's scrape target address --
  # api_server (used for pod discovery) wants the full URL, but the actual
  # per-target __address__ relabel needs just host:port.
  eks_api_host = replace(var.eks_api_server, "https://", "")
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── Security Group ─────────────────────────────────────────────────────────────

resource "aws_security_group" "monitoring" {
  name        = "bookstore-monitoring-sg"
  description = "Monitoring EC2: Grafana (3000), Prometheus (9090), Alertmanager (9093), Loki (3100)"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.admin_cidr_blocks
    # Genuinely missing until OBS-027 — this SG never had a port 22 rule at
    # all, so `make monitoring-status`/`monitoring-logs` (both plain `ssh
    # ubuntu@...`) have never been able to connect, full timeout not an auth
    # failure. Same admin_cidr_blocks scoping as the other UI ports below —
    # narrow this in production per that variable's own description.
    description = "SSH"
  }
  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = var.admin_cidr_blocks
    description = "Grafana UI"
  }
  ingress {
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = var.admin_cidr_blocks
    description = "Prometheus UI"
  }
  ingress {
    from_port   = 9093
    to_port     = 9093
    protocol    = "tcp"
    cidr_blocks = var.admin_cidr_blocks
    description = "Alertmanager UI"
  }
  ingress {
    from_port   = 3100
    to_port     = 3100
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Loki push from Fluent Bit on EKS nodes"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound"
  }

  tags = { Name = "bookstore-monitoring-sg" }
}

# Allow monitoring EC2 to scrape node-exporter (systemd, port 9100) on EKS nodes
resource "aws_security_group_rule" "eks_scrape_node_exporter" {
  type                     = "ingress"
  from_port                = 9100
  to_port                  = 9100
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.monitoring.id
  security_group_id        = var.eks_cluster_sg_id
  description              = "Prometheus on monitoring EC2 scrapes node-exporter systemd service"
}

# Allow the monitoring EC2's kube-state-metrics container to reach the EKS API
# server. `var.eks_cluster_sg_id` is actually the cluster security group (see the
# module.eks call site) -- without this, kube-state-metrics can resolve the
# API server's private-endpoint IPs but every connection attempt times out at
# the security-group layer, crash-looping forever. Confirmed missing on a
# cluster that's been through several destroy/recreate cycles -- this had
# apparently never worked. See TROUBLESHOOTING.md OBS-034.
resource "aws_security_group_rule" "monitoring_scrape_eks_api" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.monitoring.id
  security_group_id        = var.eks_cluster_sg_id
  description              = "kube-state-metrics on monitoring EC2 reaches the EKS API server"
}

# Allow the monitoring EC2's Prometheus to scrape each node's kubelet
# directly for cAdvisor container-level metrics (real per-pod CPU/memory
# usage -- kube-state-metrics only has requests/limits/status, never actual
# usage). Same shared cluster security group as the node-exporter and API
# server rules above (var.eks_cluster_sg_id is EKS's cluster security group,
# auto-attached to every managed-node-group instance too).
resource "aws_security_group_rule" "monitoring_scrape_kubelet" {
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.monitoring.id
  security_group_id        = var.eks_cluster_sg_id
  description              = "Prometheus on monitoring EC2 scrapes kubelet /metrics/cadvisor on each node"
}

# ── EKS Access Entry (monitoring EC2 IAM role → read-only K8s API) ─────────────
# Enables kube-state-metrics Docker container on EC2 to authenticate via kubeconfig

resource "aws_eks_access_entry" "monitoring" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.monitoring.arn
  type          = "STANDARD"

  # A stable RBAC group, not the raw principal ARN. Without this, EKS maps
  # the entry to a k8s username derived from the assumed-role SESSION (which
  # embeds the specific EC2 instance ID), so any RBAC binding made directly
  # to that username breaks the moment the instance is replaced. Binding to
  # a group name here instead keeps the RBAC grant in observability-rbac.tf
  # stable across instance replacement, since group membership is decided by
  # this access entry (tied to the IAM role, not the instance), not by the
  # binding.
  kubernetes_groups = ["monitoring-metrics-readers"]
}

resource "aws_eks_access_policy_association" "monitoring_view" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.monitoring.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.monitoring]
}

# ── IAM Role ───────────────────────────────────────────────────────────────────

resource "aws_iam_role" "monitoring" {
  name = "bookstore-monitoring-ec2"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "monitoring" {
  name = "bookstore-monitoring-policy"
  role = aws_iam_role.monitoring.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [var.grafana_admin_secret_arn, var.alertmanager_smtp_secret_arn, var.monitoring_basic_auth_secret_arn]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "bookstore-monitoring-ec2"
  role = aws_iam_role.monitoring.name
}

# ── SSH Key Pair ────────────────────────────────────────────────────────────────
# Genuinely missing until OBS-027 — the instance below never had a key_name
# at all, so even with the SG's new port 22 rule, SSH had no way to
# authenticate (Ubuntu's cloud-init only seeds authorized_keys from an EC2
# key pair supplied at launch, or explicit user-data — neither existed).
# Auto-generated rather than requiring the user to bring their own, matching
# this project's existing automate-everything posture (argocd.tf's ALB
# discovery, the schema-init hooks, etc.) — Makefile's `monitoring-key`
# target fetches the private key from state and saves it locally.

resource "tls_private_key" "monitoring_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "monitoring" {
  key_name   = "bookstore-monitoring-ssh"
  public_key = tls_private_key.monitoring_ssh.public_key_openssh
}

# ── EC2 Instance ───────────────────────────────────────────────────────────────

resource "aws_instance" "monitoring" { # nosemgrep: aws-ec2-has-public-ip
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = var.public_subnet_id
  vpc_security_group_ids      = [aws_security_group.monitoring.id]
  iam_instance_profile        = aws_iam_instance_profile.monitoring.name
  key_name                    = aws_key_pair.monitoring.key_name
  associate_public_ip_address = true # intentional — SG restricts to admin_cidr_blocks, EIP needed for monitoring UIs

  # Without this, changing user_data only updates the instance's stored
  # attribute at the AWS API level -- cloud-init only ever runs user-data
  # once per instance, on first boot, so an already-running box would never
  # actually pick up script changes. This box is fully stateless/rebuildable
  # (Docker Compose + auto-imported dashboards), so replacing it on every
  # script change is the correct behavior, not a risk to avoid.
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # gzip'd: EC2/cloud-init auto-detects and decompresses gzip user-data at
  # boot, and the 16KB limit applies to the compressed bytes -- this script
  # has been bumping against the plain-text limit as features get added, so
  # compressing buys real headroom instead of trimming comments every time.
  user_data_base64 = base64gzip(templatefile("${path.module}/user-data.sh.tftpl", {
    cluster_name                      = var.cluster_name
    region                            = var.region
    grafana_admin_secret_name         = var.grafana_admin_secret_name
    monitoring_basic_auth_secret_name = var.monitoring_basic_auth_secret_name
    alertmanager_smtp_secret_name     = var.alertmanager_smtp_secret_name
    ne_port                           = 9100
    kubelet_port                      = 10250
    eks_api_server                    = var.eks_api_server
    eks_api_host                      = local.eks_api_host
    custom_dashboard_json             = file("${path.module}/dashboards/pod-node-resources.json")
    cluster_dashboard_json            = file("${path.module}/dashboards/k8s-cluster-overview.json")
  }))

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  tags = { Name = "bookstore-monitoring" }

  # Access entry must exist before the instance starts user-data
  depends_on = [
    aws_eks_access_entry.monitoring,
    aws_eks_access_policy_association.monitoring_view,
  ]
}

resource "aws_eip_association" "monitoring" {
  instance_id   = aws_instance.monitoring.id
  allocation_id = var.eip_allocation_id
}
