variable "tls_secret_name" {}
variable "tier" { type = string }
variable "nfs_server" { type = string }
variable "homepage_credentials" {
  type      = map(any)
  sensitive = true
}


resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "servarr-qbittorrent-data-proxmox"
    namespace = "servarr"
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
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
}

module "nfs_downloads_host" {
  source     = "../../../modules/kubernetes/nfs_volume"
  name       = "servarr-qbittorrent-downloads-host"
  namespace  = "servarr"
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/servarr/downloads"
}

module "nfs_audiobooks_host" {
  source     = "../../../modules/kubernetes/nfs_volume"
  name       = "servarr-qbittorrent-audiobooks-host"
  namespace  = "servarr"
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/audiobookshelf/audiobooks"
}

resource "kubernetes_deployment" "qbittorrent" {
  metadata {
    name      = "qbittorrent"
    namespace = "servarr"
    labels = {
      app  = "qbittorrent"
      tier = var.tier
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "qbittorrent"
      }
    }
    template {
      metadata {
        labels = {
          app = "qbittorrent"
        }
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^\\d+\\.\\d+\\.\\d+$"
        }
      }
      spec {
        container {
          image = "lscr.io/linuxserver/qbittorrent:5.0.4"
          name  = "qbittorrent"

          port {
            container_port = 8787
          }
          env {
            name  = "PUID"
            value = 1000
          }
          env {
            name  = "PGID"
            value = 1000
          }
          env {
            name  = "WEBUI_PORT"
            value = 8080
          }
          env {
            name  = "TORRENTING_PORT"
            value = 50000
          }
          volume_mount {
            name       = "data"
            mount_path = "/config"
          }
          volume_mount {
            name       = "downloads"
            mount_path = "/downloads"
          }
          volume_mount {
            name       = "audiobooks"
            mount_path = "/audiobooks"
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_proxmox.metadata[0].name
          }
        }
        volume {
          name = "downloads"
          persistent_volume_claim {
            claim_name = module.nfs_downloads_host.claim_name
          }
        }
        volume {
          name = "audiobooks"
          persistent_volume_claim {
            claim_name = module.nfs_audiobooks_host.claim_name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "qbittorrent" {
  metadata {
    name      = "qbittorrent"
    namespace = "servarr"
    labels = {
      app = "qbittorrent"
    }
  }

  spec {
    selector = {
      app = "qbittorrent"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

resource "kubernetes_service" "qbittorrent-torrenting" {
  metadata {
    name      = "qbittorrent-torrenting"
    namespace = "servarr"
    labels = {
      app = "qbittorrent-torrenting"

    }
    annotations = {
      "metallb.io/loadBalancerIPs" = "10.0.20.200"
      "metallb.io/allow-shared-ip" = "shared"
    }
  }

  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Cluster"
    selector = {
      app = "qbittorrent"
    }
    port {
      name        = "torrenting"
      port        = 50000
      target_port = 50000
    }
    port {
      name        = "torrenting-udp"
      port        = 50000
      protocol    = "UDP"
      target_port = 50000
    }
  }
}


resource "kubernetes_cron_job_v1" "qbittorrent_ratio_monitor" {
  metadata {
    name      = "qbittorrent-ratio-monitor"
    namespace = "servarr"
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 3
    schedule                      = "*/5 * * * *"
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 300
        template {
          metadata {}
          spec {
            container {
              name    = "ratio-monitor"
              image   = "docker.io/library/python:3.12-alpine"
              command = ["/bin/sh", "-c", "set -euo pipefail; pip install -q requests > /dev/null 2>&1; python3 /tmp/monitor.py"]
              volume_mount {
                name       = "script"
                mount_path = "/tmp/monitor.py"
                sub_path   = "monitor.py"
              }
              resources {
                requests = {
                  memory = "64Mi"
                  cpu    = "10m"
                }
                limits = {
                  memory = "128Mi"
                }
              }
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map.ratio_monitor_script.metadata[0].name
              }
            }
            dns_config {
              option {
                name  = "ndots"
                value = "2"
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_config_map" "ratio_monitor_script" {
  metadata {
    name      = "qbt-ratio-monitor-script"
    namespace = "servarr"
  }
  data = {
    "monitor.py" = <<-PYEOF
import requests, json, sys
from collections import defaultdict
from urllib.parse import urlparse

QB_URL = "http://qbittorrent.servarr.svc.cluster.local"
PUSHGW = "http://prometheus-prometheus-pushgateway.monitoring:9091"

try:
    torrents = requests.get(f"{QB_URL}/api/v2/torrents/info", timeout=10).json()
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)

try:
    transfer = requests.get(f"{QB_URL}/api/v2/transfer/info", timeout=10).json()
except Exception:
    transfer = {}

tracker_stats = defaultdict(lambda: {
    "uploaded": 0, "downloaded": 0, "size": 0,
    "count": 0, "seeding": 0, "downloading": 0,
    "seed_time_total": 0, "unsatisfied": 0
})

for t in torrents:
    tracker_url = t.get("tracker", "")
    if not tracker_url:
        domain = "unknown"
    else:
        try:
            domain = urlparse(tracker_url).hostname or "unknown"
        except Exception:
            domain = "unknown"

    if "myanonamouse" in domain or "mam" in domain.lower():
        label = "mam"
    elif "audiobookbay" in domain or "abb" in domain.lower():
        label = "audiobookbay"
    else:
        label = domain.replace(".", "_")

    s = tracker_stats[label]
    s["uploaded"] += t.get("uploaded", 0)
    s["downloaded"] += t.get("downloaded", 0)
    s["size"] += t.get("size", 0)
    s["count"] += 1
    s["seed_time_total"] += t.get("seeding_time", 0)

    state = t.get("state", "")
    if state in ("uploading", "stalledUP", "forcedUP", "queuedUP"):
        s["seeding"] += 1
    elif state in ("downloading", "stalledDL", "forcedDL", "queuedDL"):
        s["downloading"] += 1

    if t.get("seeding_time", 0) < 259200 and t.get("progress", 0) >= 1.0:
        s["unsatisfied"] += 1

for tracker, stats in tracker_stats.items():
    dl = stats["downloaded"]
    ul = stats["uploaded"]
    ratio = ul / dl if dl > 0 else 0.0

    metrics = f"""# HELP qbt_tracker_uploaded_bytes Total bytes uploaded for tracker
# TYPE qbt_tracker_uploaded_bytes gauge
qbt_tracker_uploaded_bytes {ul}
# HELP qbt_tracker_downloaded_bytes Total bytes downloaded for tracker
# TYPE qbt_tracker_downloaded_bytes gauge
qbt_tracker_downloaded_bytes {dl}
# HELP qbt_tracker_ratio Upload/download ratio for tracker
# TYPE qbt_tracker_ratio gauge
qbt_tracker_ratio {ratio:.4f}
# HELP qbt_tracker_torrents_total Total torrents for tracker
# TYPE qbt_tracker_torrents_total gauge
qbt_tracker_torrents_total {stats['count']}
# HELP qbt_tracker_seeding Torrents currently seeding
# TYPE qbt_tracker_seeding gauge
qbt_tracker_seeding {stats['seeding']}
# HELP qbt_tracker_downloading Torrents currently downloading
# TYPE qbt_tracker_downloading gauge
qbt_tracker_downloading {stats['downloading']}
# HELP qbt_tracker_seed_time_total_seconds Total seed time across all torrents
# TYPE qbt_tracker_seed_time_total_seconds gauge
qbt_tracker_seed_time_total_seconds {stats['seed_time_total']}
# HELP qbt_tracker_unsatisfied Torrents not yet seeded 72h
# TYPE qbt_tracker_unsatisfied gauge
qbt_tracker_unsatisfied {stats['unsatisfied']}
# HELP qbt_tracker_size_bytes Total size of all torrents
# TYPE qbt_tracker_size_bytes gauge
qbt_tracker_size_bytes {stats['size']}
"""
    resp = requests.post(
        f"{PUSHGW}/metrics/job/qbt-ratio-monitor/tracker/{tracker}",
        data=metrics, timeout=10
    )
    print(f"Tracker {tracker}: ratio={ratio:.3f} ul={ul} dl={dl} count={stats['count']} seeding={stats['seeding']} unsatisfied={stats['unsatisfied']} -> {resp.status_code}")

connected = 1 if transfer.get("connection_status") == "connected" else 0
dht = transfer.get("dht_nodes", 0)
dl_speed = transfer.get("dl_info_speed", 0)
ul_speed = transfer.get("up_info_speed", 0)

global_metrics = f"""# HELP qbt_connected Whether qBittorrent is connected
# TYPE qbt_connected gauge
qbt_connected {connected}
# HELP qbt_dht_nodes Number of DHT nodes
# TYPE qbt_dht_nodes gauge
qbt_dht_nodes {dht}
# HELP qbt_dl_speed_bytes Current download speed
# TYPE qbt_dl_speed_bytes gauge
qbt_dl_speed_bytes {dl_speed}
# HELP qbt_ul_speed_bytes Current upload speed
# TYPE qbt_ul_speed_bytes gauge
qbt_ul_speed_bytes {ul_speed}
"""
resp = requests.post(
    f"{PUSHGW}/metrics/job/qbt-ratio-monitor/tracker/global",
    data=global_metrics, timeout=10
)
print(f"Global: connected={connected} dht={dht} dl_speed={dl_speed} ul_speed={ul_speed} -> {resp.status_code}")
    PYEOF
  }
}

module "ingress" {
  source          = "../../../modules/kubernetes/ingress_factory"
  dns_type        = "non-proxied"
  namespace       = "servarr"
  name            = "qbittorrent"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"         = "true"
    "gethomepage.dev/name"            = "qBittorrent"
    "gethomepage.dev/description"     = "BitTorrent client"
    "gethomepage.dev/icon"            = "qbittorrent.png"
    "gethomepage.dev/group"           = "Media & Entertainment"
    "gethomepage.dev/pod-selector"    = ""
    "gethomepage.dev/widget.type"     = "qbittorrent"
    "gethomepage.dev/widget.url"      = "http://qbittorrent.servarr.svc.cluster.local"
    "gethomepage.dev/widget.username" = var.homepage_credentials["qbittorrent"]["username"]
    "gethomepage.dev/widget.password" = var.homepage_credentials["qbittorrent"]["password"]
  }
}
