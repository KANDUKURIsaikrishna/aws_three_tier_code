# ─────────────────────────────────────────────────────────────────────────────
# RBAC for the monitoring EC2's Prometheus to scrape kubelet's /metrics/cadvisor
# directly on each node (real per-pod CPU/memory usage — kube-state-metrics only
# exposes requests/limits/status, never actual usage).
#
# Kubelet, contacted directly (not proxied through the API server), still
# authorizes every request via a SubjectAccessReview against the API server for
# resource "nodes", subresource "proxy" (get) — this is the standard shape for
# any Prometheus-to-kubelet scrape, in-cluster or not. AmazonEKSViewPolicy
# (already associated with the monitoring EC2's access entry, see
# modules/monitoring-ec2/main.tf) doesn't cover this, so a dedicated
# ClusterRole/ClusterRoleBinding is needed, bound to the stable
# "monitoring-metrics-readers" group set on that access entry rather than the
# principal ARN directly (see the access entry's own comment for why).
# ─────────────────────────────────────────────────────────────────────────────

resource "kubectl_manifest" "monitoring_kubelet_reader_role" {
  yaml_body = <<-YAML
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: monitoring-kubelet-reader
    rules:
      - apiGroups: [""]
        resources: ["nodes/proxy", "nodes/metrics", "nodes/stats"]
        verbs: ["get"]
  YAML

  depends_on = [module.eks]
}

resource "kubectl_manifest" "monitoring_kubelet_reader_binding" {
  yaml_body = <<-YAML
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: monitoring-kubelet-reader
    subjects:
      - kind: Group
        name: monitoring-metrics-readers
        apiGroup: rbac.authorization.k8s.io
    roleRef:
      kind: ClusterRole
      name: monitoring-kubelet-reader
      apiGroup: rbac.authorization.k8s.io
  YAML

  depends_on = [
    module.eks,
    module.monitoring_ec2,
    kubectl_manifest.monitoring_kubelet_reader_role,
  ]
}
