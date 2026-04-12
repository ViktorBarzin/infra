variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

data "vault_kv_secret_v2" "viktor" {
  mount = "secret"
  name  = "viktor"
}

locals {
  index_html = file("${path.module}/index.html")
}

resource "kubernetes_namespace_v1" "status_page" {
  metadata {
    name = "status-page"
    labels = {
      tier = local.tiers.aux
    }
  }
}

resource "kubernetes_config_map_v1" "status_page_template" {
  metadata {
    name      = "status-page-template"
    namespace = kubernetes_namespace_v1.status_page.metadata[0].name
  }
  data = {
    "index.html" = local.index_html
    "CNAME"      = "status.viktorbarzin.me"
  }
}

resource "kubernetes_service_account_v1" "status_page" {
  metadata {
    name      = "status-page-pusher"
    namespace = kubernetes_namespace_v1.status_page.metadata[0].name
  }
}

resource "kubernetes_cluster_role_v1" "ingress_reader" {
  metadata {
    name = "status-page-ingress-reader"
  }
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["list"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "ingress_reader" {
  metadata {
    name = "status-page-ingress-reader"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.ingress_reader.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.status_page.metadata[0].name
    namespace = kubernetes_namespace_v1.status_page.metadata[0].name
  }
}

# =============================================================================
# Status Page Pusher
# Reads Uptime Kuma monitors, generates status.json, pushes to GitHub Pages
# =============================================================================
resource "kubernetes_cron_job_v1" "status_page_pusher" {
  metadata {
    name      = "status-page-pusher"
    namespace = kubernetes_namespace_v1.status_page.metadata[0].name
  }
  spec {
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 3
    schedule                      = "*/5 * * * *"
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 300
        template {
          metadata {}
          spec {
            service_account_name = kubernetes_service_account_v1.status_page.metadata[0].name
            container {
              name  = "status-pusher"
              image = "docker.io/library/python:3.12-alpine"
              command = ["/bin/sh", "-c", <<-EOT
                apk add --no-cache git >/dev/null 2>&1
                pip install --quiet --disable-pip-version-check uptime-kuma-api
                python3 << 'PYEOF'
import os, sys, json, time, subprocess
from datetime import datetime, timezone, timedelta
from uptime_kuma_api import UptimeKumaApi

UPTIME_KUMA_URL = "http://uptime-kuma.uptime-kuma.svc.cluster.local"
UPTIME_KUMA_PASS = os.environ["UPTIME_KUMA_PASSWORD"]
GITHUB_TOKEN = os.environ["GITHUB_TOKEN"]
REPO = "ViktorBarzin/status-page"
REPO_URL = "https://" + GITHUB_TOKEN + "@github.com/" + REPO + ".git"

TYPE_NAMES = {
    "http": "HTTP",
    "port": "TCP Port",
    "ping": "Ping",
    "keyword": "HTTP Keyword",
    "grpc-keyword": "gRPC",
    "dns": "DNS",
    "docker": "Docker",
    "push": "Push",
    "steam": "Steam",
    "gamedig": "GameDig",
    "mqtt": "MQTT",
    "sqlserver": "SQL Server",
    "postgres": "PostgreSQL",
    "mysql": "MySQL",
    "mongodb": "MongoDB",
    "radius": "RADIUS",
    "redis": "Redis",
    "tailscale-ping": "Tailscale Ping",
    "real-browser": "Real Browser",
    "group": "Group",
    "snmp": "SNMP",
    "json-query": "JSON Query",
}

def beat_status_is_up(status_val):
    """Handle both enum and int status values."""
    if hasattr(status_val, "value"):
        return status_val.value == 1
    return status_val == 1

# Build namespace -> external URL map from K8s ingresses
ingress_map = {}
try:
    import ssl, urllib.request
    token_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
    ca_path = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    if os.path.exists(token_path):
        with open(token_path) as f:
            token = f.read().strip()
        ctx = ssl.create_default_context(cafile=ca_path)
        k8s_host = os.environ.get("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc")
        k8s_port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
        req = urllib.request.Request(
            "https://" + k8s_host + ":" + k8s_port + "/apis/networking.k8s.io/v1/ingresses",
            headers={"Authorization": "Bearer " + token}
        )
        resp = urllib.request.urlopen(req, context=ctx, timeout=10)
        ing_data = json.loads(resp.read())
        for item in ing_data.get("items", []):
            ns = item["metadata"]["namespace"]
            rules = item.get("spec", {}).get("rules", [])
            if rules and rules[0].get("host"):
                host = rules[0]["host"]
                if ns not in ingress_map:
                    ingress_map[ns] = "https://" + host
        print(f"Built ingress map: {len(ingress_map)} namespaces")
except Exception as e:
    print(f"Warning: could not build ingress map: {e}")

print("Connecting to Uptime Kuma...")
api = UptimeKumaApi(UPTIME_KUMA_URL, timeout=30)
api.login("admin", UPTIME_KUMA_PASS)

monitors = api.get_monitors()
print(f"Fetched {len(monitors)} monitors")

# Get current heartbeats for live status
heartbeats = api.get_heartbeats()

now = datetime.now(timezone.utc)

def calc_uptime(beat_list, hours):
    cutoff = now - timedelta(hours=hours)
    relevant = []
    for b in beat_list:
        t = str(b["time"])
        try:
            bt = datetime.fromisoformat(t.replace("Z", "+00:00"))
        except (ValueError, TypeError):
            continue
        if bt.tzinfo is None:
            bt = bt.replace(tzinfo=timezone.utc)
        if bt > cutoff:
            relevant.append(b)
    if not relevant:
        return None
    up_count = sum(1 for b in relevant if beat_status_is_up(b.get("status", 0)))
    return round(up_count / len(relevant) * 100, 1)

groups = {}
for m in monitors:
    raw_type = m.get("type", "unknown")
    monitor_type = raw_type.value if hasattr(raw_type, "value") else str(raw_type)
    monitor_type = monitor_type.lower().replace("monitortype.", "")
    group_name = TYPE_NAMES.get(monitor_type, monitor_type.upper())

    if not m.get("active", True):
        continue
    else:
        # Get latest heartbeat for current status
        mid = m["id"]
        mon_beats = heartbeats.get(mid, [])
        if mon_beats:
            # Flatten if nested lists
            if mon_beats and isinstance(mon_beats[0], list):
                mon_beats = [b for sublist in mon_beats for b in sublist]
            latest = mon_beats[-1] if mon_beats else None
            if latest and beat_status_is_up(latest.get("status", 0)):
                status = "up"
            else:
                status = "down"
        else:
            status = "pending"

    uptime_24h = None
    uptime_7d = None
    uptime_30d = None
    try:
        beats = api.get_monitor_beats(m["id"], 720)
        if beats:
            uptime_24h = calc_uptime(beats, 24)
            uptime_7d = calc_uptime(beats, 168)
            uptime_30d = calc_uptime(beats, 720)
    except Exception as e:
        print(f"  Warning: could not get beats for {m['name']}: {e}")

    if group_name not in groups:
        groups[group_name] = []

    # Extract external URL for HTTP monitors
    monitor_url = None
    raw_url = m.get("url", "") or ""
    if monitor_type == "http" and raw_url:
        if ".svc.cluster.local" not in raw_url and raw_url.startswith("http"):
            monitor_url = raw_url.rstrip("/")
        else:
            # Internal URL — derive external from namespace
            import re as _re
            ns_match = _re.search(r"//[^.]+\.([^.]+)\.svc\.cluster\.local", raw_url)
            if ns_match:
                ns = ns_match.group(1)
                if ns in ingress_map:
                    monitor_url = ingress_map[ns]

    entry = {
        "name": m["name"],
        "status": status,
        "uptime_24h": uptime_24h,
        "uptime_7d": uptime_7d,
        "uptime_30d": uptime_30d,
    }
    if monitor_url:
        entry["url"] = monitor_url

    groups[group_name].append(entry)

api.disconnect()
print(f"Generated {len(groups)} groups")

status_data = {
    "last_updated": now.isoformat(),
    "groups": groups,
}

work_dir = "/tmp/status-page"
subprocess.run(["rm", "-rf", work_dir], check=True)
subprocess.run(["git", "clone", "--depth=1", REPO_URL, work_dir], check=True, capture_output=True)

# Sync template files from ConfigMap mount
import shutil
for tpl in ["index.html", "CNAME"]:
    src = os.path.join("/template", tpl)
    dst = os.path.join(work_dir, tpl)
    if os.path.exists(src):
        shutil.copy2(src, dst)

# Ensure .nojekyll exists
open(os.path.join(work_dir, ".nojekyll"), "a").close()

with open(os.path.join(work_dir, "status.json"), "w") as f:
    json.dump(status_data, f, indent=2)

history_dir = os.path.join(work_dir, "history")
os.makedirs(history_dir, exist_ok=True)
today_file = os.path.join(history_dir, now.strftime("%Y-%m-%d") + ".json")
history = []
if os.path.exists(today_file):
    with open(today_file) as f:
        try:
            history = json.load(f)
        except json.JSONDecodeError:
            history = []

snapshot = {"timestamp": now.isoformat(), "monitors": {}}
for gname, gmonitors in groups.items():
    for mon in gmonitors:
        snapshot["monitors"][mon["name"]] = mon["status"]
history.append(snapshot)
with open(today_file, "w") as f:
    json.dump(history, f)

cutoff_date = (now - timedelta(days=30)).strftime("%Y-%m-%d")
for fname in os.listdir(history_dir):
    if fname.endswith(".json") and fname < cutoff_date + ".json":
        os.remove(os.path.join(history_dir, fname))
        print(f"  Deleted old history: {fname}")

os.chdir(work_dir)
subprocess.run(["git", "config", "user.email", "status-bot@viktorbarzin.me"], check=True)
subprocess.run(["git", "config", "user.name", "Status Bot"], check=True)
subprocess.run(["git", "add", "-A"], check=True)

result = subprocess.run(["git", "diff", "--cached", "--quiet"])
if result.returncode == 0:
    print("No changes to push")
    sys.exit(0)

commit_msg = "status update " + now.strftime("%Y-%m-%d %H:%M UTC")
subprocess.run(["git", "commit", "-m", commit_msg], check=True)
push_result = subprocess.run(["git", "push"], capture_output=True, text=True)
if push_result.returncode != 0:
    print(f"Push failed: {push_result.stderr}")
    sys.exit(1)

print(f"Successfully pushed status update at {now.isoformat()}")
PYEOF
              EOT
              ]
              env {
                name  = "UPTIME_KUMA_PASSWORD"
                value = data.vault_kv_secret_v2.viktor.data["uptime_kuma_admin_password"]
              }
              env {
                name  = "GITHUB_TOKEN"
                value = data.vault_kv_secret_v2.viktor.data["github_pat"]
              }
              volume_mount {
                name       = "template"
                mount_path = "/template"
                read_only  = true
              }
              resources {
                requests = {
                  memory = "128Mi"
                  cpu    = "10m"
                }
                limits = {
                  memory = "256Mi"
                }
              }
            }
            volume {
              name = "template"
              config_map {
                name = kubernetes_config_map_v1.status_page_template.metadata[0].name
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
  lifecycle {
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}
