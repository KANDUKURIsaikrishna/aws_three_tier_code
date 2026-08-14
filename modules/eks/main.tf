# ── KMS key for Kubernetes Secrets envelope encryption ────────────────────────
# Without this, K8s Secrets are encrypted at rest only via EBS/etcd-volume
# encryption -- the CIS EKS Benchmark / AWS well-architected baseline expects
# envelope encryption at the API layer too (a compromised etcd snapshot alone
# shouldn't be enough to read Secret contents). Default key policy (no
# explicit `policy` argument) grants the account root user full access, which
# is what lets Terraform's calling principal (needs kms:CreateGrant) provision
# this in the same apply as the cluster -- EKS creates its own grant on the
# key using that principal's permissions during CreateCluster.
resource "aws_kms_key" "eks_secrets" {
  description             = "EKS Kubernetes Secrets envelope encryption for ${var.cluster_name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${var.prefix}-eks-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}

# ── EKS Cluster ───────────────────────────────────────────────────────────────

# EKS auto-creates this log group on first write with no expiry if it doesn't
# already exist. Declaring it here first (all 5 log types are enabled below)
# makes 30-day retention apply from the start instead of needing an import.
resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 30
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.public_access_cidrs
  }

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  enabled_cluster_log_types = [
    "api", "audit", "authenticator", "controllerManager", "scheduler"
  ]

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks_secrets.arn
    }
    resources = ["secrets"]
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_iam_role_policy_attachment.cluster_vpc_controller,
    aws_iam_role_policy.cluster_kms,
    aws_cloudwatch_log_group.eks_cluster,
  ]
}

# ── Admin Access Entries ───────────────────────────────────────────────────────
# bootstrap_cluster_creator_admin_permissions (default true) only fires once, at
# the literal CreateCluster API call — it does not retroactively grant access to
# whoever runs `terraform apply` later, and does not survive a module refactor
# that state-moves this resource without recreating it. These entries are the
# persistent, re-appliable equivalent: every apply ensures every ARN in
# var.admin_principal_arns has cluster-admin, regardless of who created the
# cluster originally.

resource "aws_eks_access_entry" "admin" {
  for_each      = toset(var.admin_principal_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  for_each      = toset(var.admin_principal_arns)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

# ── OIDC Provider (enables IRSA) ──────────────────────────────────────────────

data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

# ── Node Launch Template (node-exporter + Fluent Bit as systemd services) ─────
# AL2 managed node groups merge MIME multipart user-data with EKS bootstrap.
# No AMI ID specified → MNG picks EKS-optimised AL2 AMI and appends bootstrap.

resource "aws_launch_template" "nodes" {
  name_prefix = "${var.prefix}-node-"

  # Explicit gp3 root volume — the EKS-optimized AL2 AMI's default is
  # unmanaged/undeclared otherwise (implicitly gp2). Size matches the AMI
  # default; this is a cost/consistency fix, not a resize.
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type           = "gp3"
      volume_size           = 20
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/node-user-data.sh.tftpl", {
    cluster_name = var.cluster_name
    region       = var.region
  }))

  # hop_limit=2 required: containers on node need one extra hop to reach IMDS
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.prefix}-eks-node" }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── Managed Node Group ────────────────────────────────────────────────────────

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.prefix}-node-group"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = var.subnet_ids

  instance_types = [var.node_instance_type]
  ami_type       = "AL2_x86_64"

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  scaling_config {
    min_size     = var.node_min_size
    max_size     = var.node_max_size
    desired_size = var.node_desired_size
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr_readonly,
  ]

  # Pinned to whatever launch_template.version is already live -- the
  # node-user-data.sh.tftpl Fluent Bit/Loki fix (OBS-050) is staying in the
  # repo, but rolling it onto real nodes needs a surge node during replace,
  # which this account's EC2 vCPU quota (8, steady-state already at 6-8) has
  # no headroom for -- confirmed live: NodeCreationFailure/VcpuLimitExceeded,
  # AWS auto-rolled back to the original 3 nodes. Quota increase requested
  # (8->16) but paused pending it, by request, rather than shrinking node
  # count into an already-tight pod-capacity margin (see node_max_size
  # comment in main.tf, TF-014/OBS-030). Remove this ignore_changes line
  # (or terraform apply -replace) once the quota clears and there's a
  # deliberate window to re-attempt the rollout.
  lifecycle {
    ignore_changes = [launch_template[0].version]
  }
}
