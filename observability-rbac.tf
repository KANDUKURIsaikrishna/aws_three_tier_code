# ─────────────────────────────────────────────────────────────────────────────
# RBAC for the monitoring EC2's Prometheus to scrape:
#   1. kubelet's /metrics/cadvisor directly on each node (real per-pod
#      CPU/memory usage — kube-state-metrics only exposes requests/limits/
#      status, never actual usage) -- needs "nodes/proxy" et al.
#   2. each app pod's own /metrics (prom-client, HTTP request counters/
#      histograms) via the API server's pod-proxy endpoint, since ClusterIP
#      Services and pod IPs aren't reachable from outside the cluster's pod
#      network the way node-hosted processes are -- needs "pods/proxy".
#
# Both are authorized via a SubjectAccessReview against the API server (get
# on the given subresource) — the standard shape for any out-of-cluster
# Prometheus scrape of either kind. AmazonEKSViewPolicy (already associated
# with the monitoring EC2's access entry) doesn't cover either, so a
# dedicated ClusterRole/ClusterRoleBinding is needed, bound to the stable
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
        resources: ["nodes/proxy", "nodes/metrics", "nodes/stats", "pods/proxy"]
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
