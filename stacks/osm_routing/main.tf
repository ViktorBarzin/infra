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
      "limits.memory"   = "16Gi"
      pods              = "20"
      # NO "limits.cpu" — deliberately. A quota that includes limits.cpu makes
      # every pod in the namespace REQUIRED to set a CPU limit, but the
      # cluster-wide `strip-cpu-limits` ClusterPolicy removes limits.cpu from
      # every container at admission (CFS throttling hurts bursty workloads).
      # The two contradict, and the result is that NO pod can be created here at
      # all: the API server rejects with "must specify limits.cpu", the
      # job-controller retries forever, and no pod ever exists to show logs.
      # Found 2026-08-04 while reviving OSRM. The generated tier-4-aux template
      # (generate-resourcequota-by-tier) correctly omits it — this stack's
      # hand-written quota had drifted from it.
    }
  }
}

module "nfs_osrm_data_host" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "osm-routing-osrm-data-host"
  namespace          = kubernetes_namespace.osm-routing.metadata[0].name
  nfs_server         = "192.168.1.127"
  nfs_path           = "/srv/nfs/osm-routing/osrm"
  storage_class_name = "nfs-pve"
}

module "nfs_otp_data_host" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "osm-routing-otp-data-host"
  namespace          = kubernetes_namespace.osm-routing.metadata[0].name
  nfs_server         = "192.168.1.127"
  nfs_path           = "/srv/nfs/osm-routing/otp"
  storage_class_name = "nfs-pve"
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
    # Re-enabled 2026-08-04, once the graphs actually existed — both NFS PVCs
    # were empty, so these pods had nothing to load even before the OOM. Memory
    # raised from 256Mi (the namespace LimitRange default, and the likely cause
    # of the 2026-03-14 OOM) to 1Gi; observed peak during the graph build was
    # ~1.3GB for extract, and serving MLD needs far less.
    replicas = 1
    # Rolling, not Recreate (changed at the v26 cut-over): the new pod must load
    # its graph and pass readiness before the old one goes, so a bad image or a
    # graph that is not built yet costs no routing. NFS volume, no RWO conflict;
    # the surge pod briefly adds one 640Mi request.
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "1"
        max_unavailable = "0"
      }
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
          image   = local.osrm_image
          command = ["osrm-routed", "--algorithm", "MLD", "${local.osrm_graph_dir}/foot/greater-london-latest.osrm"]
          port {
            name           = "http"
            container_port = 5000
            protocol       = "TCP"
          }
          volume_mount {
            name       = "osrm-data"
            mount_path = "/data"
          }
          # osrm-routed opens the port only after the graph has loaded, so a
          # pod whose graph is missing or from another osrm version never
          # becomes ready and the rolling update keeps the old pod serving.
          readiness_probe {
            tcp_socket {
              port = 5000
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
          # requests 1Gi -> 640Mi on 2026-09-04 (bead code-hn6k). Measured
          # peak working set over 30 days is 391Mi, so the old request reserved
          # ~2.6x what this engine has ever used while the cluster could not
          # drain a node. 640Mi is 1.5x that peak.
          #
          # The LIMIT stays at 1Gi, which is a RAISE in effective burst room:
          # request and limit were equal before, so the process could never go
          # above 1Gi and now still cannot, but it is no longer reserving the
          # whole ceiling. Stateless routing server, holds no state, not on a
          # login path.
          resources {
            requests = {
              cpu    = "50m"
              memory = "640Mi"
            }
            limits = {
              memory = "1Gi"
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
      # The image is not ignored: this stack owns it. While it was ignored
      # (Keel era, before 2026-10), Keel rewrote the serving image to
      # v26.5.0-debug-amd64-debian, which cannot read a graph built by the pinned
      # builder — "File is incompatible with this version of OSRM: prepared with
      # OSRM 6.0.0 but this is v26.5.0". Build and serve MUST use one version.
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # LEGACY_TEMPLATE_ANNOTATIONS
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
    # Re-enabled 2026-08-04, once the graphs actually existed — both NFS PVCs
    # were empty, so these pods had nothing to load even before the OOM. Memory
    # raised from 256Mi (the namespace LimitRange default, and the likely cause
    # of the 2026-03-14 OOM) to 1Gi; observed peak during the graph build was
    # ~1.3GB for extract, and serving MLD needs far less.
    replicas = 1
    # Rolling, not Recreate (changed at the v26 cut-over): the new pod must load
    # its graph and pass readiness before the old one goes, so a bad image or a
    # graph that is not built yet costs no routing. NFS volume, no RWO conflict;
    # the surge pod briefly adds one 640Mi request.
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "1"
        max_unavailable = "0"
      }
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
          image   = local.osrm_image
          command = ["osrm-routed", "--algorithm", "MLD", "${local.osrm_graph_dir}/bicycle/greater-london-latest.osrm"]
          port {
            name           = "http"
            container_port = 5000
            protocol       = "TCP"
          }
          volume_mount {
            name       = "osrm-data"
            mount_path = "/data"
          }
          # osrm-routed opens the port only after the graph has loaded, so a
          # pod whose graph is missing or from another osrm version never
          # becomes ready and the rolling update keeps the old pod serving.
          readiness_probe {
            tcp_socket {
              port = 5000
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
          # requests 1Gi -> 640Mi on 2026-09-04 (bead code-hn6k). Measured
          # peak working set over 30 days is 401Mi, so the old request reserved
          # ~2.6x what this engine has ever used while the cluster could not
          # drain a node. 640Mi is 1.5x that peak.
          #
          # The LIMIT stays at 1Gi, which is a RAISE in effective burst room:
          # request and limit were equal before, so the process could never go
          # above 1Gi and now still cannot, but it is no longer reserving the
          # whole ceiling. Stateless routing server, holds no state, not on a
          # login path.
          resources {
            requests = {
              cpu    = "50m"
              memory = "640Mi"
            }
            limits = {
              memory = "1Gi"
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
      # The image is not ignored: this stack owns it. While it was ignored
      # (Keel era, before 2026-10), Keel rewrote the serving image to
      # v26.5.0-debug-amd64-debian, which cannot read a graph built by the pinned
      # builder — "File is incompatible with this version of OSRM: prepared with
      # OSRM 6.0.0 but this is v26.5.0". Build and serve MUST use one version.
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # LEGACY_TEMPLATE_ANNOTATIONS
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
    # Deliberately NOT revived (2026-08-04). Originally disabled for cluster
    # memory pressure after the 2026-03-14 OOM; OTP was the memory hog and the
    # only reason a GTFS pipeline was needed. Transit now comes from the free TfL
    # Journey Planner API on demand instead — see
    # realestate-crawler/docs/plans/2026-08-04-routing-backends-design.md
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
          image = "opentripplanner/opentripplanner:2.10.0"
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
      # The image is not ignored: this stack owns it. While it was ignored
      # (Keel era, before 2026-10), Keel rewrote the serving image to
      # v26.5.0-debug-amd64-debian, which cannot read a graph built by the pinned
      # builder — "File is incompatible with this version of OSRM: prepared with
      # OSRM 6.0.0 but this is v26.5.0". Build and serve MUST use one version.
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # LEGACY_TEMPLATE_ANNOTATIONS
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
# These build the Greater London graphs the deployments load, into
# local.osrm_build_graph_dir (/data/<osrm version>/<profile>). Graphs of earlier
# versions stay next to it: v26.4.0 in /data/v26.4.0 (served until 2026-10-15)
# and v6.0.0 in /data/foot and /data/bicycle. Nothing reads them now.
#
# Staging + swap: each profile builds into <profile>.new and is moved into place
# only once complete, so a refresh never corrupts a graph being served. The build
# is the memory-expensive phase and gets generous limits here; the serving pods
# stay small (see their own resources blocks).
#
# Design: realestate-crawler/docs/plans/2026-08-04-routing-backends-design.md
locals {
  # Build and serve normally use one image. osrm-routed refuses a graph prepared
  # by a different major.minor (util::FingerPrint::IsDataCompatible), so graphs
  # live in a directory named after the osrm version that built them. A version
  # bump therefore points the serving pods at a directory that is empty until
  # osrm-refresh has run with the new image: build first (move only
  # osrm_build_image, run the CronJob once), then move osrm_image to match. The
  # rolling update with a readiness probe keeps the old pod serving if a new one
  # cannot load its graph.
  #
  # From v26.6.5 osrm publishes Debian images with a suffix (-debian); the graph
  # directory is named after the bare version (v26.10.0), not the full tag.
  # v26.10.0 since 2026-10-15; the v26.4.0 graph stays in /data/v26.4.0 so
  # pointing osrm_image back at v26.4.0 restores the previous setup.
  osrm_image           = "ghcr.io/project-osrm/osrm-backend:v26.10.0-debian"
  osrm_build_image     = local.osrm_image
  osrm_graph_dir       = "/data/${regex("v[0-9]+\\.[0-9]+\\.[0-9]+", element(split(":", local.osrm_image), 1))}"
  osrm_build_graph_dir = "/data/${regex("v[0-9]+\\.[0-9]+\\.[0-9]+", element(split(":", local.osrm_build_image), 1))}"

  # Download step, in its own init container: the Debian osrm images ship
  # neither wget nor curl. curl follows Geofabrik's 307 from the -latest URL to
  # the dated file.
  osrm_download_image  = "docker.io/curlimages/curl:8.23.0"
  osrm_download_script = <<-EOT
    set -eu
    cd /data
    echo "downloading Greater London extract"
    rm -f greater-london-latest.osm.pbf.tmp
    # Retry with a wait. The 2026-10-01 run failed all three pod attempts within
    # 83 s on "wget: too many redirections" from Geofabrik (the -latest URL is a
    # 307 to a dated file); the same request worked on 2026-10-12, so this was
    # transient upstream, and the Job's own retries came too fast to outlast it.
    n=1
    until curl -fsSL --max-time 1800 -o greater-london-latest.osm.pbf.tmp \
      https://download.geofabrik.de/europe/united-kingdom/england/greater-london-latest.osm.pbf; do
      if [ "$n" -ge 6 ]; then echo "download failed $n times, giving up"; exit 1; fi
      echo "download attempt $n failed, retrying in 10 minutes"
      n=$((n + 1))
      rm -f greater-london-latest.osm.pbf.tmp
      sleep 600
    done
    mv greater-london-latest.osm.pbf.tmp greater-london-latest.osm.pbf
    ls -la greater-london-latest.osm.pbf
  EOT

  # Shared by every graph build (the monthly CronJob and on-demand Jobs made
  # from it). GRAPH_DIR comes from the container env (local.osrm_build_graph_dir).
  osrm_build_script = <<-EOT
    set -eu
    cd /data
    test -s greater-london-latest.osm.pbf
    mkdir -p "$GRAPH_DIR"
    for profile in foot bicycle; do
      out="$GRAPH_DIR/$profile"
      echo "=== building $profile into $out ==="
      rm -rf "$out.new"
      mkdir -p "$out.new"
      cp greater-london-latest.osm.pbf "$out.new/"
      osrm-extract -p "/opt/$profile.lua" "$out.new/greater-london-latest.osm.pbf"
      osrm-partition "$out.new/greater-london-latest.osrm"
      osrm-customize "$out.new/greater-london-latest.osrm"
      rm -f "$out.new/greater-london-latest.osm.pbf"
      rm -rf "$out.old"
      if [ -d "$out" ]; then mv "$out" "$out.old"; fi
      mv "$out.new" "$out"
      rm -rf "$out.old"
      echo "built $profile"
    done
    ls -la "$GRAPH_DIR/foot" "$GRAPH_DIR/bicycle"
  EOT
}

# The ONLY graph-build definition. A one-off Job resource lived here too, but it
# duplicated this script and a Job's spec is immutable once created — a bad first
# attempt could not be corrected by Terraform, it just sat there Failed.
#
# To build or rebuild on demand, instantiate this CronJob:
#   kubectl -n osm-routing create job osrm-bootstrap --from=cronjob/osrm-refresh
#   kubectl -n osm-routing logs -f -l job-name=osrm-bootstrap
#
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
            init_container {
              name    = "download"
              image   = local.osrm_download_image
              command = ["/bin/sh", "-c"]
              args    = [local.osrm_download_script]
              # The curl image runs as uid 100; the NFS directory belongs to
              # root, as the osrm image that downloaded before always ran.
              security_context {
                run_as_user = 0
              }
              volume_mount {
                name       = "osrm-data"
                mount_path = "/data"
              }
              resources {
                requests = {
                  cpu    = "50m"
                  memory = "64Mi"
                }
                limits = {
                  memory = "256Mi"
                }
              }
            }
            container {
              name    = "build"
              image   = local.osrm_build_image
              command = ["/bin/sh", "-c"]
              args    = [local.osrm_build_script]
              env {
                name  = "GRAPH_DIR"
                value = local.osrm_build_graph_dir
              }
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
                  # No cpu limit: strip-cpu-limits removes it cluster-wide anyway.
                  # 4Gi is the per-container ceiling from the tier-defaults LimitRange.
                  memory = "4Gi"
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
