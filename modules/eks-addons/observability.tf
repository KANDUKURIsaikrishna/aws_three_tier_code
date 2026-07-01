# Monitoring stack moved to dedicated EC2 instance (modules/monitoring-ec2).
# EKS cluster runs zero monitoring pods — node-exporter and Fluent Bit are
# installed as systemd services via the EKS node group launch template.
# kube-state-metrics runs as a Docker container on the monitoring EC2.
