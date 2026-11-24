# =============================================================================
# library — stremio-library.viktorbarzin.me, the "Our server" Stremio addon
# =============================================================================
# Plays films and episodes from our NFS share, and saves films and episodes to
# watch later (docs/plans/2026-11-23-stremio-saves-design.md; words as in
# GLOSSARY.md, "Saved films and episodes"). Added 2026-11-23 for Undercover
# season 6, which exists only as BULTOR WEB-DL releases that Real-Debrid
# refuses.
#
# files/library.py: the HTTP routes, file rows and byte ranges.
# files/saves.py: Save, Follow, the copies (Real-Debrid first, qBittorrent when
# it refuses or makes no progress for 2 hours), Watched and the cleanup.
#
# Files: qBittorrent category "stremio" saves to /downloads/stremio/<imdb id>/
# (NFS /srv/nfs/servarr/downloads/stremio, never backed up); this pod mounts
# that folder read-only and deletes copies through qBittorrent's API.
# Install URLs (token in Secret stremio/library):
#   viktor, shared account: https://stremio-library.viktorbarzin.me/<token>/a/viktor/manifest.json
#     (the older /<token>/manifest.json is the same account)
#   emo, emostremio@:       https://stremio-library-lan.viktorbarzin.me/<token>/a/emo/manifest.json

resource "random_id" "library_token" {
  byte_length = 24
}

resource "kubernetes_secret" "library" {
  metadata {
    name      = "library"
    namespace = kubernetes_namespace.stremio.metadata[0].name
  }
  data = {
    LIBRARY_TOKEN = random_id.library_token.hex
  }
}

# RD_API_KEY (Vault secret/stremio rd_api_key) for adding magnets and playing
# Real-Debrid copies; Viktor's AIOStreams login for the release search.
resource "kubernetes_manifest" "library_keys" {
  field_manager { force_conflicts = true }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "library-keys"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "vault-kv", kind = "ClusterSecretStore" }
      target          = { name = "library-keys" }
      data = [
        { secretKey = "RD_API_KEY", remoteRef = { key = "stremio", property = "rd_api_key" } },
        { secretKey = "AIOSTREAMS_UUID", remoteRef = { key = "viktor", property = "aiostreams_uuid" } },
        { secretKey = "AIOSTREAMS_PASSWORD", remoteRef = { key = "viktor", property = "aiostreams_password" } },
      ]
    }
  }
  depends_on = [kubernetes_namespace.stremio]
}

resource "kubernetes_config_map" "library" {
  metadata {
    name      = "library"
    namespace = kubernetes_namespace.stremio.metadata[0].name
  }
  data = {
    "library.py" = file("${path.module}/files/library.py")
    "saves.py"   = file("${path.module}/files/saves.py")
  }
}

# Six-second clips a tap plays while there is no video yet: "Saved",
# "Saving", "No copy found", "Save removed", "Season saved", in English
# (-en) and Bulgarian (-bg), 10-13 KB each. Rendered with ffmpeg:
#   ffmpeg -f lavfi -i color=c=0x141218:s=854x480:r=10:d=6 -f lavfi -i anullsrc=r=22050:cl=mono -t 6
#     -vf "drawtext=fontfile=DejaVuSans-Bold.ttf:textfile=<title>:fontsize=56:...,drawtext=...:fontsize=28"
#     -c:v libx264 -tune stillimage -crf 30 -pix_fmt yuv420p -c:a aac -b:a 16k -movflags +faststart <kind>-<lang>.mp4
resource "kubernetes_config_map" "library_clips" {
  metadata {
    name      = "library-clips"
    namespace = kubernetes_namespace.stremio.metadata[0].name
  }
  binary_data = { for f in fileset("${path.module}/files/clips", "*.mp4") : f => filebase64("${path.module}/files/clips/${f}") }
}

module "nfs_library" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "stremio-library-downloads"
  namespace          = kubernetes_namespace.stremio.metadata[0].name
  nfs_server         = "192.168.1.127"
  nfs_path           = "/srv/nfs/servarr/downloads"
  storage_class_name = "nfs-pve"
}

# The saves database (SQLite: never on NFS). No secrets in it; it holds which
# account saved and watched what.
resource "kubernetes_persistent_volume_claim" "library_data" {
  wait_until_bound = false
  metadata {
    name      = "stremio-library-data-proxmox"
    namespace = kubernetes_namespace.stremio.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = { storage = "1Gi" }
    }
  }
  lifecycle {
    # pvc-autoresizer grows it; do not shrink it back on apply.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_deployment" "library" {
  metadata {
    name      = "library"
    namespace = kubernetes_namespace.stremio.metadata[0].name
    labels    = { app = "stremio-library", tier = local.tiers.gpu }
  }
  spec {
    replicas = 1 # SQLite on a ReadWriteOnce volume: one writer
    strategy {
      type = "Recreate"
    }
    selector { match_labels = { app = "stremio-library" } }
    template {
      metadata {
        labels = { app = "stremio-library" }
        annotations = {
          "checksum/code" = sha256(join("", [file("${path.module}/files/library.py"), file("${path.module}/files/saves.py")]))
        }
      }
      spec {
        security_context {
          run_as_user     = 65534
          run_as_group    = 65534
          run_as_non_root = true
          fs_group        = 65534 # writes /data/saves.db
        }
        container {
          name    = "library"
          image   = "docker.io/library/python:3.15.2-alpine"
          command = ["python3", "-u", "/app/library.py"]
          env {
            name  = "LIBRARY_DIR"
            value = "/media"
          }
          env {
            name  = "PUBLIC_URL"
            value = "https://stremio-library.viktorbarzin.me"
          }
          env {
            # emo's rows: his TV on the Sofia LAN has no hairpin NAT to our
            # public address (module.library_lan_ingress).
            name  = "PUBLIC_URL_EMO"
            value = "https://stremio-library-lan.viktorbarzin.me"
          }
          env {
            name  = "DATA_DIR"
            value = "/data"
          }
          env {
            name  = "CLIPS_DIR"
            value = "/clips"
          }
          env {
            name  = "AIOSTREAMS_BASE"
            value = "http://aiostreams.aiostreams.svc.cluster.local"
          }
          env {
            # emo's saves search this variant of Viktor's AIOStreams config,
            # which puts Bulgarian audio first; Viktor's use the base config.
            name  = "AIOSTREAMS_VARIANT_EMO"
            value = "sofia"
          }
          env {
            name  = "QBITTORRENT_URL"
            value = "http://qbittorrent.servarr.svc.cluster.local/api/v2"
          }
          env {
            name  = "CINEMETA_BASE"
            value = "http://cinemeta-proxy.stremio.svc.cluster.local"
          }
          env {
            # One-time follows, each applied once (table seeds): Viktor follows
            # Undercover season 6 from episode 1, so E1-E7, already on the
            # share, become his saves and E8-E12 are fetched as they air.
            name  = "SEED_FOLLOWS"
            value = "viktor:tt1909015:6:1"
          }
          env {
            name = "LIBRARY_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.library.metadata[0].name
                key  = "LIBRARY_TOKEN"
              }
            }
          }
          env_from {
            # RD_API_KEY, AIOSTREAMS_UUID, AIOSTREAMS_PASSWORD
            secret_ref { name = "library-keys" }
          }
          port {
            container_port = 8080
            name           = "http"
          }
          volume_mount {
            name       = "code"
            mount_path = "/app"
            read_only  = true
          }
          volume_mount {
            name       = "clips"
            mount_path = "/clips"
            read_only  = true
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "downloads"
            mount_path = "/media"
            sub_path   = "stremio"
            read_only  = true
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds = 10
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }
          resources {
            # Python stdlib server; each stream (a file, or a Real-Debrid copy
            # proxied through Sofia) is a thread copying 1 MiB chunks, plus the
            # saves worker.
            requests = {
              cpu    = "20m"
              memory = "64Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
        volume {
          name = "code"
          config_map {
            name = kubernetes_config_map.library.metadata[0].name
          }
        }
        volume {
          name = "clips"
          config_map {
            name = kubernetes_config_map.library_clips.metadata[0].name
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.library_data.metadata[0].name
          }
        }
        volume {
          name = "downloads"
          persistent_volume_claim {
            claim_name = module.nfs_library.claim_name
            read_only  = true
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
    ]
  }
  depends_on = [kubernetes_manifest.library_keys]
}

resource "kubernetes_service" "library" {
  metadata {
    name      = "library"
    namespace = kubernetes_namespace.stremio.metadata[0].name
    labels    = { app = "stremio-library" }
  }
  spec {
    selector = { app = "stremio-library" }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

module "library_ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": the random token in every path is the gate (files/library.py
  # answers 404 without it), as for AIOStreams' install URLs. Stremio players
  # fetch the manifest, rows and video directly and cannot follow Authentik.
  auth             = "none"
  anti_ai_scraping = false # an addon API and video files; no pages to protect
  # Non-proxied: Cloudflare's terms bar serving video through its CDN (as for
  # stremio.viktorbarzin.me).
  dns_type        = "non-proxied"
  namespace       = kubernetes_namespace.stremio.metadata[0].name
  name            = "stremio-library"
  homepage_group  = "Media & Entertainment"
  service_name    = kubernetes_service.library.metadata[0].name
  tls_secret_name = var.tls_secret_name
  # No Turnstile gate: Stremio addon API, machine-only (docs/plans/2026-10-16-turnstile-sitewide-design.md).
  turnstile = false
  extra_annotations = {
    "gethomepage.dev/description" = "Stremio addon: saves films and episodes, plays files on our server"
  }
}

# The same addon on the internal Traefik address, for emo's TV on the Sofia
# LAN, which has no hairpin NAT to our public IP. The internal record is
# reachability; the home-LANs allowlist is the network gate.
module "library_lan_ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": the random token in every path is the gate, as on
  # module.library_ingress; Stremio players cannot follow Authentik.
  auth              = "none"
  anti_ai_scraping  = false # an addon API and video files
  dns_type          = "internal"
  extra_middlewares = ["traefik-home-lans-only@kubernetescrd"]
  namespace         = kubernetes_namespace.stremio.metadata[0].name
  name              = "stremio-library-lan"
  service_name      = kubernetes_service.library.metadata[0].name
  tls_secret_name   = var.tls_secret_name
  homepage_enabled  = false
  # No Turnstile gate: Stremio addon API, machine-only.
  turnstile = false
}

# Nightly copy of the saves database to NFS /srv/nfs/stremio-library-backup/
# (docs/agents/storage-backup.md: every proxmox-lvm app has one). nfs-mirror
# and the offsite sync carry it on; lvm-pvc-snapshot also snapshots the volume.
module "nfs_library_backup" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "stremio-library-backup"
  namespace          = kubernetes_namespace.stremio.metadata[0].name
  nfs_server         = "192.168.1.127"
  nfs_path           = "/srv/nfs/stremio-library-backup"
  storage_class_name = "nfs-pve"
}

resource "kubernetes_cron_job_v1" "library_backup" {
  metadata {
    name      = "stremio-library-backup"
    namespace = kubernetes_namespace.stremio.metadata[0].name
    # Run by the Proxmox host's nightly-chain (scripts/nightly-chain.sh), not by
    # this schedule.
    annotations = {
      "backup.viktorbarzin.me/nightly-chain" = "daily"
    }
  }
  spec {
    concurrency_policy        = "Replace"
    failed_jobs_history_limit = 3
    schedule                  = "30 3 * * *"
    # Suspended: nightly-chain starts it with `kubectl create job --from=cronjob/...`.
    suspend                       = true
    starting_deadline_seconds     = 10
    successful_jobs_history_limit = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 3
        ttl_seconds_after_finished = 10
        template {
          metadata {}
          spec {
            affinity {
              # The volume is ReadWriteOnce: run beside the library pod.
              pod_affinity {
                required_during_scheduling_ignored_during_execution {
                  label_selector {
                    match_labels = { app = "stremio-library" }
                  }
                  topology_key = "kubernetes.io/hostname"
                }
              }
            }
            container {
              name  = "backup"
              image = "docker.io/library/python:3.15.2-alpine"
              # sqlite3's online backup, so a save written meanwhile is safe;
              # 30 days kept.
              command = ["python3", "-c", <<-EOT
                import glob, os, sqlite3, time
                out = time.strftime("/backup/saves-%Y%m%d-%H%M.db")
                src = sqlite3.connect("file:/data/saves.db?mode=ro", uri=True)
                dst = sqlite3.connect(out)
                src.backup(dst)
                dst.close()
                src.close()
                for old in glob.glob("/backup/saves-*.db"):
                    if os.path.getmtime(old) < time.time() - 30 * 86400:
                        os.remove(old)
                print("backup", out, os.path.getsize(out), "bytes")
              EOT
              ]
              volume_mount {
                name       = "data"
                mount_path = "/data"
                read_only  = true
              }
              volume_mount {
                name       = "backup"
                mount_path = "/backup"
              }
              resources {
                requests = {
                  memory = "32Mi"
                  cpu    = "10m"
                }
                limits = {
                  memory = "64Mi"
                }
              }
            }
            volume {
              name = "data"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.library_data.metadata[0].name
              }
            }
            volume {
              name = "backup"
              persistent_volume_claim {
                claim_name = module.nfs_library_backup.claim_name
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}
