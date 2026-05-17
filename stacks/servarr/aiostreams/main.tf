variable "tls_secret_name" {}
variable "tier" { type = string }
variable "aiostreams_database_connection_string" { type = string }
variable "nfs_server" { type = string }

resource "kubernetes_namespace" "aiostreams" {
  metadata {
    name = "aiostreams"
    labels = {
      "istio-injection" : "disabled"
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "random_id" "secret_key" {
  byte_length = 32 # 32 bytes × 2 hex chars = 64 hex characters
}

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "aiostreams-data-proxmox"
    namespace = kubernetes_namespace.aiostreams.metadata[0].name
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
      requests = {
        storage = "1Gi"
      }
    }
  }
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and
    # PVCs can't shrink. Without this, every TF apply tries to revert
    # to the spec value, K8s rejects the shrink, and the PVC ends up
    # in Terminating-but-in-use limbo.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_deployment" "aiostreams" {
  metadata {
    name      = "aiostreams"
    namespace = kubernetes_namespace.aiostreams.metadata[0].name
    labels = {
      app  = "aiostreams"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "aiostreams"
      }
    }
    template {
      metadata {
        labels = {
          app = "aiostreams"
        }
      }
      spec {
        container {
          image = "viren070/aiostreams:2026.05.14.1326-nightly"
          name  = "aiostreams"
          port {
            container_port = 3000
          }
          env {
            name  = "BASE_URL"
            value = "https://aiostreams.viktorbarzin.me"
          }
          env {
            name  = "SECRET_KEY"
            value = random_id.secret_key.hex
          }
          env {
            name  = "DATABASE_URI"
            value = var.aiostreams_database_connection_string
          }
          env {
            # Cache stream-response payloads for 1h. Default is -1 (disabled),
            # which made every Stremio request hit all 5 upstream addons live —
            # slow, and contributed to the perceived empty-list issue when an
            # upstream was slow/erroring. 1h is short enough that RD cache
            # invalidations are picked up quickly.
            name  = "STREAM_CACHE_TTL"
            value = "3600"
          }
          env {
            # Whitelisted regex sync URLs. Vidhin's regexes.json contains release-group
            # patterns (TRaSH Guides-aligned).
            name  = "WHITELISTED_REGEX_PATTERNS_URLS"
            value = jsonencode([
              "https://raw.githubusercontent.com/Vidhin05/Releases-Regex/main/English/regexes.json",
            ])
          }
          env {
            # Whitelisted SEL (Stream Expression Language) sync URLs. Stream-expression
            # files (Vidhin's ranked expressions + Tamtaro's ISE/PSE/ESE) go here, NOT
            # in WHITELISTED_REGEX_PATTERNS_URLS — AIOStreams validates each field
            # against the correct whitelist.
            name  = "WHITELISTED_SEL_URLS"
            value = jsonencode([
              "https://raw.githubusercontent.com/Vidhin05/Releases-Regex/main/English/expressions.json",
              "https://raw.githubusercontent.com/Tam-Taro/SEL-Filtering-and-Sorting/main/AIOStreams-SyncedURLs/Tamtaro-synced-ISEs.json",
              "https://raw.githubusercontent.com/Tam-Taro/SEL-Filtering-and-Sorting/main/AIOStreams-SyncedURLs/Tamtaro-synced-PSEs.json",
              "https://raw.githubusercontent.com/Tam-Taro/SEL-Filtering-and-Sorting/main/AIOStreams-SyncedURLs/Tamtaro-synced-ESEs-standard.json",
            ])
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }
          resources {
            requests = {
              cpu    = "25m"
              memory = "768Mi"
            }
            limits = {
              memory = "768Mi"
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_proxmox.metadata[0].name
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

resource "kubernetes_service" "aiostreams" {
  metadata {
    name      = "aiostreams"
    namespace = kubernetes_namespace.aiostreams.metadata[0].name
    labels = {
      "app" = "aiostreams"
    }
  }

  spec {
    selector = {
      app = "aiostreams"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3000
    }
  }
}

resource "kubernetes_manifest" "probe_secrets" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "aiostreams-probe-secrets"
      namespace = kubernetes_namespace.aiostreams.metadata[0].name
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = { name = "aiostreams-probe-secrets" }
      data = [
        { secretKey = "AIOSTREAMS_UUID", remoteRef = { key = "viktor", property = "aiostreams_uuid" } },
        { secretKey = "AIOSTREAMS_PASSWORD", remoteRef = { key = "viktor", property = "aiostreams_password" } },
        { secretKey = "STREMIO_EMAIL", remoteRef = { key = "viktor", property = "stremio_email" } },
        { secretKey = "STREMIO_PASSWORD", remoteRef = { key = "viktor", property = "stremio_password" } },
      ]
    }
  }
  depends_on = [kubernetes_namespace.aiostreams]
}

resource "kubernetes_cron_job_v1" "stream_probe" {
  metadata {
    name      = "aiostreams-stream-probe"
    namespace = kubernetes_namespace.aiostreams.metadata[0].name
  }
  spec {
    schedule                      = "*/5 * * * *"
    concurrency_policy            = "Replace"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 300
        template {
          metadata {}
          spec {
            restart_policy = "Never"
            container {
              name    = "probe"
              image   = "docker.io/library/python:3.12-alpine"
              command = ["/bin/sh", "-c", <<-EOT
                pip install --quiet --disable-pip-version-check requests && python3 -c '
import requests, os, time, urllib.parse, sys

BASE = "http://aiostreams.aiostreams.svc.cluster.local"
PUSHGATEWAY = "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/aiostreams-stream-probe"
UUID = os.environ["AIOSTREAMS_UUID"]
PW = os.environ["AIOSTREAMS_PASSWORD"]
TEST_ID = "tt0903747:1:1"  # Breaking Bad S01E01 - stable, always has many streams
THRESHOLD = 50

count = 0
success = 0
duration = 0
start = time.time()

try:
    r = requests.get(f"{BASE}/api/v1/user/", params={"uuid": UUID, "password": PW}, timeout=10)
    r.raise_for_status()
    enc = r.json()["data"]["encryptedPassword"]
    enc_url = urllib.parse.quote(enc, safe="")
    r2 = requests.get(
        f"{BASE}/stremio/{UUID}/{enc_url}/stream/series/{TEST_ID}.json",
        headers={"User-Agent": "AIOStreams/probe"}, timeout=60,
    )
    r2.raise_for_status()
    count = len(r2.json().get("streams", []))
    success = 1 if count >= THRESHOLD else 0
    print(f"streams={count} success={success}")
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    success = 0

duration = time.time() - start

body = (
    "# TYPE aiostreams_stream_count gauge\n"
    f"aiostreams_stream_count {count}\n"
    "# TYPE aiostreams_probe_success gauge\n"
    f"aiostreams_probe_success {success}\n"
    "# TYPE aiostreams_probe_duration_seconds gauge\n"
    f"aiostreams_probe_duration_seconds {duration:.3f}\n"
    "# TYPE aiostreams_probe_last_run_timestamp gauge\n"
    f"aiostreams_probe_last_run_timestamp {int(time.time())}\n"
)
try:
    requests.post(PUSHGATEWAY, data=body, timeout=10).raise_for_status()
except Exception as e:
    print(f"WARN: pushgateway POST failed: {e}", file=sys.stderr)

sys.exit(0 if success else 1)
'
              EOT
              ]
              env_from {
                secret_ref { name = "aiostreams-probe-secrets" }
              }
              resources {
                requests = { memory = "64Mi", cpu = "10m" }
                limits   = { memory = "128Mi" }
              }
            }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_manifest.probe_secrets, kubernetes_deployment.aiostreams]
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}

module "nfs_backup" {
  source     = "../../../modules/kubernetes/nfs_volume"
  name       = "aiostreams-backup"
  namespace  = kubernetes_namespace.aiostreams.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/srv/nfs/aiostreams-backup"
  storage    = "1Gi"
}

resource "kubernetes_cron_job_v1" "config_backup" {
  metadata {
    name      = "aiostreams-config-backup"
    namespace = kubernetes_namespace.aiostreams.metadata[0].name
  }
  spec {
    schedule                      = "0 3 * * 0" # Sunday 03:00 weekly
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 600
        template {
          metadata {}
          spec {
            restart_policy = "Never"
            container {
              name    = "backup"
              image   = "docker.io/library/python:3.12-alpine"
              command = ["/bin/sh", "-c", <<-EOT
                pip install --quiet --disable-pip-version-check requests && python3 -c '
import requests, os, time, json, sys, datetime, glob

BASE = "http://aiostreams.aiostreams.svc.cluster.local"
PUSHGATEWAY = "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/aiostreams-config-backup"
UUID = os.environ["AIOSTREAMS_UUID"]
PW = os.environ["AIOSTREAMS_PASSWORD"]
BACKUP_DIR = "/backup"
RETENTION_DAYS = 90

success = 0
bytes_written = 0
start = time.time()

try:
    r = requests.get(f"{BASE}/api/v1/user/", params={"uuid": UUID, "password": PW, "raw": "true"}, timeout=30)
    r.raise_for_status()
    data = r.json()["data"]["userData"]
    if not data:
        raise RuntimeError("empty userData from API")

    os.makedirs(BACKUP_DIR, exist_ok=True)
    ts = datetime.datetime.utcnow().strftime("%Y-%m-%d_%H%M")
    path = f"{BACKUP_DIR}/config-{ts}.json"
    with open(path, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
    bytes_written = os.path.getsize(path)
    os.chmod(path, 0o600)
    print(f"OK wrote {path} ({bytes_written} bytes)")

    # Prune backups older than RETENTION_DAYS
    cutoff = time.time() - (RETENTION_DAYS * 86400)
    pruned = 0
    for f in glob.glob(f"{BACKUP_DIR}/config-*.json"):
        if os.path.getmtime(f) < cutoff:
            os.unlink(f)
            pruned += 1
    if pruned:
        print(f"Pruned {pruned} old backups")
    success = 1
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)

duration = time.time() - start
body = (
    "# TYPE aiostreams_config_backup_success gauge\n"
    f"aiostreams_config_backup_success {success}\n"
    "# TYPE aiostreams_config_backup_bytes gauge\n"
    f"aiostreams_config_backup_bytes {bytes_written}\n"
    "# TYPE aiostreams_config_backup_duration_seconds gauge\n"
    f"aiostreams_config_backup_duration_seconds {duration:.3f}\n"
    "# TYPE aiostreams_config_backup_last_run_timestamp gauge\n"
    f"aiostreams_config_backup_last_run_timestamp {int(time.time())}\n"
)
try:
    requests.post(PUSHGATEWAY, data=body, timeout=10).raise_for_status()
except Exception as e:
    print(f"WARN: pushgateway POST failed: {e}", file=sys.stderr)

sys.exit(0 if success else 1)
'
              EOT
              ]
              env_from {
                secret_ref { name = "aiostreams-probe-secrets" }
              }
              volume_mount {
                name       = "backup"
                mount_path = "/backup"
              }
              resources {
                requests = { memory = "64Mi", cpu = "10m" }
                limits   = { memory = "128Mi" }
              }
            }
            volume {
              name = "backup"
              persistent_volume_claim {
                claim_name = module.nfs_backup.claim_name
              }
            }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_manifest.probe_secrets, kubernetes_deployment.aiostreams, module.nfs_backup]
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_cron_job_v1" "stremio_account_backup" {
  metadata {
    name      = "stremio-account-backup"
    namespace = kubernetes_namespace.aiostreams.metadata[0].name
  }
  spec {
    schedule                      = "0 4 * * 0" # Sunday 04:00 weekly (1h after config-backup)
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 600
        template {
          metadata {}
          spec {
            restart_policy = "Never"
            container {
              name    = "backup"
              image   = "docker.io/library/python:3.12-alpine"
              command = ["/bin/sh", "-c", <<-EOT
                pip install --quiet --disable-pip-version-check requests && python3 -c '
import requests, os, time, json, sys, datetime, glob

BASE = "https://api.strem.io/api"
PUSHGATEWAY = "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/stremio-account-backup"
EMAIL = os.environ["STREMIO_EMAIL"]
PASSWORD = os.environ["STREMIO_PASSWORD"]
BACKUP_DIR = "/backup"
RETENTION_DAYS = 90

success = 0
bytes_written = 0
addon_count = 0
start = time.time()

try:
    r = requests.post(f"{BASE}/login", json={"type":"Login","email":EMAIL,"password":PASSWORD}, timeout=20)
    r.raise_for_status()
    auth = r.json()["result"]["authKey"]

    r2 = requests.post(f"{BASE}/addonCollectionGet", json={"type":"AddonCollectionGet","authKey":auth,"update":True}, timeout=30)
    r2.raise_for_status()
    addons = r2.json()["result"]["addons"]
    addon_count = len(addons)

    os.makedirs(BACKUP_DIR, exist_ok=True)
    ts = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d_%H%M")
    path = f"{BACKUP_DIR}/stremio-collection-{ts}.json"
    payload = {"capturedAt": ts, "email": EMAIL, "addonCount": addon_count, "addons": addons}
    with open(path, "w") as f:
        json.dump(payload, f, indent=2, sort_keys=True)
    bytes_written = os.path.getsize(path)
    os.chmod(path, 0o600)
    print(f"OK wrote {path} ({bytes_written} bytes, {addon_count} addons)")

    # Logout to invalidate the auth key
    try:
        requests.post(f"{BASE}/logout", json={"type":"Logout","authKey":auth}, timeout=10)
    except Exception:
        pass

    # Prune older than RETENTION_DAYS
    cutoff = time.time() - (RETENTION_DAYS * 86400)
    pruned = 0
    for f in glob.glob(f"{BACKUP_DIR}/stremio-collection-*.json"):
        if os.path.getmtime(f) < cutoff:
            os.unlink(f); pruned += 1
    if pruned: print(f"Pruned {pruned} old backups")
    success = 1
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)

duration = time.time() - start
body = (
    "# TYPE stremio_account_backup_success gauge\n"
    f"stremio_account_backup_success {success}\n"
    "# TYPE stremio_account_backup_bytes gauge\n"
    f"stremio_account_backup_bytes {bytes_written}\n"
    "# TYPE stremio_account_backup_addon_count gauge\n"
    f"stremio_account_backup_addon_count {addon_count}\n"
    "# TYPE stremio_account_backup_duration_seconds gauge\n"
    f"stremio_account_backup_duration_seconds {duration:.3f}\n"
    "# TYPE stremio_account_backup_last_run_timestamp gauge\n"
    f"stremio_account_backup_last_run_timestamp {int(time.time())}\n"
)
try:
    requests.post(PUSHGATEWAY, data=body, timeout=10).raise_for_status()
except Exception as e:
    print(f"WARN: pushgateway POST failed: {e}", file=sys.stderr)

sys.exit(0 if success else 1)
'
              EOT
              ]
              env_from {
                secret_ref { name = "aiostreams-probe-secrets" }
              }
              volume_mount {
                name       = "backup"
                mount_path = "/backup"
              }
              resources {
                requests = { memory = "64Mi", cpu = "10m" }
                limits   = { memory = "128Mi" }
              }
            }
            volume {
              name = "backup"
              persistent_volume_claim {
                claim_name = module.nfs_backup.claim_name
              }
            }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_manifest.probe_secrets, module.nfs_backup]
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}

module "ingress" {
  source = "../../../modules/kubernetes/ingress_factory"
  # auth = "app": AIOStreams enforces its own UUID + password gate on /configure
  # and /api/*, and Stremio addon URLs (/stremio/{uuid}/{encryptedPassword}/...)
  # use the encryptedPassword path segment as a bearer token. Authentik forward-auth
  # broke Stremio clients (cannot follow OAuth 302) and is redundant with the app's
  # own auth. UUIDs are 128-bit random; password attempts are rate-limited.
  auth            = "app"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.aiostreams.metadata[0].name
  name            = "aiostreams"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "AIOStreams"
    "gethomepage.dev/description"  = "Streaming addon manager"
    "gethomepage.dev/icon"         = "stremio.png"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
  }
}
