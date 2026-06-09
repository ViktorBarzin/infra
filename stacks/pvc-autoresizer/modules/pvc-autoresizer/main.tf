variable "tier" { type = string }

resource "kubernetes_namespace" "pvc_autoresizer" {
  metadata {
    name = "pvc-autoresizer"
    labels = {
      tier = var.tier
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "helm_release" "pvc_autoresizer" {
  namespace        = kubernetes_namespace.pvc_autoresizer.metadata[0].name
  create_namespace = false
  name             = "pvc-autoresizer"
  atomic           = true
  timeout          = 300

  repository = "https://topolvm.github.io/pvc-autoresizer"
  chart      = "pvc-autoresizer"

  values = [yamlencode({
    controller = {
      args = {
        prometheusURL = "http://prometheus-server.monitoring.svc.cluster.local:80"
        interval      = "10m"
      }
      resources = {
        requests = {
          memory = "64Mi"
          cpu    = "10m"
        }
        limits = {
          memory = "128Mi"
        }
      }
    }
    webhook = {
      certificate = {
        generate = true
      }
      pvcMutatingWebhook = {
        enabled = false
      }
    }
  })]
}
