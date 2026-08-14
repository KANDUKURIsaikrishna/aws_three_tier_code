# security

Security groups: RDS (3306, scoped to EKS node subnet CIDRs only — see OBS-049) and any other project-level SGs. See [../../docs/TERRAFORM.md](../../docs/TERRAFORM.md#module-security).


<!-- BEGIN_TF_DOCS -->
## Requirements

No requirements.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_security_group.rds](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group_rule.rds_mysql_in](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_eks_node_cidr_blocks"></a> [eks\_node\_cidr\_blocks](#input\_eks\_node\_cidr\_blocks) | CIDR blocks of the EKS node private subnets, allowed to reach RDS on 3306. Previously this rule opened 3306 to the entire VPC CIDR (public subnets, RDS's own subnets, everything) despite its description claiming EKS-nodes-only — see docs/TROUBLESHOOTING.md OBS-049. | `list(string)` | n/a | yes |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | Prefix applied to all resource names | `string` | `"bookstore"` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | VPC ID where security groups are created | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_rds_sg_id"></a> [rds\_sg\_id](#output\_rds\_sg\_id) | SG for RDS — allows MySQL from EKS node subnets only |
<!-- END_TF_DOCS -->