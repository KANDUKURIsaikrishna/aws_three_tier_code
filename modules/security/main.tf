resource "aws_security_group" "rds" {
  name        = "${var.prefix}-rds-sg"
  description = "RDS: allow MySQL from EKS node subnets only"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.prefix}-rds-sg" }
}

resource "aws_security_group_rule" "rds_mysql_in" {
  type              = "ingress"
  from_port         = 3306
  to_port           = 3306
  protocol          = "tcp"
  cidr_blocks       = var.eks_node_cidr_blocks
  security_group_id = aws_security_group.rds.id
  description       = "MySQL from EKS node subnets"
}

# RDS does not initiate outbound connections — no egress rule needed.
