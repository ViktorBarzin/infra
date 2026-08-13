variable "namespace" {
  type    = string
  default = "servarr"
}

locals {
  python_image = "docker.io/library/python:3.12-alpine"
  pip_prefix   = "pip install -q requests > /dev/null 2>&1; python3 /tmp/script.py"

  # Dry-run window was satisfied by a one-shot test on 2026-04-19 that
  # produced 466 `never_started` candidates and 0 matches in any other
  # reason bucket — consistent with Phase B's expected 495 stuck torrents.
  # Enforcing from here on.
  janitor_dry_run = "0"
}

# ----------------------------- NFS data volume -----------------------
# Migrated off proxmox-lvm (2026-06-04): the cookie + grabbed-ID dedup list
# are two plain-text files (no embedded DB), so NFS is safe and removes this
# volume from the per-VM SCSI-LUN hotplug path entirely — a stuck `query-pci`
# on a disk-heavy node VM used to wedge the grabber in ContainerCreating (the
# disk never enumerated, Forbid blocked every run → MAMFarmingStuck). NFS
# mounts over the network, consumes zero LUN slots, and is RWX so the grabber
# and bp-spender can co-schedule on any node. See docs/architecture/storage.md
# "Per-VM SCSI-LUN cap" lever #1.
module "mam_data_nfs" {
  source     = "../../../modules/kubernetes/nfs_volume"
  name       = "servarr-mam-farming-data"
  namespace  = var.namespace
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/servarr/mam-farming"
  storage    = "1Gi"
}

# --------------------------- Grabber ---------------------------------
# Every 30 minutes: skip while ratio < 1.2 or class == Mouse; otherwise
# grab up to 5 small-but-popular freeleech torrents. Existing ConfigMap
# + CronJob are adopted via imports in the parent stack.

resource "kubernetes_config_map" "grabber_script" {
  metadata {
    name      = "mam-freeleech-grabber-script"
    namespace = var.namespace
  }
  data = {
    "script.py" = file("${path.module}/files/freeleech-grabber.py")
  }
}

resource "kubernetes_cron_job_v1" "grabber" {
  metadata {
    name      = "mam-freeleech-grabber"
    namespace = var.namespace
  }
  spec {
    schedule                      = "*/30 * * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 300
        template {
          metadata {}
          spec {
            restart_policy = "Never"
            container {
              name    = "freeleech-grabber"
              image   = local.python_image
              command = ["/bin/sh", "-c", local.pip_prefix]
              env {
                name = "MAM_ID"
                value_from {
                  secret_key_ref {
                    name = "servarr-secrets"
                    key  = "mam_id"
                  }
                }
              }
              resources {
                requests = { memory = "64Mi", cpu = "10m" }
                limits   = { memory = "128Mi" }
              }
              volume_mount {
                name       = "script"
                mount_path = "/tmp/script.py"
                sub_path   = "script.py"
              }
              volume_mount {
                name       = "data"
                mount_path = "/data"
              }
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map.grabber_script.metadata[0].name
              }
            }
            volume {
              name = "data"
              persistent_volume_claim {
                claim_name = module.mam_data_nfs.claim_name
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

# --------------------------- BP Spender ------------------------------
# Every 6 hours: compute the upload deficit against TARGET_RATIO and buy
# exactly what we need (+1 GiB margin), capped by BP reserve. Existing
# ConfigMap + CronJob are adopted via imports in the parent stack.

resource "kubernetes_config_map" "bp_spender_script" {
  metadata {
    name      = "mam-bp-spender-script"
    namespace = var.namespace
  }
  data = {
    "script.py" = file("${path.module}/files/bp-spender.py")
  }
}

resource "kubernetes_cron_job_v1" "bp_spender" {
  metadata {
    name      = "mam-bp-spender"
    namespace = var.namespace
  }
  spec {
    # Offset from the top of the hour so this never runs at the same minute as
    # mam-freeleech-grabber (*/30, i.e. :00 and :30). Both mount the SAME PVC
    # (servarr-mam-farming-data) and both read *and rewrite* /data/mam_id, and
    # MAM rotates that session cookie on every request -- which is why
    # save_cookie() exists. Two jobs presenting the same pre-rotation cookie
    # concurrently means one of them sends a value MAM has already retired.
    # At "0 */6" they collided at 00:00/06:00/12:00/18:00, four times a day.
    #
    # Scope note: this removes a real concurrent-use race on a rotating
    # credential. It is NOT established that the race caused the 2026-08-13
    # expiry -- the session may simply have aged out -- so treat this as
    # hygiene, not a proven fix. If mam_farming_cookie_expired keeps returning
    # after the cookie is refreshed, the next thing to check is whether the two
    # jobs should share one cookie at all rather than hold separate sessions.
    schedule                      = "15 */6 * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 300
        template {
          metadata {}
          spec {
            restart_policy = "Never"
            container {
              name    = "bp-spender"
              image   = local.python_image
              command = ["/bin/sh", "-c", local.pip_prefix]
              env {
                name = "MAM_ID"
                value_from {
                  secret_key_ref {
                    name = "servarr-secrets"
                    key  = "mam_id"
                  }
                }
              }
              resources {
                requests = { memory = "64Mi", cpu = "10m" }
                limits   = { memory = "128Mi" }
              }
              volume_mount {
                name       = "script"
                mount_path = "/tmp/script.py"
                sub_path   = "script.py"
              }
              volume_mount {
                name       = "data"
                mount_path = "/data"
              }
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map.bp_spender_script.metadata[0].name
              }
            }
            volume {
              name = "data"
              persistent_volume_claim {
                claim_name = module.mam_data_nfs.claim_name
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

# ----------------------------- Janitor -------------------------------
# New: every 15 minutes, independent of grabber ratio guard. Deletes
# stuck/unregistered/redundant torrents in category=mam-farming while
# preserving torrents beyond the 72h H&R window with a tracker margin.

resource "kubernetes_config_map" "janitor_script" {
  metadata {
    name      = "mam-farming-janitor-script"
    namespace = var.namespace
  }
  data = {
    "script.py" = file("${path.module}/files/mam-farming-janitor.py")
  }
}

resource "kubernetes_cron_job_v1" "janitor" {
  metadata {
    name      = "mam-farming-janitor"
    namespace = var.namespace
  }
  spec {
    schedule                      = "*/15 * * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 300
        template {
          metadata {}
          spec {
            restart_policy = "Never"
            container {
              name    = "farming-janitor"
              image   = local.python_image
              command = ["/bin/sh", "-c", local.pip_prefix]
              env {
                name  = "DRY_RUN"
                value = local.janitor_dry_run
              }
              resources {
                requests = { memory = "64Mi", cpu = "10m" }
                limits   = { memory = "128Mi" }
              }
              volume_mount {
                name       = "script"
                mount_path = "/tmp/script.py"
                sub_path   = "script.py"
              }
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map.janitor_script.metadata[0].name
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
