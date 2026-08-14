# eks

EKS cluster, managed node group, OIDC provider (IRSA), KMS-encrypted Kubernetes Secrets, and the node launch template that installs node-exporter + Fluent Bit as systemd services. See [../../docs/TERRAFORM.md](../../docs/TERRAFORM.md#module-eks).


<!-- BEGIN_TF_DOCS -->
## Requirements

No requirements.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_log_group.eks_cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_eks_access_entry.admin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_entry) | resource |
| [aws_eks_access_policy_association.admin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_policy_association) | resource |
| [aws_eks_cluster.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster) | resource |
| [aws_eks_node_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_node_group) | resource |
| [aws_iam_openid_connect_provider.eks](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider) | resource |
| [aws_iam_role.cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.node_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.cluster_kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.node_describe_instances](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.cluster_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.cluster_vpc_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.node_cni](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.node_ecr_readonly](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.node_worker](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_kms_alias.eks_secrets](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.eks_secrets](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_launch_template.nodes](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_admin_principal_arns"></a> [admin\_principal\_arns](#input\_admin\_principal\_arns) | IAM principal ARNs granted cluster-admin via EKS access entries (AmazonEKSClusterAdminPolicy). bootstrap\_cluster\_creator\_admin\_permissions only fires once at cluster creation and doesn't cover later operators/CI roles — this list is the persistent, re-appliable alternative. | `list(string)` | `[]` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name of the EKS cluster | `string` | `"bookstore-eks"` | no |
| <a name="input_cluster_version"></a> [cluster\_version](#input\_cluster\_version) | Kubernetes version for the EKS cluster | `string` | `"1.31"` | no |
| <a name="input_node_desired_size"></a> [node\_desired\_size](#input\_node\_desired\_size) | Desired number of worker nodes at rest | `number` | `1` | no |
| <a name="input_node_instance_type"></a> [node\_instance\_type](#input\_node\_instance\_type) | EC2 instance type for worker nodes | `string` | `"t3.medium"` | no |
| <a name="input_node_max_size"></a> [node\_max\_size](#input\_node\_max\_size) | Maximum number of worker nodes | `number` | `2` | no |
| <a name="input_node_min_size"></a> [node\_min\_size](#input\_node\_min\_size) | Minimum number of worker nodes | `number` | `1` | no |
| <a name="input_prefix"></a> [prefix](#input\_prefix) | Prefix applied to all IAM and resource names | `string` | `"bookstore"` | no |
| <a name="input_public_access_cidrs"></a> [public\_access\_cidrs](#input\_public\_access\_cidrs) | CIDR blocks allowed to reach the public EKS API endpoint. Restrict to admin IP ranges in production (e.g. ["203.0.113.0/24"]). Default allows all — narrow before go-live. | `list(string)` | ```[ "0.0.0.0/0" ]``` | no |
| <a name="input_region"></a> [region](#input\_region) | AWS region — nodes use this to call ec2:DescribeInstances at boot, discovering the monitoring EC2's private IP for Fluent Bit's Loki output. Not templated as a static loki\_url: that would need this module to depend on module.monitoring\_ec2's actual instance, which itself depends on this module's cluster\_name -- a circular dependency. Runtime discovery via the same AWS-API-lookup pattern already used elsewhere in this project (see modules/monitoring-ec2's own node-IP discovery) sidesteps it entirely. See docs/TROUBLESHOOTING.md OBS-050. | `string` | n/a | yes |
| <a name="input_subnet_ids"></a> [subnet\_ids](#input\_subnet\_ids) | Private subnet IDs for the control plane and node groups | `list(string)` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_cluster_ca_certificate"></a> [cluster\_ca\_certificate](#output\_cluster\_ca\_certificate) | Base64-encoded CA certificate for the cluster |
| <a name="output_cluster_endpoint"></a> [cluster\_endpoint](#output\_cluster\_endpoint) | EKS API server endpoint |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | Name of the EKS cluster |
| <a name="output_cluster_security_group_id"></a> [cluster\_security\_group\_id](#output\_cluster\_security\_group\_id) | Auto-created EKS cluster security group — applied to all nodes; monitoring EC2 gets inbound rules here |
| <a name="output_node_role_name"></a> [node\_role\_name](#output\_node\_role\_name) | IAM role name of the EKS node group — passed to eks-addons for policy attachment |
| <a name="output_oidc_provider_arn"></a> [oidc\_provider\_arn](#output\_oidc\_provider\_arn) | ARN of the OIDC provider — used to create IRSA roles |
| <a name="output_oidc_provider_url"></a> [oidc\_provider\_url](#output\_oidc\_provider\_url) | URL of the OIDC provider |
<!-- END_TF_DOCS -->