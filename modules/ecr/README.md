# ecr

ECR repositories (one per service, generalized via `extra_repos`), image scanning on push, lifecycle retention policy, and optional cross-region replication. See [../../docs/TERRAFORM.md](../../docs/TERRAFORM.md#module-ecr).


<!-- BEGIN_TF_DOCS -->
## Requirements

No requirements.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_ecr_lifecycle_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_lifecycle_policy) | resource |
| [aws_ecr_replication_configuration.secondary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_replication_configuration) | resource |
| [aws_ecr_repository.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_repository) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_extra_repos"></a> [extra\_repos](#input\_extra\_repos) | Additional short repo names (without prefix) to create, e.g. ["catalog-service"] | `list(string)` | `[]` | no |
| <a name="input_image_retention_count"></a> [image\_retention\_count](#input\_image\_retention\_count) | Number of images to keep per repository | `number` | `10` | no |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | n/a | `string` | `"bookstore"` | no |
| <a name="input_secondary_region"></a> [secondary\_region](#input\_secondary\_region) | Secondary AWS region for cross-region image replication. Empty string disables replication. | `string` | `""` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_frontend_repo_url"></a> [frontend\_repo\_url](#output\_frontend\_repo\_url) | ECR URL for the frontend image |
| <a name="output_registry_id"></a> [registry\_id](#output\_registry\_id) | AWS account ID owning the registry |
| <a name="output_repo_urls"></a> [repo\_urls](#output\_repo\_urls) | Map of short repo name (without prefix) to ECR repository URL — covers frontend and all extra\_repos |
<!-- END_TF_DOCS -->