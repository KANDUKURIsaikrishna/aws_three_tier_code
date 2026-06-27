locals {
  vpc_cidr = "170.20.0.0/16"

  public_subnets = [
    { cidr = "170.20.1.0/24", az = "us-west-1a" },
    { cidr = "170.20.2.0/24", az = "us-west-1c" },
  ]

  # Index layout:
  #   [0-3] EKS node subnets  (alternating AZs)
  #   [4-5] RDS subnets       (one per AZ for Multi-AZ)
  private_subnets = [
    { cidr = "170.20.3.0/24", az = "us-west-1a" },
    { cidr = "170.20.4.0/24", az = "us-west-1c" },
    { cidr = "170.20.5.0/24", az = "us-west-1a" },
    { cidr = "170.20.6.0/24", az = "us-west-1c" },
    { cidr = "170.20.7.0/24", az = "us-west-1a" },
    { cidr = "170.20.8.0/24", az = "us-west-1c" },
  ]
}
