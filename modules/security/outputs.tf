output "rds_sg_id" {
  description = "SG for RDS — allows MySQL from EKS node subnets only"
  value       = aws_security_group.rds.id
}
