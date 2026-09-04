variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "mysql_host" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

locals {
  technitium_password = data.vault_kv_secret_v2.secrets.data["technitium_password"]
  technitium_username = try(data.vault_kv_secret_v2.secrets.data["technitium_username"], "admin")
  # Optional Technitium PERMANENT API token. A session login is tied to the admin
  # password, so rotating that password silently breaks every consumer of this
  # API; a permanent token survives it. The key is absent from Vault today, so
  # this is "" and phpipam-dns-sync falls back to the session login. Minting it
  # is a one-time human step -- POST /api/user/createToken with user, pass and
  # tokenName -- then `vault kv patch secret/platform technitium_api_token=...`,
  # after which the next apply picks it up with no code change.
  technitium_api_token = try(data.vault_kv_secret_v2.secrets.data["technitium_api_token"], "")
}

resource "kubernetes_namespace" "phpipam" {
  metadata {
    name = "phpipam"
    labels = {
      tier               = local.tiers.aux
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "phpipam-secrets"
      namespace = "phpipam"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "phpipam-secrets"
      }
      data = [{
        secretKey = "db_password"
        remoteRef = {
          key      = "static-creds/mysql-phpipam"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.phpipam]
}

resource "kubernetes_manifest" "external_secret_pfsense_ssh" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "phpipam-pfsense-ssh"
      namespace = "phpipam"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "phpipam-pfsense-ssh"
      }
      data = [{
        secretKey = "ssh_key"
        remoteRef = {
          key      = "viktor"
          property = "phpipam_pfsense_ssh_key"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.phpipam]
}

resource "kubernetes_manifest" "external_secret_admin" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "phpipam-admin-password"
      namespace = "phpipam"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "phpipam-admin-password"
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "viktor"
          property = "phpipam_admin_password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.phpipam]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.phpipam.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "phpipam_web" {
  metadata {
    name      = "phpipam-web"
    namespace = kubernetes_namespace.phpipam.metadata[0].name
    labels = {
      app  = "phpipam"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "phpipam"
      }
    }
    template {
      metadata {
        labels = {
          app = "phpipam"
        }
        annotations = {
          "diun.enable"                    = "true"
          "dependency.kyverno.io/wait-for" = "mysql.dbaas:3306"
        }
      }
      spec {
        container {
          image = "phpipam/phpipam-www:v1.7.4"
          name  = "phpipam-web"
          port {
            container_port = 80
          }
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }
          env {
            name  = "IPAM_DATABASE_HOST"
            value = var.mysql_host
          }
          env {
            name  = "IPAM_DATABASE_USER"
            value = "phpipam"
          }
          env {
            name = "IPAM_DATABASE_PASS"
            value_from {
              secret_key_ref {
                name = "phpipam-secrets"
                key  = "db_password"
              }
            }
          }
          env {
            name  = "IPAM_DATABASE_NAME"
            value = "phpipam"
          }
          env {
            name  = "IPAM_TRUST_X_FORWARDED"
            value = "true"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      # Stakater Reloader stamps this on every secret-triggered restart. The
      # 2026-08-14 switch to reloadStrategy = annotations (stacks/reloader) moved
      # the marker onto this pod-template annotation on the expectation that
      # Terraform does not manage it, but it does wherever the pod template
      # declares annotations, so it planned as a removal on every run.
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
      spec[0].template[0].spec[0].dns_config,                                                  # KYVERNO_LIFECYCLE_V1
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

# phpipam-cron container removed — discovery now handled by phpipam-pfsense-import CronJob
# which queries Kea DHCP leases + pfSense ARP table directly (no fping needed)

resource "kubernetes_service" "phpipam" {
  metadata {
    name      = "phpipam"
    namespace = kubernetes_namespace.phpipam.metadata[0].name
    labels = {
      app = "phpipam"
    }
  }
  spec {
    selector = {
      app = "phpipam"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 80
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.phpipam.metadata[0].name
  name            = "phpipam"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "phpIPAM"
    "gethomepage.dev/description"  = "IP Address Management"
    "gethomepage.dev/icon"         = "phpipam.png"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}

# CronJob: Bidirectional sync between phpIPAM and Technitium DNS
# 1. Push: named phpIPAM hosts → Technitium A + PTR records
# 2. Pull: Technitium reverse DNS → phpIPAM hostnames for unnamed entries
resource "kubernetes_cron_job_v1" "phpipam_dns_sync" {
  metadata {
    name      = "phpipam-dns-sync"
    namespace = kubernetes_namespace.phpipam.metadata[0].name
  }
  spec {
    schedule                      = "*/15 * * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    concurrency_policy            = "Forbid"
    job_template {
      metadata {}
      spec {
        backoff_limit = 1
        template {
          metadata {}
          spec {
            restart_policy = "Never"
            container {
              name  = "sync"
              image = "mysql:8.0"
              command = ["/bin/bash", "-c", <<-EOT
                set -e
                TECH_URL="http://technitium-web.technitium.svc.cluster.local:5380"
                TECH_OUT=/tmp/tech-response.json

                # Every Technitium API endpoint answers HTTP 200 and carries the
                # real outcome in a JSON "status" field, so `curl -sf` on its own
                # cannot tell success from failure. Verified against the live API
                # 2026-09-03: a wrong password returns 200 {"status":"error"} and a
                # stale token returns 200 {"status":"invalid-token"}. The previous
                # version of this script tested the login only for an EMPTY token,
                # so a rotated password left TECH_TOKEN holding the error JSON
                # itself, printed "Technitium auth OK", wrote nothing, and exited 0
                # -- a silent no-op sync that no monitor could see. tech_call
                # publishes TECH_HTTP / TECH_STATUS / TECH_BODY and returns
                # non-zero unless status is "ok".
                tech_call() {
                  TECH_PATH="$1"; shift
                  # Truncate first: on a connection failure curl writes no output
                  # file at all, and without this the parse below reads the PREVIOUS
                  # call's body and reports its status as this call's.
                  : > "$$TECH_OUT"
                  TECH_HTTP=$$(curl -s --max-time 20 -o "$$TECH_OUT" -w '%%{http_code}' "$$TECH_URL$$TECH_PATH" "$$@") || TECH_HTTP=000
                  TECH_STATUS=$$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$$TECH_OUT" | head -1)
                  TECH_BODY=$$(head -c 300 "$$TECH_OUT" | tr -d '\n')
                  [ "$$TECH_HTTP" = "200" ] && [ "$$TECH_STATUS" = "ok" ]
                }

                # --- authenticate -------------------------------------------------
                # Prefer a Technitium PERMANENT API token when one is in Vault: it
                # survives an admin-password rotation, which a session login does
                # not. Falls back to the session login while that key is absent.
                if [ -n "$${TECH_API_TOKEN:-}" ]; then
                  TECH_TOKEN="$$TECH_API_TOKEN"
                  echo "Technitium auth: permanent API token from Vault"
                else
                  TECH_TOKEN=""
                  BACKOFF=5
                  for ATTEMPT in 1 2 3 4; do
                    if tech_call "/api/user/login" --data-urlencode "user=$$TECH_USER" --data-urlencode "pass=$$TECH_PASS"; then
                      TECH_TOKEN=$$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$$TECH_OUT" | head -1)
                      echo "Technitium auth OK (session login, attempt $$ATTEMPT)"
                      break
                    fi
                    echo "Technitium login attempt $$ATTEMPT/4 failed: http=$$TECH_HTTP status=$${TECH_STATUS:-<none>} body=$${TECH_BODY:-<empty>}"
                    # status "error" means Technitium answered and rejected the
                    # credentials. Retrying that just burns 75s and logs the same
                    # line four times; only a connection failure or a 5xx is worth
                    # waiting out (Technitium restarting, which is what the
                    # 2026-08-04 primary outage looked like from in here).
                    if [ "$$TECH_STATUS" = "error" ]; then
                      echo "Technitium rejected the credentials; this is not transient, not retrying"
                      break
                    fi
                    [ "$$ATTEMPT" = "4" ] && break
                    echo "  retrying in $${BACKOFF}s"
                    sleep "$$BACKOFF"
                    BACKOFF=$$((BACKOFF * 2))
                  done
                fi
                if [ -z "$$TECH_TOKEN" ]; then
                  echo "Technitium login failed; see the per-attempt http/status/body lines above"
                  exit 1
                fi

                # Prove the credential actually works BEFORE touching phpIPAM, so a
                # bad token fails the Job here with a readable reason instead of
                # writing zero records and exiting green.
                if ! tech_call "/api/zones/list?token=$$TECH_TOKEN"; then
                  echo "Technitium token rejected: http=$$TECH_HTTP status=$${TECH_STATUS:-<none>} body=$${TECH_BODY:-<empty>}"
                  exit 1
                fi
                echo "Technitium auth verified"

                # Query phpIPAM MySQL directly for hosts with hostnames
                mysql -h $$DB_HOST -u $$DB_USER -p$$DB_PASS $$DB_NAME -N -B -e \
                  "SELECT INET_NTOA(ip_addr), hostname FROM ipaddresses WHERE hostname != '' AND hostname IS NOT NULL AND subnetId >= 7" > /tmp/hosts.tsv

                # Read from a file, not a pipeline: `... | while` runs the loop in a
                # subshell, so the counters below never survived it.
                SYNCED=0
                FAILED=0
                while IFS=$$'\t' read -r IP HOSTNAME; do
                  [ -z "$$IP" ] || [ -z "$$HOSTNAME" ] && continue
                  SHORT=$$(echo "$$HOSTNAME" | cut -d. -f1)
                  FQDN="$$SHORT.viktorbarzin.lan"

                  # A record
                  if tech_call "/api/zones/records/add?token=$$TECH_TOKEN" -X POST \
                    -d "domain=$$FQDN&zone=viktorbarzin.lan&type=A&ipAddress=$$IP&overwrite=true&ttl=300"; then
                    SYNCED=$$((SYNCED + 1))
                    echo "  $$IP -> $$FQDN"
                  else
                    FAILED=$$((FAILED + 1))
                    echo "  A add FAILED $$IP -> $$FQDN: http=$$TECH_HTTP status=$${TECH_STATUS:-<none>} body=$${TECH_BODY:-<empty>}"
                  fi

                  # PTR record. Tolerated on failure as before: reverse zones do not
                  # exist for every subnet, so a miss here is normal, not an error.
                  O1=$$(echo $$IP | cut -d. -f1); O2=$$(echo $$IP | cut -d. -f2)
                  O3=$$(echo $$IP | cut -d. -f3); O4=$$(echo $$IP | cut -d. -f4)
                  tech_call "/api/zones/records/add?token=$$TECH_TOKEN" -X POST \
                    -d "domain=$$O4.$$O3.$$O2.$$O1.in-addr.arpa&zone=$$O3.$$O2.$$O1.in-addr.arpa&type=PTR&ptrName=$$FQDN&overwrite=true&ttl=300" || true
                done < /tmp/hosts.tsv
                echo "Push sync complete: $$SYNCED A record(s) written, $$FAILED failure(s)"
                if [ "$$SYNCED" -eq 0 ] && [ "$$FAILED" -gt 0 ]; then
                  echo "Every A record write failed; treating this run as failed rather than reporting success"
                  exit 1
                fi

                # Reverse sync: pull hostnames from DNS into phpIPAM for unnamed entries
                echo ""
                echo "=== Reverse sync: DNS -> phpIPAM ==="
                mysql -h $$DB_HOST -u $$DB_USER -p$$DB_PASS $$DB_NAME -N -B -e \
                  "SELECT id, INET_NTOA(ip_addr) FROM ipaddresses WHERE (hostname IS NULL OR hostname = '') AND subnetId >= 7" > /tmp/unnamed.tsv

                while IFS=$$'\t' read -r ID IP; do
                  [ -z "$$ID" ] || [ -z "$$IP" ] && continue
                  # Query Technitium for PTR record
                  O1=$$(echo $$IP | cut -d. -f1); O2=$$(echo $$IP | cut -d. -f2)
                  O3=$$(echo $$IP | cut -d. -f3); O4=$$(echo $$IP | cut -d. -f4)
                  PTR_NAME="$$O4.$$O3.$$O2.$$O1.in-addr.arpa"
                  REV_ZONE="$$O3.$$O2.$$O1.in-addr.arpa"
                  tech_call "/api/zones/records/get?token=$$TECH_TOKEN&domain=$$PTR_NAME&zone=$$REV_ZONE&type=PTR" || continue
                  HOSTNAME=$$(sed -n 's/.*"ptrName":"\([^"]*\)".*/\1/p' "$$TECH_OUT" | head -1)
                  [ -z "$$HOSTNAME" ] && continue

                  # Extract short name
                  SHORT=$$(echo "$$HOSTNAME" | cut -d. -f1)
                  [ -z "$$SHORT" ] && continue
                  # $$SHORT is interpolated into SQL below and its value comes from a
                  # DNS record, so restrict it to what a hostname label may contain.
                  case "$$SHORT" in
                    *[!A-Za-z0-9-]*) echo "  skipping $$IP: PTR name '$$SHORT' is not a plain hostname label"; continue ;;
                  esac

                  # Update phpIPAM
                  mysql -h $$DB_HOST -u $$DB_USER -p$$DB_PASS $$DB_NAME -e \
                    "UPDATE ipaddresses SET hostname='$$SHORT' WHERE id=$$ID AND (hostname IS NULL OR hostname = '')"
                  echo "  $$IP -> $$SHORT (from DNS)"
                done < /tmp/unnamed.tsv
                echo "Bidirectional sync complete"
              EOT
              ]
              env {
                name  = "TECH_USER"
                value = local.technitium_username
              }
              env {
                name  = "TECH_PASS"
                value = local.technitium_password
              }
              env {
                name  = "TECH_API_TOKEN"
                value = local.technitium_api_token
              }
              env {
                name  = "DB_HOST"
                value = var.mysql_host
              }
              env {
                name  = "DB_USER"
                value = "phpipam"
              }
              env {
                name = "DB_PASS"
                value_from {
                  secret_key_ref {
                    name = "phpipam-secrets"
                    key  = "db_password"
                  }
                }
              }
              env {
                name  = "DB_NAME"
                value = "phpipam"
              }
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "32Mi"
                }
                limits = {
                  memory = "128Mi"
                }
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

# CronJob: Import devices from pfSense (Kea DHCP leases + ARP table) into phpIPAM
# Replaces active fping scanning with passive data from pfSense
resource "kubernetes_cron_job_v1" "phpipam_pfsense_import" {
  metadata {
    name      = "phpipam-pfsense-import"
    namespace = kubernetes_namespace.phpipam.metadata[0].name
  }
  spec {
    schedule                      = "0 * * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    concurrency_policy            = "Forbid"
    job_template {
      metadata {}
      spec {
        backoff_limit = 1
        # Same wedge as webterminal-probe, at the same moment: on 2026-08-10
        # 02:00 this Job's `apk add openssh-client mysql-client python3` hung on
        # a black-holed TLS connection to the Alpine CDN (151.101.194.132:443 --
        # ESTABLISHED but dead, no FIN/RST, and apk applies no timeout). With
        # Forbid and no deadline it ran for 3d19h and blocked every hourly
        # import, so Kea lease + ARP data went stale for nearly four days.
        # Nothing alerted: unlike the webterminal probe this CronJob has no
        # staleness alert, so the wedged Job was the only signal. A normal run
        # finishes in ~9s and imported 40 new entries once unblocked, so 600s
        # only ever trips on a hang.
        active_deadline_seconds = 600
        template {
          metadata {}
          spec {
            restart_policy = "Never"
            container {
              name  = "import"
              image = "alpine:3.21"
              command = ["/bin/sh", "-c", <<-EOT
                set -e
                apk add --no-cache -q openssh-client mysql-client python3 > /dev/null 2>&1

                # Setup SSH key
                mkdir -p /root/.ssh
                cp /ssh/ssh_key /root/.ssh/id_rsa
                chmod 600 /root/.ssh/id_rsa
                echo "StrictHostKeyChecking no" > /root/.ssh/config

                # 1. Get Kea DHCP leases via control socket
                echo "=== Fetching Kea leases ==="
                LEASES=$$(ssh admin@10.0.20.1 'echo "{\"command\": \"lease4-get-all\"}" | /usr/bin/nc -U /tmp/kea4-ctrl-socket 2>/dev/null')

                # 2. Get ARP table
                echo "=== Fetching ARP table ==="
                ARP=$$(ssh admin@10.0.20.1 'arp -an' 2>/dev/null)

                # Remote sites handled by phpipam-remote-import CronJob (hourly)

                # 3. Parse and import into phpIPAM MySQL
                echo "=== Importing into phpIPAM ==="
                export LEASES_DATA="$$LEASES"
                export ARP_DATA="$$ARP"
                python3 << 'PYEOF'
import json, subprocess, sys, re, os

db_host = os.environ["DB_HOST"]
db_user = os.environ["DB_USER"]
db_pass = os.environ["DB_PASS"]
db_name = os.environ["DB_NAME"]

def mysql_exec(sql):
    r = subprocess.run(
        ["mysql", "-h", db_host, "-u", db_user, f"-p{db_pass}", db_name, "-N", "-B", "-e", sql],
        capture_output=True, text=True
    )
    return r.stdout.strip()

# Get existing phpIPAM entries (subnetId >= 7 = our subnets)
existing = {}
rows = mysql_exec("SELECT INET_NTOA(ip_addr), hostname, mac, subnetId FROM ipaddresses WHERE subnetId >= 7")
for line in rows.split("\n"):
    if not line: continue
    parts = line.split("\t")
    existing[parts[0]] = {"hostname": parts[1] if parts[1] != "NULL" else "", "mac": parts[2] if parts[2] != "NULL" else "", "subnetId": parts[3]}

# Subnet mapping
def get_subnet_id(ip):
    if ip.startswith("10.0.10."): return 7
    if ip.startswith("10.0.20."): return 8
    if ip.startswith("192.168.1."): return 9
    if ip.startswith("10.3.2."): return 10
    if ip.startswith("192.168.8."): return 11
    if ip.startswith("192.168.0."): return 12
    return None

# Parse Kea leases
leases_raw = os.environ.get("LEASES_DATA", "{}")
try:
    leases_json = json.loads(leases_raw)
    leases = leases_json.get("arguments", {}).get("leases", []) if isinstance(leases_json, dict) else leases_json[0].get("arguments", {}).get("leases", [])
except:
    leases = []

imported = 0
updated_mac = 0
updated_hostname = 0

for lease in leases:
    ip = lease["ip-address"]
    mac = lease.get("hw-address", "")
    hostname = lease.get("hostname", "").split(".")[0]  # strip .viktorbarzin.lan
    subnet_id = get_subnet_id(ip)
    if not subnet_id: continue

    if ip not in existing:
        # New host — insert
        mac_sql = f"'{mac}'" if mac else "NULL"
        host_sql = f"'{hostname}'" if hostname else "''"
        mysql_exec(f"INSERT INTO ipaddresses (ip_addr, subnetId, hostname, mac, description, lastSeen) VALUES (INET_ATON('{ip}'), {subnet_id}, {host_sql}, {mac_sql}, '-- kea lease --', NOW())")
        imported += 1
        print(f"  NEW {ip} -> {hostname} mac={mac}")
    else:
        # Existing — update MAC if missing, hostname if missing, lastSeen always
        updates = ["lastSeen=NOW()"]
        if mac and not existing[ip]["mac"]:
            updates.append(f"mac='{mac}'")
            updated_mac += 1
        if hostname and not existing[ip]["hostname"]:
            updates.append(f"hostname='{hostname}'")
            updated_hostname += 1
        mysql_exec(f"UPDATE ipaddresses SET {','.join(updates)} WHERE ip_addr=INET_ATON('{ip}')")

# Parse ARP table for devices not in Kea (static IPs)
arp_raw = os.environ.get("ARP_DATA", "")
lease_ips = {l["ip-address"] for l in leases}

for line in arp_raw.split("\n"):
    m = re.match(r'\? \((\d+\.\d+\.\d+\.\d+)\) at ([0-9a-f:]+) on', line)
    if not m: continue
    ip, mac = m.group(1), m.group(2)
    if mac == "(incomplete)": continue
    subnet_id = get_subnet_id(ip)
    if not subnet_id: continue
    if ip in lease_ips: continue  # already handled by Kea

    if ip not in existing:
        mysql_exec(f"INSERT INTO ipaddresses (ip_addr, subnetId, mac, description, lastSeen) VALUES (INET_ATON('{ip}'), {subnet_id}, '{mac}', '-- arp discovered --', NOW())")
        imported += 1
        print(f"  NEW (arp) {ip} mac={mac}")
    else:
        updates = ["lastSeen=NOW()"]
        if mac and not existing[ip]["mac"]:
            updates.append(f"mac='{mac}'")
            updated_mac += 1
        mysql_exec(f"UPDATE ipaddresses SET {','.join(updates)} WHERE ip_addr=INET_ATON('{ip}')")

print(f"\nImported: {imported} new, Updated: {updated_mac} MACs, {updated_hostname} hostnames")
PYEOF
                echo "Import complete"
              EOT
              ]
              env {
                name  = "DB_HOST"
                value = var.mysql_host
              }
              env {
                name  = "DB_USER"
                value = "phpipam"
              }
              env {
                name = "DB_PASS"
                value_from {
                  secret_key_ref {
                    name = "phpipam-secrets"
                    key  = "db_password"
                  }
                }
              }
              env {
                name  = "DB_NAME"
                value = "phpipam"
              }
              volume_mount {
                name       = "ssh-key"
                mount_path = "/ssh"
                read_only  = true
              }
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "64Mi"
                }
                limits = {
                  memory = "128Mi"
                }
              }
            }
            volume {
              name = "ssh-key"
              secret {
                secret_name  = "phpipam-pfsense-ssh"
                default_mode = "0400"
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

# CronJob: Import devices from remote sites (London + Valchedrym) via SSH
# Runs hourly — these networks are mostly static
resource "kubernetes_cron_job_v1" "phpipam_remote_import" {
  metadata {
    name      = "phpipam-remote-import"
    namespace = kubernetes_namespace.phpipam.metadata[0].name
  }
  spec {
    schedule                      = "0 * * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    concurrency_policy            = "Forbid"
    job_template {
      metadata {}
      spec {
        backoff_limit = 1
        template {
          metadata {}
          spec {
            restart_policy = "Never"
            container {
              name  = "import"
              image = "alpine:3.21"
              command = ["/bin/sh", "-c", <<-EOT
                set -e
                apk add --no-cache -q openssh-client mysql-client python3 > /dev/null 2>&1

                mkdir -p /root/.ssh
                cp /ssh/ssh_key /root/.ssh/id_rsa
                chmod 600 /root/.ssh/id_rsa
                echo "StrictHostKeyChecking no" > /root/.ssh/config

                # Pull DHCP leases + ARP from Valchedrym via pfSense SSH hop
                echo "=== Valchedrym (192.168.0.1 via pfSense) ==="
                VALCHEDRYM=$$(ssh -o ConnectTimeout=10 admin@10.0.20.1 'timeout 15 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@192.168.0.1 "cat /tmp/dhcp.leases 2>/dev/null; echo ---ARP---; cat /proc/net/arp 2>/dev/null" 2>/dev/null' 2>/dev/null || echo "")

                echo "=== London (192.168.8.1 via pfSense) ==="
                LONDON=$$(ssh -o ConnectTimeout=10 admin@10.0.20.1 'timeout 15 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@192.168.8.1 "cat /tmp/dhcp.leases 2>/dev/null; echo ---ARP---; cat /proc/net/arp 2>/dev/null" 2>/dev/null' 2>/dev/null || echo "")

                echo "=== Importing ==="
                export LONDON_DATA="$$LONDON"
                export VALCHEDRYM_DATA="$$VALCHEDRYM"
                python3 << 'PYEOF'
import os, re, subprocess

db_host = os.environ["DB_HOST"]
db_user = os.environ["DB_USER"]
db_pass = os.environ["DB_PASS"]
db_name = os.environ["DB_NAME"]

def mysql_exec(sql):
    subprocess.run(["mysql", "-h", db_host, "-u", db_user, f"-p{db_pass}", db_name, "-N", "-B", "-e", sql], capture_output=True, text=True)

def get_existing():
    r = subprocess.run(["mysql", "-h", db_host, "-u", db_user, f"-p{db_pass}", db_name, "-N", "-B", "-e",
        "SELECT INET_NTOA(ip_addr), hostname, mac, subnetId FROM ipaddresses WHERE subnetId IN (11, 12)"],
        capture_output=True, text=True)
    existing = {}
    for line in r.stdout.strip().split("\n"):
        if not line: continue
        parts = line.split("\t")
        existing[parts[0]] = {"hostname": parts[1] if parts[1] != "NULL" else "", "mac": parts[2] if parts[2] != "NULL" else ""}
    return existing

def import_site(data, subnet_prefix, subnet_id, site_name):
    if not data or "---ARP---" not in data:
        print(f"  {site_name}: no data")
        return 0
    existing = get_existing()
    dhcp_part, arp_part = data.split("---ARP---", 1)
    imported = 0

    # DHCP leases: timestamp mac ip hostname client_id
    for line in dhcp_part.strip().split("\n"):
        parts = line.split()
        if len(parts) < 4: continue
        mac, ip, hostname = parts[1], parts[2], parts[3]
        if not ip.startswith(subnet_prefix): continue
        short = hostname.split(".")[0] if hostname != "*" else ""
        if ip not in existing:
            mac_sql = f"'{mac}'" if mac else "NULL"
            host_sql = f"'{short}'" if short else "''"
            mysql_exec(f"INSERT INTO ipaddresses (ip_addr, subnetId, hostname, mac, description, lastSeen) VALUES (INET_ATON('{ip}'), {subnet_id}, {host_sql}, {mac_sql}, '-- {site_name} dhcp --', NOW())")
            imported += 1
            print(f"  NEW {ip} -> {short} mac={mac}")
        else:
            updates = ["lastSeen=NOW()"]
            if mac and not existing[ip]["mac"]: updates.append(f"mac='{mac}'")
            if short and not existing[ip]["hostname"]: updates.append(f"hostname='{short}'")
            mysql_exec(f"UPDATE ipaddresses SET {','.join(updates)} WHERE ip_addr=INET_ATON('{ip}')")

    # ARP table
    for line in arp_part.strip().split("\n"):
        m = re.match(r'(\d+\.\d+\.\d+\.\d+)\s+\S+\s+\S+\s+([0-9a-f:]+)\s+', line)
        if not m: continue
        ip, mac = m.group(1), m.group(2)
        if not ip.startswith(subnet_prefix) or mac == "00:00:00:00:00:00": continue
        if ip in existing: continue
        mysql_exec(f"INSERT INTO ipaddresses (ip_addr, subnetId, mac, description, lastSeen) VALUES (INET_ATON('{ip}'), {subnet_id}, '{mac}', '-- {site_name} arp --', NOW())")
        imported += 1
        print(f"  NEW (arp) {ip} mac={mac}")
    return imported

london = import_site(os.environ.get("LONDON_DATA", ""), "192.168.8.", 11, "london")
valchedrym = import_site(os.environ.get("VALCHEDRYM_DATA", ""), "192.168.0.", 12, "valchedrym")
print(f"\nLondon: {london} new, Valchedrym: {valchedrym} new")
PYEOF
                echo "Remote import complete"
              EOT
              ]
              env {
                name  = "DB_HOST"
                value = var.mysql_host
              }
              env {
                name  = "DB_USER"
                value = "phpipam"
              }
              env {
                name = "DB_PASS"
                value_from {
                  secret_key_ref {
                    name = "phpipam-secrets"
                    key  = "db_password"
                  }
                }
              }
              env {
                name  = "DB_NAME"
                value = "phpipam"
              }
              volume_mount {
                name       = "ssh-key"
                mount_path = "/ssh"
                read_only  = true
              }
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "64Mi"
                }
                limits = {
                  memory = "128Mi"
                }
              }
            }
            volume {
              name = "ssh-key"
              secret {
                secret_name  = "phpipam-pfsense-ssh"
                default_mode = "0400"
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

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
