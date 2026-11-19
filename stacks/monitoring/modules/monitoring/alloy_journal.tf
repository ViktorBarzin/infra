# Journal receiver for hosts outside the cluster: systemd-journal-remote plus
# Alloy in one pod, values in alloy-journal.yaml. ha-london uploads its whole
# journal (kernel, Home Assistant, Supervisor, add-ons) here through the
# journal_upload add-on (ha-addons/journal_upload). Separate one-replica
# release, like alloy-syslog, so the log-shipping DaemonSet's rolls never
# interrupt it. Chart pinned with the other two Alloy releases.
resource "helm_release" "alloy_journal" {
  namespace = kubernetes_namespace.monitoring.metadata[0].name
  name      = "alloy-journal"

  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = "1.16.0"

  values          = [file("${path.module}/alloy-journal.yaml")]
  atomic          = true
  cleanup_on_fail = true
  timeout         = 300
  max_history     = 10

  depends_on = [helm_release.loki]
}

# Upload endpoint on the shared MetalLB address. Reached from London over the
# site-to-site WireGuard tunnel (OPNsense passes all WireGuard traffic in).
# Only the journal-remote port is exposed; Alloy's own UI stays ClusterIP.
resource "kubernetes_service" "alloy_journal_upload" {
  metadata {
    name      = "alloy-journal-upload"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      "app.kubernetes.io/name"     = "alloy"
      "app.kubernetes.io/instance" = "alloy-journal"
    }
    annotations = {
      "metallb.universe.tf/loadBalancerIPs" = "10.0.20.200"
      "metallb.io/allow-shared-ip"          = "shared"
    }
  }
  lifecycle {
    # METALLB_LIFECYCLE_V1: MetalLB's controller writes this annotation on the
    # live object after it allocates an IP. Without the ignore, every apply
    # plans to strip it and MetalLB re-adds it — permanent drift.
    ignore_changes = [metadata[0].annotations["metallb.io/ip-allocated-from-pool"]]
  }
  spec {
    type = "LoadBalancer"
    selector = {
      "app.kubernetes.io/name"     = "alloy"
      "app.kubernetes.io/instance" = "alloy-journal"
    }
    port {
      name        = "journal-upload"
      port        = 19532
      target_port = 19532
      protocol    = "TCP"
    }
  }
}
