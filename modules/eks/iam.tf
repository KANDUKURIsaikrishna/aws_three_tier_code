# ── Cluster IAM Role ──────────────────────────────────────────────────────────

resource "aws_iam_role" "cluster" {
  name = "${var.prefix}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "cluster_vpc_controller" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

# EKS itself creates its own KMS grant on cluster creation using the calling
# principal's permissions, so this isn't strictly required for the cluster to
# come up -- added anyway as defense-in-depth so the cluster role's own
# permission set is self-sufficient for envelope encryption, not solely
# dependent on whoever happens to run `terraform apply` also holding
# kms:CreateGrant on this key.
resource "aws_iam_role_policy" "cluster_kms" {
  name = "${var.prefix}-eks-cluster-kms"
  role = aws_iam_role.cluster.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
      Resource = aws_kms_key.eks_secrets.arn
    }]
  })
}

# ── Node Group IAM Role ───────────────────────────────────────────────────────

resource "aws_iam_role" "node_group" {
  name = "${var.prefix}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_readonly" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Lets each node discover the monitoring EC2's private IP at boot (used by
# Fluent Bit's Loki output) via aws ec2 describe-instances, same pattern the
# monitoring EC2 itself already uses to discover node IPs. Read-only,
# same shape as modules/monitoring-ec2's own ec2:DescribeInstances grant.
# Discovering the IP at runtime avoids a circular module dependency: this
# module (eks) is a dependency OF module.monitoring_ec2 (which needs
# cluster_name), so eks can't take monitoring_ec2's private IP as a
# Terraform-time input without a cycle. See docs/TROUBLESHOOTING.md OBS-050.
resource "aws_iam_role_policy" "node_describe_instances" {
  name = "${var.prefix}-node-describe-instances"
  role = aws_iam_role.node_group.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:DescribeInstances"]
      Resource = "*"
    }]
  })
}
