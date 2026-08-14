# rds

MySQL RDS instance: Multi-AZ, encrypted at rest, autoscaling storage, Secrets Manager–backed admin credentials with optional automatic rotation and cross-region replication. See [../../docs/TERRAFORM.md](../../docs/TERRAFORM.md#module-rds).


<!-- BEGIN_TF_DOCS -->
## Requirements

No requirements.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_log_group.rds](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_db_instance.db](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance) | resource |
| [aws_db_subnet_group.rds_subnet_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_subnet_group) | resource |
| [aws_iam_role.rds_monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.rds_monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_secretsmanager_secret.db_credentials](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_rotation.db_credentials](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_rotation) | resource |
| [aws_secretsmanager_secret_version.db_credentials](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [random_password.db_password](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_backup_retention_period"></a> [backup\_retention\_period](#input\_backup\_retention\_period) | Days to retain automated backups (0 disables backups) | `number` | `7` | no |
| <a name="input_db_allocated_storage"></a> [db\_allocated\_storage](#input\_db\_allocated\_storage) | Allocated storage in GB | `number` | n/a | yes |
| <a name="input_db_engine"></a> [db\_engine](#input\_db\_engine) | Database engine (mysql, postgres, etc.) | `string` | `"mysql"` | no |
| <a name="input_db_engine_version"></a> [db\_engine\_version](#input\_db\_engine\_version) | Database engine version | `string` | `"8.0"` | no |
| <a name="input_db_identifier"></a> [db\_identifier](#input\_db\_identifier) | RDS instance identifier | `string` | n/a | yes |
| <a name="input_db_instance_class"></a> [db\_instance\_class](#input\_db\_instance\_class) | RDS instance type | `string` | n/a | yes |
| <a name="input_db_name"></a> [db\_name](#input\_db\_name) | Initial database name | `string` | n/a | yes |
| <a name="input_db_security_group_id"></a> [db\_security\_group\_id](#input\_db\_security\_group\_id) | Security group ID attached to RDS | `string` | n/a | yes |
| <a name="input_db_subnet_ids"></a> [db\_subnet\_ids](#input\_db\_subnet\_ids) | Subnet IDs for RDS subnet group (need at least 2 AZs) | `list(string)` | n/a | yes |
| <a name="input_db_username"></a> [db\_username](#input\_db\_username) | Master username | `string` | n/a | yes |
| <a name="input_deletion_protection"></a> [deletion\_protection](#input\_deletion\_protection) | Prevent accidental deletion of the RDS instance | `bool` | `true` | no |
| <a name="input_kms_key_arn"></a> [kms\_key\_arn](#input\_kms\_key\_arn) | KMS key ARN for storage encryption. Null = AWS-managed key. | `string` | `null` | no |
| <a name="input_max_allocated_storage"></a> [max\_allocated\_storage](#input\_max\_allocated\_storage) | Upper limit for RDS storage autoscaling in GB. 0 = disabled. | `number` | `100` | no |
| <a name="input_multi_az"></a> [multi\_az](#input\_multi\_az) | Enable Multi-AZ for high availability | `bool` | `true` | no |
| <a name="input_rotation_days"></a> [rotation\_days](#input\_rotation\_days) | Number of days between automatic secret rotations. | `number` | `30` | no |
| <a name="input_rotation_lambda_arn"></a> [rotation\_lambda\_arn](#input\_rotation\_lambda\_arn) | ARN of the Secrets Manager rotation Lambda. Empty string disables automatic rotation. Deploy aws-samples/aws-secrets-manager-rotation-lambdas (single-user MySQL) to get the ARN. | `string` | `""` | no |
| <a name="input_secondary_region"></a> [secondary\_region](#input\_secondary\_region) | Secondary AWS region for Secrets Manager replication. Empty string disables replication. | `string` | `""` | no |
| <a name="input_skip_final_snapshot"></a> [skip\_final\_snapshot](#input\_skip\_final\_snapshot) | Skip final DB snapshot on destroy. Set false in production to preserve a recovery point before deletion. | `bool` | `false` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_db_credentials_secret_arn"></a> [db\_credentials\_secret\_arn](#output\_db\_credentials\_secret\_arn) | ARN of the Secrets Manager secret at /bookstore/db-credentials (DB\_USERNAME, DB\_PASSWORD, DB\_HOST) |
| <a name="output_rds_endpoint"></a> [rds\_endpoint](#output\_rds\_endpoint) | RDS connection hostname (bare address, no port — see comment above) |
| <a name="output_rds_instance_arn"></a> [rds\_instance\_arn](#output\_rds\_instance\_arn) | RDS instance ARN — used for cross-region backup replication |
| <a name="output_rds_instance_id"></a> [rds\_instance\_id](#output\_rds\_instance\_id) | RDS instance ID |
| <a name="output_rds_subnet_group"></a> [rds\_subnet\_group](#output\_rds\_subnet\_group) | RDS subnet group name |
<!-- END_TF_DOCS -->