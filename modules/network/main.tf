# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "bookstore-vpc" }
}

# Public subnets
# nosemgrep: terraform.aws.security.aws-subnet-has-public-ip-address.aws-subnet-has-public-ip-address
resource "aws_subnet" "public" {
  count                   = length(var.public_subnets)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnets[count.index].cidr
  availability_zone       = var.public_subnets[count.index].az
  map_public_ip_on_launch = true
  tags                    = { Name = "public-subnet-${count.index + 1}" }
}

# Private subnets
resource "aws_subnet" "private" {
  count             = length(var.private_subnets)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnets[count.index].cidr
  availability_zone = var.private_subnets[count.index].az
  tags              = { Name = "private-subnet-${count.index + 1}" }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "bookstore-igw" }
}

# Elastic IP for NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"
}

# NAT Gateway (single AZ — cost optimised for tech demo; add per-AZ for HA)
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "bookstore-nat" }

  depends_on = [aws_internet_gateway.igw]
}

# Public Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "bookstore-public-rt" }
}

# Private Route Table
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "bookstore-private-rt" }
}

# VPC Flow Logs → CloudWatch Logs (90-day retention)
resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/flowlogs/bookstore"
  retention_in_days = 90
}

resource "aws_iam_role" "vpc_flow_log" {
  name = "bookstore-vpc-flow-log-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "vpc_flow_log" {
  role = aws_iam_role.vpc_flow_log.id

  # Split from a single Resource="*" statement: CreateLogGroup/DescribeLogGroups
  # are list/discovery-type actions AWS's own IAM reference doesn't support
  # scoping below "*" for, but the actual stream-level write actions
  # (CreateLogStream/PutLogEvents/DescribeLogStreams) can and should be scoped
  # to just this flow log's own log group.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:DescribeLogGroups",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = "${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"
      }
    ]
  })
}

resource "aws_flow_log" "vpc" {
  iam_role_arn    = aws_iam_role.vpc_flow_log.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.main.id

  # Must be destroyed BEFORE force_delete_flow_log_group's destroy-time
  # cleanup runs below — see that resource's comment for why the ordering
  # matters (deleting the log group while this is still live makes AWS
  # recreate it).
  depends_on = [null_resource.force_delete_flow_log_group]
}

# ── Destroy safety net ──────────────────────────────────────────────────────
# Root cause found via CloudTrail (2026-07-21, lookup-events by EventName, not
# ResourceName — the latter returns nothing for this event type and was a dead
# end): AWS's VPC Flow Logs service self-heals its destination log group. The
# IAM role below grants it logs:CreateLogGroup; if the log group vanishes while
# aws_flow_log.vpc is still actively delivering records, the service recreates
# it using that permission (CloudTrail shows the creator as
# "vpc-flow-logging+<account>", not Terraform).
#
# Ordering bug found 2026-08-16 (orphan log group survived a real destroy
# cycle): this resource previously had depends_on = [aws_flow_log.vpc], which
# on destroy runs the OPPOSITE direction from what's needed — Terraform
# destroys a dependent before the thing it depends on, so that made this
# delete the log group first, while aws_flow_log.vpc was still live and still
# delivering. AWS's self-heal then recreated it right back. Fixed by flipping
# the dependency: aws_flow_log.vpc now depends_on this resource, so on
# destroy aws_flow_log.vpc is torn down FIRST (delivery stops), then this
# runs. The sleep below is a grace period for any in-flight delivery API
# calls to finish, not the fix itself.
# Best-effort only (|| true) — requires aws CLI on whatever machine runs
# `terraform destroy`.
resource "null_resource" "force_delete_flow_log_group" {
  triggers = {
    log_group_name = aws_cloudwatch_log_group.vpc_flow_logs.name
    region         = data.aws_region.current.name
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      sleep 15
      aws logs delete-log-group --log-group-name '${self.triggers.log_group_name}' --region ${self.triggers.region} 2>/dev/null || true
    EOT
  }
}

data "aws_region" "current" {}

# S3 Gateway VPC Endpoint — free (no hourly/data charge), routes S3 traffic
# (ECR image layers are stored in S3, plus Terraform state reads) off the
# single NAT Gateway instead of paying its per-GB data-processing fee for it.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id, aws_route_table.private.id]
  tags              = { Name = "bookstore-s3-endpoint" }
}

# Route Table Associations
resource "aws_route_table_association" "public" {
  count          = length(var.public_subnets)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(var.private_subnets)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
