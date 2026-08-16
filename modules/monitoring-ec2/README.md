# monitoring-ec2

Standalone EC2 instance running Prometheus, Grafana, Loki, Alertmanager, and kube-state-metrics via Docker Compose — deliberately outside the EKS cluster (see [../../docs/TERRAFORM.md](../../docs/TERRAFORM.md#module-monitoring-ec2) for why).


<!-- BEGIN_TF_DOCS -->
## Requirements

No requirements.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_eip_association.monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eip_association) | resource |
| [aws_eks_access_entry.monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_entry) | resource |
| [aws_eks_access_policy_association.monitoring_view](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_policy_association) | resource |
| [aws_iam_instance_profile.monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_role.monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_instance.monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance) | resource |
| [aws_key_pair.monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/key_pair) | resource |
| [aws_security_group.monitoring](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group_rule.eks_scrape_node_exporter](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.monitoring_scrape_eks_api](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.monitoring_scrape_kubelet](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [tls_private_key.monitoring_ssh](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_admin_cidr_blocks"></a> [admin\_cidr\_blocks](#input\_admin\_cidr\_blocks) | CIDRs allowed to access Grafana (3000) and Prometheus (9090) | `list(string)` | ```[ "0.0.0.0/0" ]``` | no |
| <a name="input_alertmanager_smtp_secret_arn"></a> [alertmanager\_smtp\_secret\_arn](#input\_alertmanager\_smtp\_secret\_arn) | Secrets Manager secret ARN for Alertmanager's SES SMTP credentials (JSON: SMTP\_HOST/PORT/USERNAME/PASSWORD/FROM/TO) — EC2 IAM policy allows GetSecretValue on this ARN | `string` | n/a | yes |
| <a name="input_alertmanager_smtp_secret_name"></a> [alertmanager\_smtp\_secret\_name](#input\_alertmanager\_smtp\_secret\_name) | Secrets Manager secret name (path) for Alertmanager's SES SMTP credentials | `string` | n/a | yes |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | EKS cluster name — used to discover node IPs at boot | `string` | n/a | yes |
| <a name="input_eip_allocation_id"></a> [eip\_allocation\_id](#input\_eip\_allocation\_id) | Elastic IP allocation ID to associate with the monitoring instance | `string` | n/a | yes |
| <a name="input_eks_api_server"></a> [eks\_api\_server](#input\_eks\_api\_server) | EKS cluster API server endpoint URL (e.g. https://XXXX.gr7.<region>.eks.amazonaws.com) — used by Prometheus's kubernetes\_sd\_configs to discover pods and scrape app-level /metrics via the API server's pod-proxy, since pod IPs aren't reachable from outside the cluster network. Templated, not hardcoded, so it doesn't go stale like OBS-032's literal IP did — a fresh endpoint every apply is picked up automatically. | `string` | n/a | yes |
| <a name="input_eks_cluster_sg_id"></a> [eks\_cluster\_sg\_id](#input\_eks\_cluster\_sg\_id) | EKS cluster security group ID — monitoring EC2 gets inbound rule to scrape node-exporter on port 9100 | `string` | n/a | yes |
| <a name="input_grafana_admin_secret_arn"></a> [grafana\_admin\_secret\_arn](#input\_grafana\_admin\_secret\_arn) | Secrets Manager secret ARN for Grafana admin password — EC2 IAM policy allows GetSecretValue on this ARN | `string` | n/a | yes |
| <a name="input_grafana_admin_secret_name"></a> [grafana\_admin\_secret\_name](#input\_grafana\_admin\_secret\_name) | Secrets Manager secret name (path) for Grafana admin password | `string` | `"/bookstore/grafana-admin"` | no |
| <a name="input_instance_type"></a> [instance\_type](#input\_instance\_type) | EC2 instance type for the monitoring server | `string` | `"t3.small"` | no |
| <a name="input_monitoring_basic_auth_secret_arn"></a> [monitoring\_basic\_auth\_secret\_arn](#input\_monitoring\_basic\_auth\_secret\_arn) | Secrets Manager secret ARN for the shared Prometheus/Alertmanager basic-auth password — EC2 IAM policy allows GetSecretValue on this ARN | `string` | n/a | yes |
| <a name="input_monitoring_basic_auth_secret_name"></a> [monitoring\_basic\_auth\_secret\_name](#input\_monitoring\_basic\_auth\_secret\_name) | Secrets Manager secret name (path) for the shared Prometheus/Alertmanager basic-auth password | `string` | `"/bookstore/monitoring-basic-auth"` | no |
| <a name="input_public_subnet_id"></a> [public\_subnet\_id](#input\_public\_subnet\_id) | Public subnet for the monitoring EC2 instance | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | AWS region | `string` | n/a | yes |
| <a name="input_vpc_cidr"></a> [vpc\_cidr](#input\_vpc\_cidr) | VPC CIDR block — allows Fluent Bit on EKS nodes to push logs to Loki | `string` | n/a | yes |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | VPC where the monitoring EC2 instance is deployed | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alertmanager_url"></a> [alertmanager\_url](#output\_alertmanager\_url) | Alertmanager UI URL |
| <a name="output_grafana_url"></a> [grafana\_url](#output\_grafana\_url) | Grafana UI URL |
| <a name="output_instance_public_ip"></a> [instance\_public\_ip](#output\_instance\_public\_ip) | Public IP of the monitoring EC2 instance (Elastic IP) |
| <a name="output_loki_url"></a> [loki\_url](#output\_loki\_url) | Loki base URL — used by Promtail in EKS to push logs |
| <a name="output_prometheus_url"></a> [prometheus\_url](#output\_prometheus\_url) | Prometheus UI URL |
| <a name="output_ssh_private_key_pem"></a> [ssh\_private\_key\_pem](#output\_ssh\_private\_key\_pem) | Auto-generated SSH private key for the monitoring EC2 (user: ubuntu) — see Makefile's monitoring-key target |
<!-- END_TF_DOCS -->