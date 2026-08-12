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

  # Just the EKS-node subnets (indices 0-3 above) -- used to scope the RDS
  # security group to actual node traffic instead of the whole VPC CIDR.
  # See docs/TROUBLESHOOTING.md OBS-049.
  eks_node_subnet_cidrs = [for s in slice(local.private_subnets, 0, 4) : s.cidr]
}
