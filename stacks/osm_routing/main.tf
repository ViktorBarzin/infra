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
      "keel.sh/enrolled"                 = "true"
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
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
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
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
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
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
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

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00

# CI retrigger v3 2026-05-16T14:06:39Z

# CI retrigger v4 2026-05-16T14:13:59Z

# CI retrigger v5 2026-05-16T23:10:38Z

# CI retrigger v6 2026-05-16T23:18:58Z

# =============================================================================
# OSRM graph build + monthly refresh (added 2026-08-04)
# =============================================================================
# Both NFS PVCs were EMPTY (4.0K, untouched since 2026-04-12), so osrm-routed had
# no graph to load — the serving pods could not have worked even at replicas>0.
# These build the Greater London graphs the deployments' commands already expect
# at /data/foot and /data/bicycle.
#
# Staging + swap: each profile builds into <profile>.new and is moved into place
# only once complete, so a refresh never corrupts a graph being served. The build
# is the memory-expensive phase and gets generous limits here; the serving pods
# stay small (see their own resources blocks).
#
# Design: realestate-crawler/docs/plans/2026-08-04-routing-backends-design.md
locals {
  osrm_image = "ghcr.io/project-osrm/osrm-backend:v6.0.0"

  # Shared by the one-off Job and the monthly CronJob so the two can never drift.
  osrm_build_script = <<-EOT
    set -euo pipefail
    cd /data
    echo "downloading Greater London extract"
    curl -sSLo greater-london-latest.osm.pbf.tmp \
      https://download.geofabrik.de/europe/united-kingdom/england/greater-london-latest.osm.pbf
    mv greater-london-latest.osm.pbf.tmp greater-london-latest.osm.pbf
    for profile in foot bicycle; do
      echo "=== building $profile ==="
      rm -rf "$profile.new"
      mkdir -p "$profile.new"
      cp greater-london-latest.osm.pbf "$profile.new/"
      osrm-extract -p "/opt/$profile.lua" "$profile.new/greater-london-latest.osm.pbf"
      osrm-partition "$profile.new/greater-london-latest.osrm"
      osrm-customize "$profile.new/greater-london-latest.osrm"
      rm -f "$profile.new/greater-london-latest.osm.pbf"
      rm -rf "$profile.old"
      if [ -d "$profile" ]; then mv "$profile" "$profile.old"; fi
      mv "$profile.new" "$profile"
      rm -rf "$profile.old"
      echo "built $profile"
    done
    ls -la /data/foot /data/bicycle
  EOT
}

resource "kubernetes_job" "osrm_build" {
  metadata {
    name      = "osrm-build"
    namespace = kubernetes_namespace.osm-routing.metadata[0].name
    labels    = { app = "osrm-build" }
  }
  spec {
    backoff_limit = 2
    template {
      metadata { labels = { app = "osrm-build" } }
      spec {
        restart_policy = "Never"
        container {
          name    = "build"
          image   = local.osrm_image
          command = ["/bin/bash", "-lc"]
          args    = [local.osrm_build_script]
          volume_mount {
            name       = "osrm-data"
            mount_path = "/data"
          }
          resources {
            requests = {
              cpu    = "500m"
              memory = "2Gi"
            }
            limits = {
              cpu    = "3"
              memory = "6Gi"
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
  wait_for_completion = false
  timeouts {
    create = "60m"
  }
}

# Monthly rebuild so the graphs cannot rot the way they just did. OSM geometry
# changes slowly and there are no timetables to chase (OTP is deliberately not
# revived — transit comes from the free TfL API on demand), so monthly is ample.
# NOTE: osrm-routed loads its graph at startup, so a refreshed graph is only
# picked up when the serving pods restart.
resource "kubernetes_cron_job_v1" "osrm_refresh" {
  metadata {
    name      = "osrm-refresh"
    namespace = kubernetes_namespace.osm-routing.metadata[0].name
    labels    = { app = "osrm-refresh" }
  }
  spec {
    schedule                      = "0 4 1 * *" # 04:00 UTC on the 1st
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 2
    job_template {
      metadata { labels = { app = "osrm-refresh" } }
      spec {
        backoff_limit = 2
        template {
          metadata { labels = { app = "osrm-refresh" } }
          spec {
            restart_policy = "Never"
            container {
              name    = "build"
              image   = local.osrm_image
              command = ["/bin/bash", "-lc"]
              args    = [local.osrm_build_script]
              volume_mount {
                name       = "osrm-data"
                mount_path = "/data"
              }
              resources {
                requests = {
                  cpu    = "500m"
                  memory = "2Gi"
                }
                limits = {
                  cpu    = "3"
                  memory = "6Gi"
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
    }
  }
}
