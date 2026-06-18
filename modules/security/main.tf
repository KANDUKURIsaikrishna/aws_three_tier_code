# ── Security Groups ────────────────────────────────────────────────────────

resource "aws_security_group" "alb_frontend" {
  name        = "${var.prefix}-alb-frontend-sg"
  description = "Internet-facing ingress load balancer: allow HTTP/HTTPS from anywhere"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.prefix}-alb-frontend-sg" }
}

resource "aws_security_group" "rds" {
  name        = "${var.prefix}-rds-sg"
  description = "RDS: allow MySQL from EKS nodes (private subnets)"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.prefix}-rds-sg" }
}

# ── Ingress Rules ──────────────────────────────────────────────────────────

resource "aws_security_group_rule" "alb_frontend_http_in" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb_frontend.id
  description       = "HTTP from internet"
}

resource "aws_security_group_rule" "alb_frontend_https_in" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb_frontend.id
  description       = "HTTPS from internet"
}

# EKS nodes in private subnets (170.20.3-6.x) connect to RDS
resource "aws_security_group_rule" "rds_mysql_in" {
  type              = "ingress"
  from_port         = 3306
  to_port           = 3306
  protocol          = "tcp"
  cidr_blocks       = ["170.20.0.0/16"]
  security_group_id = aws_security_group.rds.id
  description       = "MySQL from EKS nodes in VPC"
}

# ── Egress Rules ───────────────────────────────────────────────────────────

resource "aws_security_group_rule" "alb_frontend_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb_frontend.id
}

resource "aws_security_group_rule" "rds_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.rds.id
}
