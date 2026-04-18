variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }


resource "kubernetes_namespace" "osm-routing" {
  metadata {
    name = "osm-routing"
    labels = {
      "istio-injection" : "disabled"
      tier                               = local.tiers.aux
      "resource-governance/custom-quota" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_resource_quota_v1" "osm_routing" {
  metadata {
    name      = "tier-quota"
    namespace = kubernetes_namespace.osm-routing.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "4"
      "requests.memory" = "6Gi"
      "limits.cpu"      = "16"
      "limits.memory"   = "16Gi"
      pods              = "20"
    }
  }
}

module "nfs_osrm_data_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "osm-routing-osrm-data-host"
  namespace  = kubernetes_namespace.osm-routing.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/osm-routing/osrm"
}

module "nfs_otp_data_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "osm-routing-otp-data-host"
  namespace  = kubernetes_namespace.osm-routing.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/osm-routing/otp"
}

# --- OSRM Foot ---
resource "kubernetes_deployment" "osrm-foot" {
  metadata {
    name      = "osrm-foot"
    namespace = kubernetes_namespace.osm-routing.metadata[0].name
    labels = {
      app  = "osrm-foot"
      tier = local.tiers.aux
    }
  }
  spec {
    # Disabled: reduce cluster memory pressure (2026-03-14 OOM incident)
    replicas = 0
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "osrm-foot"
      }
    }
    template {
      metadata {
        labels = {
          app = "osrm-foot"
        }
      }
      spec {
        container {
          name    = "osrm-foot"
          image   = "ghcr.io/project-osrm/osrm-backend:latest"
          command = ["osrm-routed", "--algorithm", "MLD", "/data/foot/greater-london-latest.osrm"]
          port {
            name           = "http"
            container_port = 5000
            protocol       = "TCP"
          }
          volume_mount {
            name       = "osrm-data"
            mount_path = "/data"
          }
          resources {
            requests = {
              cpu    = "15m"
              memory = "256Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
        volume {
          name = "osrm-data"
          persistent_volume_claim {
            claim_name = module.nfs_osrm_data_host.claim_name
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_service" "osrm-foot" {
  metadata {
    name      = "osrm-foot"
    namespace = kubernetes_namespace.osm-routing.metadata[0].name
    labels = {
      app = "osrm-foot"
    }
  }
  spec {
    selector = {
      app = "osrm-foot"
    }
    port {
      port        = 5000
      target_port = 5000
    }
  }
}

# --- OSRM Bicycle ---
resource "kubernetes_deployment" "osrm-bicycle" {
  metadata {
    name      = "osrm-bicycle"
    namespace = kubernetes_namespace.osm-routing.metadata[0].name
    labels = {
      app  = "osrm-bicycle"
      tier = local.tiers.aux
    }
  }
  spec {
    # Disabled: reduce cluster memory pressure (2026-03-14 OOM incident)
    replicas = 0
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "osrm-bicycle"
      }
    }
    template {
      metadata {
        labels = {
          app = "osrm-bicycle"
        }
      }
      spec {
        container {
          name    = "osrm-bicycle"
          image   = "ghcr.io/project-osrm/osrm-backend:latest"
          command = ["osrm-routed", "--algorithm", "MLD", "/data/bicycle/greater-london-latest.osrm"]
          port {
            name           = "http"
            container_port = 5000
            protocol       = "TCP"
          }
          volume_mount {
            name       = "osrm-data"
            mount_path = "/data"
          }
          resources {
            requests = {
              cpu    = "15m"
              memory = "256Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
        volume {
          name = "osrm-data"
          persistent_volume_claim {
            claim_name = module.nfs_osrm_data_host.claim_name
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_service" "osrm-bicycle" {
  metadata {
    name      = "osrm-bicycle"
    namespace = kubernetes_namespace.osm-routing.metadata[0].name
    labels = {
      app = "osrm-bicycle"
    }
  }
  spec {
    selector = {
      app = "osrm-bicycle"
    }
    port {
      port        = 5000
      target_port = 5000
    }
  }
}

# --- OTP (OpenTripPlanner) ---
resource "kubernetes_deployment" "otp" {
  metadata {
    name      = "otp"
    namespace = kubernetes_namespace.osm-routing.metadata[0].name
    labels = {
      app  = "otp"
      tier = local.tiers.aux
    }
  }
  spec {
    # Disabled: reduce cluster memory pressure (2026-03-14 OOM incident)
    replicas = 0
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "otp"
      }
    }
    template {
      metadata {
        labels = {
          app = "otp"
        }
      }
      spec {
        container {
          name  = "otp"
          image = "opentripplanner/opentripplanner:2.6.0"
          args  = ["--build", "--save"]
          port {
            name           = "http"
            container_port = 8080
            protocol       = "TCP"
          }
          volume_mount {
            name       = "otp-data"
            mount_path = "/var/opentripplanner"
          }
          env {
            name  = "JAVA_TOOL_OPTIONS"
            value = "-Xmx3g"
          }
          resources {
            requests = {
              cpu    = "300m"
              memory = "2Gi"
            }
            limits = {
              memory = "2Gi"
            }
          }
        }
        volume {
          name = "otp-data"
          persistent_volume_claim {
            claim_name = module.nfs_otp_data_host.claim_name
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_service" "otp" {
  metadata {
    name      = "otp"
    namespace = kubernetes_namespace.osm-routing.metadata[0].name
    labels = {
      app = "otp"
    }
  }
  spec {
    selector = {
      app = "otp"
    }
    port {
      port        = 8080
      target_port = 8080
    }
  }
}
