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
  security_group_id        = var.eks_node_sg_id
  description              = "Prometheus on monitoring EC2 scrapes node-exporter systemd service"
}

# ── EKS Access Entry (monitoring EC2 IAM role → read-only K8s API) ─────────────
# Enables kube-state-metrics Docker container on EC2 to authenticate via kubeconfig

resource "aws_eks_access_entry" "monitoring" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.monitoring.arn
  type          = "STANDARD"
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
        Resource = var.grafana_admin_secret_arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "bookstore-monitoring-ec2"
  role = aws_iam_role.monitoring.name
}

# ── EC2 Instance ───────────────────────────────────────────────────────────────

resource "aws_instance" "monitoring" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = var.public_subnet_id
  vpc_security_group_ids      = [aws_security_group.monitoring.id]
  iam_instance_profile        = aws_iam_instance_profile.monitoring.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    cluster_name              = var.cluster_name
    region                    = var.region
    grafana_admin_secret_name = var.grafana_admin_secret_name
    ne_port                   = 9100
  })

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
