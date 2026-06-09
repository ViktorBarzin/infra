resource "kubernetes_deployment" "goflow2" {
  metadata {
    name      = "goflow2"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app  = "goflow2"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "goflow2"
      }
    }
    template {
      metadata {
        labels = {
          app = "goflow2"
        }
      }
      spec {
        container {
          name  = "goflow2"
          image = "netsampler/goflow2:v2.2.1"
          args  = ["-listen", "netflow://:2055"]

          port {
            name           = "netflow"
            container_port = 2055
            protocol       = "UDP"
          }
          port {
            name           = "metrics"
            container_port = 8080
            protocol       = "TCP"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    # KEEL: monitoring ns is keel-enrolled (policy=patch) — Keel owns the image
    # tag and injects keel.sh annotations. Ignore so TF stops reverting Keel each
    # plan (completes the cdb7d9a8 KEEL sweep that missed these exporters and was
    # tripping drift-detection exit 2 every run). 2026-05-31.
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "goflow2" {
  metadata {
    name      = "goflow2"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app = "goflow2"
    }
  }
  spec {
    selector = {
      app = "goflow2"
    }
    port {
      name        = "metrics"
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_service" "goflow2-netflow" {
  metadata {
    name      = "goflow2-netflow"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app = "goflow2"
    }
  }
  spec {
    type = "NodePort"
    selector = {
      app = "goflow2"
    }
    port {
      name        = "netflow"
      port        = 2055
      target_port = 2055
      protocol    = "UDP"
      node_port   = 32055
    }
  }
}
