output "alb_frontend_sg_id" {
  description = "SG for internet-facing ingress load balancer"
  value       = aws_security_group.alb_frontend.id
}

output "rds_sg_id" {
  description = "SG for RDS — allows MySQL from VPC private subnets"
  value       = aws_security_group.rds.id
}
