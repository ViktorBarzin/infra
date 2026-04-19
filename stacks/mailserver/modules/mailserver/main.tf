variable "tls_secret_name" {}
variable "tier" { type = string }
variable "mailserver_accounts" {}
variable "postfix_account_aliases" {}
variable "opendkim_key" {}
variable "sasl_passwd" {} # For sendgrid i.e relayhost
variable "nfs_server" { type = string }
# Build the virtual-alias map, dropping aliases where BOTH the source and
# target are real mailboxes in var.mailserver_accounts (and are different).
# Without this filter, docker-mailserver emits two passwd-file userdb lines
# for the source address — its own mailbox home plus the alias target's home
# — and Dovecot logs 'exists more than once' on every auth lookup. Aliases
# that forward to external addresses (gmail etc.) or to self are safe.
locals {
  _account_set   = keys(var.mailserver_accounts)
  _virtual_lines = split("\n", format("%s%s", var.postfix_account_aliases, file("${path.module}/extra/aliases.txt")))
  postfix_virtual = join("\n", [
    for line in local._virtual_lines : line
    if !(
      length(split(" ", line)) == 2 &&
      contains(local._account_set, split(" ", line)[0]) &&
      contains(local._account_set, split(" ", line)[1]) &&
      split(" ", line)[0] != split(" ", line)[1]
    )
  ])
}

resource "kubernetes_namespace" "mailserver" {
  metadata {
    name = "mailserver"
    labels = {
      tier = var.tier
    }
    # connecting via localhost does not seem to work?
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.mailserver.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_config_map" "mailserver_env_config" {
  metadata {
    name      = "mailserver.env.config"
    namespace = kubernetes_namespace.mailserver.metadata[0].name
    labels = {
      app = "mailserver"
    }
    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    DMS_DEBUG = "0"
    # LOG_LEVEL                              = "debug"
    ENABLE_CLAMAV                          = "0"
    ENABLE_AMAVIS                          = "0"
    ENABLE_FAIL2BAN                        = "0"
    ENABLE_FETCHMAIL                       = "0"
    ENABLE_POSTGREY                        = "0"
    ENABLE_SASLAUTHD                       = "0"
    ENABLE_SPAMASSASSIN                    = "0"
    ENABLE_RSPAMD                          = "1"
    ENABLE_OPENDKIM                        = "0"
    ENABLE_OPENDMARC                       = "0"
    ENABLE_RSPAMD_REDIS                    = "0"
    RSPAMD_LEARN                           = "1"
    ENABLE_SRS                             = "1"
    FETCHMAIL_POLL                         = "120"
    ONE_DIR                                = "1"
    OVERRIDE_HOSTNAME                      = "mail.viktorbarzin.me"
    POSTFIX_MESSAGE_SIZE_LIMIT             = 1024 * 1024 * 200 # 200 MB
    POSTFIX_REJECT_UNKNOWN_CLIENT_HOSTNAME = "1"
    # TLS_LEVEL                              = "intermediate"
    # DEFAULT_RELAY_HOST = "[smtp.sendgrid.net]:587"
    DEFAULT_RELAY_HOST = "[smtp-relay.brevo.com]:587"
    SPOOF_PROTECTION   = "1"
    SSL_TYPE           = "manual"
    SSL_CERT_PATH      = "/tmp/ssl/tls.crt"
    SSL_KEY_PATH       = "/tmp/ssl/tls.key"
  }
}

resource "kubernetes_config_map" "mailserver_config" {
  metadata {
    name      = "mailserver.config"
    namespace = kubernetes_namespace.mailserver.metadata[0].name

    labels = {
      app = "mailserver"
    }
    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    # Actual mail settings
    "postfix-accounts.cf" = join("\n", [for user, pass in var.mailserver_accounts : "${user}|${bcrypt(pass, 6)}"])
    "postfix-main.cf"     = var.postfix_cf
    "postfix-virtual.cf"  = local.postfix_virtual

    KeyTable      = "mail._domainkey.viktorbarzin.me viktorbarzin.me:mail:/etc/opendkim/keys/viktorbarzin.me-mail.key\n"
    SigningTable  = "*@viktorbarzin.me mail._domainkey.viktorbarzin.me\n"
    TrustedHosts  = "127.0.0.1\nlocalhost\n"
    "sasl_passwd" = var.sasl_passwd
    # Rspamd DKIM signing configuration
    "dkim_signing.conf" = <<-EOF
    enabled = true;
    sign_authenticated = true;
    sign_local = true;
    use_domain = "header";
    use_redis = false;
    use_esld = true;
    selector = "mail";
    path = "/tmp/docker-mailserver/rspamd/dkim/viktorbarzin.me/mail.private";
    domain {
        viktorbarzin.me {
            path = "/tmp/docker-mailserver/rspamd/dkim/viktorbarzin.me/mail.private";
            selector = "mail";
        }
    }
    EOF
    # Increase max IMAP connections per user+IP - all Roundcube connections come from same pod IP
    "dovecot.cf"  = <<-EOF
    mail_max_userip_connections = 50
    EOF
    fail2ban_conf = <<-EOF
    [DEFAULT]

    #logtarget = /var/log/fail2ban.log
    logtarget = SYSOUT
    EOF
  }
  # Password hashes are different each time and avoid changing secret constantly.
  # Either 1.Create consistent hashes or 2.Find a way to ignore_changes on per password
  lifecycle {
    # DRIFT_WORKAROUND: postfix-accounts.cf password hashes non-deterministic; would flap on every apply. Reviewed 2026-04-18.
    ignore_changes = [data["postfix-accounts.cf"]]
  }
}

# resource "kubernetes_config_map" "user_patches" {
#   metadata {
#     name      = "user-patches"
#    namespace = kubernetes_namespace.mailserver.metadata[0].name
#     labels = {
#       "app" = "mailserver"
#     }
#   }

#   data = {
#     user_patches = <<EOF
# #!/bin/bash
# cp -f /tmp/dovecot.key /etc/dovecot/ssl/dovecot.key
# cp -f /tmp/dovecot.crt /etc/dovecot/ssl/dovecot.pem 
#     EOF
#   }
# }

resource "kubernetes_secret" "opendkim_key" {
  metadata {
    name      = "mailserver.opendkim.key"
    namespace = kubernetes_namespace.mailserver.metadata[0].name
    labels = {
      "app" = "mailserver"
    }
  }
  type = "Opaque"
  data = {
    "viktorbarzin.me-mail.key" = var.opendkim_key
  }
}


resource "kubernetes_persistent_volume_claim" "data_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "mailserver-data-encrypted"
    namespace = kubernetes_namespace.mailserver.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        storage = "2Gi"
      }
    }
  }
}

resource "kubernetes_deployment" "mailserver" {
  metadata {
    name      = "mailserver"
    namespace = kubernetes_namespace.mailserver.metadata[0].name
    labels = {
      "app" = "mailserver"
      tier  = var.tier
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = "1"
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        "app" = "mailserver"
      }
    }
    template {
      metadata {
        annotations = {
          # "diun.enable" = "true"
        }
        labels = {
          "app"  = "mailserver"
          "role" = "mail"
        }
      }
      spec {
        container {
          name              = "docker-mailserver"
          image             = "docker.io/mailserver/docker-mailserver:15.0.0"
          image_pull_policy = "IfNotPresent"
          security_context {
            capabilities {
              add = ["NET_ADMIN"]
            }
          }

          lifecycle {
            post_start {
              exec {
                command = [
                  "postmap",
                  "/etc/postfix/sasl/passwd"
                  # "/bin/sh",
                  # "-c",
                  # "cp -f /tmp/user-patches.sh /tmp/docker-mailserver/user-patches.sh && chown root:root /var/log/mail && chmod 755 /var/log/mail",
                ]
              }
            }
          }

          volume_mount {
            name       = "config-tls"
            mount_path = "/tmp/ssl/tls.key"
            sub_path   = "tls.key"
            read_only  = true
          }
          volume_mount {
            name       = "config-tls"
            mount_path = "/tmp/ssl/tls.crt"
            sub_path   = "tls.crt"
            read_only  = true
          }
          volume_mount {
            name       = "config"
            mount_path = "/tmp/docker-mailserver/postfix-accounts.cf"
            sub_path   = "postfix-accounts.cf"
            read_only  = true
          }
          volume_mount {
            name       = "config"
            mount_path = "/tmp/docker-mailserver/postfix-main.cf"
            sub_path   = "postfix-main.cf"
            read_only  = true
          }
          volume_mount {
            name       = "config"
            mount_path = "/tmp/docker-mailserver/postfix-virtual.cf"
            sub_path   = "postfix-virtual.cf"
            read_only  = true
          }
          volume_mount {
            name       = "config"
            mount_path = "/tmp/docker-mailserver/fetchmail.cf"
            sub_path   = "fetchmail.cf"
            read_only  = true
          }
          volume_mount {
            name       = "config"
            mount_path = "/tmp/docker-mailserver/dovecot.cf"
            sub_path   = "dovecot.cf"
            read_only  = true
          }
          # volume_mount {
          #   name       = "user-patches"
          #   mount_path = "/tmp/user-patches.sh"
          #   sub_path   = "user-patches.sh"
          #   read_only  = true
          # }
          volume_mount {
            name       = "config"
            mount_path = "/tmp/docker-mailserver/opendkim/SigningTable"
            sub_path   = "SigningTable"
            read_only  = true
          }
          volume_mount {
            name       = "config"
            mount_path = "/tmp/docker-mailserver/opendkim/KeyTable"
            sub_path   = "KeyTable"
            read_only  = true
          }
          volume_mount {
            name       = "config"
            mount_path = "/tmp/docker-mailserver/opendkim/TrustedHosts"
            sub_path   = "TrustedHosts"
            read_only  = true
          }
          volume_mount {
            name       = "opendkim-key"
            mount_path = "/tmp/docker-mailserver/opendkim/keys"
            read_only  = true
          }
          volume_mount {
            name       = "opendkim-key"
            mount_path = "/tmp/docker-mailserver/rspamd/dkim/viktorbarzin.me/mail.private"
            sub_path   = "viktorbarzin.me-mail.key"
            read_only  = true
          }
          volume_mount {
            name       = "config"
            mount_path = "/tmp/docker-mailserver/rspamd/override.d/dkim_signing.conf"
            sub_path   = "dkim_signing.conf"
            read_only  = true
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/mail"
            sub_path   = "data"
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/mail-state"
            sub_path   = "state"
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/log/mail"
            sub_path   = "log"
          }
          volume_mount {
            name       = "var-run-dovecot"
            mount_path = "/var/run/dovecot"
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/postfix/sasl/passwd"
            sub_path   = "sasl_passwd"
            read_only  = true
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/fail2ban/fail2ban.local"
            sub_path   = "fail2ban_conf"
            read_only  = true
          }
          port {
            name           = "smtp"
            container_port = 25
            protocol       = "TCP"
          }
          port {
            name           = "smtp-secure"
            container_port = 465
            protocol       = "TCP"
          }
          port {
            name           = "smtp-auth"
            container_port = 587
            protocol       = "TCP"
          }
          port {
            name           = "imap-secure"
            container_port = 993
            protocol       = "TCP"
          }
          env_from {
            config_map_ref {
              name = "mailserver.env.config"
            }
          }

          resources {
            requests = {
              cpu    = "25m"
              memory = "512Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }

          readiness_probe {
            tcp_socket {
              port = 25
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          liveness_probe {
            tcp_socket {
              port = 993
            }
            initial_delay_seconds = 60
            period_seconds        = 60
            timeout_seconds       = 15
          }

        }

        container {
          name  = "dovecot-exporter"
          image = "viktorbarzin/dovecot_exporter:latest"
          command = [
            "/dovecot_exporter/exporter",
            "--dovecot.socket-path=/var/run/dovecot/stats-reader"
          ]
          image_pull_policy = "IfNotPresent"
          port {
            name           = "dovecotexporter"
            container_port = 9166
            protocol       = "TCP"
          }
          volume_mount {
            name       = "var-run-dovecot"
            mount_path = "/var/run/dovecot"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "32Mi"
            }
          }
        }

        volume {
          name = "config"
          config_map {
            name = "mailserver.config"
          }
        }
        volume {
          name = "config-tls"
          secret {
            secret_name = var.tls_secret_name
          }
        }
        volume {
          name = "opendkim-key"
          secret {
            secret_name = "mailserver.opendkim.key"
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_encrypted.metadata[0].name
          }
          # iscsi {
          #   target_portal = "iscsi.viktorbarzin.lan:3260"
          #   iqn           = "iqn.2020-12.lan.viktorbarzin:storage:mailserver"
          #   lun           = 0
          #   fs_type       = "ext4"
          # }
        }
        # volume {
        #   name = "user-patches"
        #   config_map {
        #     name = "user-patches"
        #   }
        # }
        volume {
          name = "var-run-dovecot"
          empty_dir {}
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

resource "kubernetes_service" "mailserver" {
  metadata {
    name      = "mailserver"
    namespace = kubernetes_namespace.mailserver.metadata[0].name

    labels = {
      app = "mailserver"
    }

    annotations = {
      "metallb.io/loadBalancerIPs" = "10.0.20.202"
    }
  }

  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Local"
    selector = {
      app = "mailserver"
    }

    port {
      name        = "smtp"
      protocol    = "TCP"
      port        = 25
      target_port = "smtp"
    }

    port {
      name        = "smtp-secure"
      protocol    = "TCP"
      port        = 465
      target_port = "smtp-secure"
    }

    port {
      name        = "smtp-auth"
      protocol    = "TCP"
      port        = 587
      target_port = "smtp-auth"
    }

    port {
      name        = "imap-secure"
      protocol    = "TCP"
      port        = 993
      target_port = "imap-secure"
    }

    port {
      name        = "dovecot-metrics"
      protocol    = "TCP"
      port        = 9166
      target_port = 9166
    }
  }
}

# =============================================================================
# E2E Email Roundtrip Monitor
# Sends test email via Brevo API, verifies delivery via IMAP, pushes metrics
# =============================================================================
# ExternalSecret syncing the probe's Vault inputs into a K8s Secret, so
# `kubectl describe cronjob email-roundtrip-monitor` no longer leaks the
# Brevo API key and IMAP password via `env[].value`. The two upstream Vault
# entries both wrap the effective secret:
#   - secret/viktor  → brevo_api_key     = base64(JSON({"api_key": "..."}))
#   - secret/platform → mailserver_accounts = JSON({"spam@viktorbarzin.me": "<pw>", ...})
# ESO's `target.template` (engineVersion v2) runs sprig on the raw remote
# values so the rendered K8s Secret contains ONLY the two env vars the probe
# actually needs, under the exact keys `BREVO_API_KEY` and
# `EMAIL_MONITOR_IMAP_PASSWORD` so the CronJob can consume them via a single
# `env_from { secret_ref {} }` block.
resource "kubernetes_manifest" "email_roundtrip_monitor_secrets" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "mailserver-probe-secrets"
      namespace = kubernetes_namespace.mailserver.metadata[0].name
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "mailserver-probe-secrets"
        template = {
          engineVersion = "v2"
          data = {
            BREVO_API_KEY               = "{{ .brevo_api_key_wrapped | b64dec | fromJson | dig \"api_key\" \"\" }}"
            EMAIL_MONITOR_IMAP_PASSWORD = "{{ .mailserver_accounts | fromJson | dig \"spam@viktorbarzin.me\" \"\" }}"
          }
        }
      }
      data = [
        {
          secretKey = "brevo_api_key_wrapped"
          remoteRef = {
            key      = "viktor"
            property = "brevo_api_key"
          }
        },
        {
          secretKey = "mailserver_accounts"
          remoteRef = {
            key      = "platform"
            property = "mailserver_accounts"
          }
        },
      ]
    }
  }
}

resource "kubernetes_cron_job_v1" "email_roundtrip_monitor" {
  metadata {
    name      = "email-roundtrip-monitor"
    namespace = kubernetes_namespace.mailserver.metadata[0].name
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 3
    schedule                      = "*/20 * * * *"
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 300
        template {
          metadata {}
          spec {
            container {
              name  = "email-roundtrip"
              image = "docker.io/library/python:3.12-alpine"
              command = ["/bin/sh", "-c", <<-EOT
                pip install --quiet --disable-pip-version-check requests && python3 -c '
import requests, imaplib, email, time, os, uuid, sys, ssl, json

BREVO_API_KEY = os.environ["BREVO_API_KEY"]
IMAP_USER = "spam@viktorbarzin.me"
IMAP_PASS = os.environ["EMAIL_MONITOR_IMAP_PASSWORD"]
IMAP_HOST = "mailserver.mailserver.svc.cluster.local"
PUSHGATEWAY = "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/email-roundtrip-monitor"
DOMAIN = "viktorbarzin.me"

marker = f"e2e-probe-{uuid.uuid4().hex[:12]}"
subject = f"[E2E Monitor] {marker}"
start = time.time()
success = 0
duration = 0

try:
    # Step 1: Send via Brevo Transactional Email API to smoke-test@ (hits catch-all -> spam@)
    resp = requests.post(
        "https://api.brevo.com/v3/smtp/email",
        headers={
            "api-key": BREVO_API_KEY,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        json={
            "sender": {"name": "Monitoring", "email": f"monitoring@{DOMAIN}"},
            "to": [{"email": f"smoke-test@{DOMAIN}"}],
            "subject": subject,
            "textContent": f"E2E email monitoring probe {marker}. Auto-generated, will be deleted.",
        },
        timeout=30,
    )
    resp.raise_for_status()
    print(f"Sent test email via Brevo: {resp.status_code} marker={marker}")

    # Step 2: Wait for delivery, retry IMAP up to 5 min (15 x 20s)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    found = False
    for attempt in range(15):
        time.sleep(20)
        try:
            imap = imaplib.IMAP4_SSL(IMAP_HOST, 993, ssl_context=ctx, timeout=10)
            imap.login(IMAP_USER, IMAP_PASS)
            imap.select("INBOX")
            _, msg_ids = imap.search(None, "SUBJECT", marker)
            if msg_ids[0]:
                found = True
                print(f"Found test email after {attempt+1} attempts")
            # Delete ALL e2e probe emails (current + any leftovers from previous runs)
            if found:
                try:
                    _, all_e2e = imap.search(None, "SUBJECT", "e2e-probe")
                    if all_e2e[0]:
                        e2e_ids = all_e2e[0].split()
                        for mid in e2e_ids:
                            imap.store(mid, "+FLAGS", "(\\Deleted)")
                        imap.expunge()
                        print(f"Deleted {len(e2e_ids)} e2e probe email(s)")
                except Exception as de:
                    print(f"Delete failed (non-critical): {de}")
            imap.logout()
            if found:
                break
        except Exception as e:
            print(f"IMAP attempt {attempt+1} failed: {e}")

    duration = time.time() - start
    if found:
        success = 1
        print(f"Round-trip SUCCESS in {duration:.1f}s")
    else:
        print(f"Round-trip FAILED - email not found after {duration:.1f}s")

except Exception as e:
    duration = time.time() - start
    print(f"ERROR: {e}")

# Push metrics to Pushgateway
metrics = f"""# HELP email_roundtrip_success Whether the last e2e email probe succeeded
# TYPE email_roundtrip_success gauge
email_roundtrip_success {success}
# HELP email_roundtrip_duration_seconds Duration of the last e2e email probe
# TYPE email_roundtrip_duration_seconds gauge
email_roundtrip_duration_seconds {duration:.2f}
# HELP email_roundtrip_last_success_timestamp Unix timestamp of last successful probe
# TYPE email_roundtrip_last_success_timestamp gauge
email_roundtrip_last_success_timestamp {int(time.time()) if success else 0}
"""
UPTIME_KUMA_URL = "http://uptime-kuma.uptime-kuma.svc.cluster.local/api/push/hLtyRKgeZO?status=up&msg=OK&ping=" + str(int(duration))

def push_with_retry(label, func, url):
    # 3 attempts with exponential backoff (1s, 2s, 4s). Returns True on success, False otherwise.
    # Final failure logs ERROR with URL + status code (or exception) so the pod log surfaces the drop.
    last_status = None
    last_exc = None
    for attempt in range(3):
        try:
            resp = func()
            last_status = resp.status_code
            if 200 <= resp.status_code < 300:
                print(f"Pushed to {label} (attempt {attempt+1}, status {resp.status_code})")
                return True
            last_exc = None
        except Exception as e:
            last_exc = e
            last_status = None
        if attempt < 2:
            time.sleep(2 ** attempt)
    detail = f"status={last_status}" if last_exc is None else f"exception={last_exc!r}"
    print(f"ERROR: Failed to push to {label} after 3 attempts: url={url} {detail}", file=sys.stderr)
    return False

pushgateway_ok = push_with_retry(
    "Pushgateway",
    lambda: requests.put(PUSHGATEWAY, data=metrics, timeout=10),
    PUSHGATEWAY,
)

# Push to Uptime Kuma on success
uptime_kuma_ok = True
if success:
    uptime_kuma_ok = push_with_retry(
        "Uptime Kuma",
        lambda: requests.get(UPTIME_KUMA_URL, timeout=10),
        UPTIME_KUMA_URL,
    )

# Exit non-zero when the round-trip itself failed, OR when BOTH push endpoints
# failed after all retries (only possible on the success path — on failure we
# only attempt Pushgateway, and the round-trip failure already dominates exit).
both_pushes_failed = success and (not pushgateway_ok) and (not uptime_kuma_ok)
sys.exit(0 if (success and not both_pushes_failed) else 1)
'
              EOT
              ]
              env_from {
                secret_ref {
                  name = "mailserver-probe-secrets"
                }
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
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}

# =============================================================================
# Mailserver Backup — Daily rsync of maildirs, mail-state, and log
# Pattern mirrors vaultwarden-backup (pod_affinity for RWO co-location, /backup
# write to NFS, Pushgateway metrics). Runs at 03:00 to avoid overlap with
# mysql-backup (00:30), vaultwarden-backup (*/6h), email-roundtrip (*/20m).
# Total loss of this PVC = all maildirs + DKIM keys gone; regenerating DKIM
# requires DNS changes, hence backup is critical.
# =============================================================================
module "nfs_mailserver_backup_host" {
  source     = "../../../../modules/kubernetes/nfs_volume"
  name       = "mailserver-backup-host"
  namespace  = kubernetes_namespace.mailserver.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/srv/nfs/mailserver-backup"
}

resource "kubernetes_cron_job_v1" "mailserver-backup" {
  metadata {
    name      = "mailserver-backup"
    namespace = kubernetes_namespace.mailserver.metadata[0].name
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 5
    schedule                      = "0 3 * * *"
    starting_deadline_seconds     = 10
    successful_jobs_history_limit = 10
    job_template {
      metadata {}
      spec {
        backoff_limit              = 3
        ttl_seconds_after_finished = 10
        template {
          metadata {}
          spec {
            # RWO co-location: backup pod must land on the same node as the
            # mailserver pod because mailserver-data-encrypted is ReadWriteOnce.
            affinity {
              pod_affinity {
                required_during_scheduling_ignored_during_execution {
                  label_selector {
                    match_labels = {
                      app = "mailserver"
                    }
                  }
                  topology_key = "kubernetes.io/hostname"
                }
              }
            }
            container {
              name  = "mailserver-backup"
              image = "docker.io/library/alpine"
              command = ["/bin/sh", "-c", <<-EOT
                set -euxo pipefail
                apk add --no-cache rsync
                _t0=$(date +%s)
                _rb0=$(awk '/^read_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)
                _wb0=$(awk '/^write_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)

                week=$(date +"%Y-%W")
                prev_week=$(date -d "-7 days" +"%Y-%W" 2>/dev/null || echo "")
                dst=/backup/$week
                mkdir -p "$dst"

                # Use --link-dest against previous week for space-efficient
                # incrementals (unchanged files are hardlinked, not re-copied).
                link_dest_arg=""
                if [ -n "$prev_week" ] && [ -d "/backup/$prev_week" ]; then
                  link_dest_arg="--link-dest=/backup/$prev_week"
                fi

                # Mailserver data layout (from deployment subPath mounts):
                #   /var/mail       -> data (maildirs)
                #   /var/mail-state -> state (postfix, dovecot, rspamd, dkim keys)
                #   /var/log/mail   -> log  (mail logs)
                for src in /var/mail /var/mail-state /var/log/mail; do
                  [ -d "$src" ] || { echo "SKIP missing $src"; continue; }
                  name=$(basename "$src")
                  rsync -aH --delete $link_dest_arg "$src/" "$dst/$name/"
                done

                # Rotate — keep 8 weekly snapshots (~2 months)
                find /backup -maxdepth 1 -mindepth 1 -type d -regex '.*/[0-9]+-[0-9]+$' | sort | head -n -8 | xargs -r rm -rf

                _dur=$(($(date +%s) - _t0))
                _rb1=$(awk '/^read_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)
                _wb1=$(awk '/^write_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)
                echo "=== Backup IO Stats ==="
                echo "duration: $${_dur}s"
                echo "read:    $(( (_rb1 - _rb0) / 1048576 )) MiB"
                echo "written: $(( (_wb1 - _wb0) / 1048576 )) MiB"
                echo "output:  $(du -sh "$dst" | awk '{print $1}')"

                _out_bytes=$(du -sb "$dst" | awk '{print $1}')
                wget -qO- --post-data "backup_duration_seconds $${_dur}
                backup_read_bytes $(( _rb1 - _rb0 ))
                backup_written_bytes $(( _wb1 - _wb0 ))
                backup_output_bytes $${_out_bytes}
                backup_last_success_timestamp $(date +%s)
                " "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/mailserver-backup" || true
              EOT
              ]
              volume_mount {
                name       = "data"
                mount_path = "/var/mail"
                sub_path   = "data"
                read_only  = true
              }
              volume_mount {
                name       = "data"
                mount_path = "/var/mail-state"
                sub_path   = "state"
                read_only  = true
              }
              volume_mount {
                name       = "data"
                mount_path = "/var/log/mail"
                sub_path   = "log"
                read_only  = true
              }
              volume_mount {
                name       = "backup"
                mount_path = "/backup"
              }
            }
            volume {
              name = "data"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.data_encrypted.metadata[0].name
                read_only  = true
              }
            }
            volume {
              name = "backup"
              persistent_volume_claim {
                claim_name = module.nfs_mailserver_backup_host.claim_name
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
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}

# =============================================================================
# Roundcube Backup — Daily rsync of html + enigma PVCs to NFS
# Roundcube uses two encrypted RWO PVCs (see roundcubemail.tf):
#   - roundcubemail-html-encrypted   → /var/www/html (plugins, user sessions, skin overrides)
#   - roundcubemail-enigma-encrypted → /var/roundcube/enigma (user-uploaded PGP keys)
# Losing either one = users lose plugin state + have to re-import PGP keys.
# Mirrors the mailserver-backup pattern but:
#   - pod_affinity targets app=roundcubemail (both PVCs attach to the
#     Roundcube pod, not mailserver)
#   - schedule offset by +10m (03:10) so two NFS-writers don't overlap
#   - writes to /srv/nfs/roundcube-backup/<YYYY-WW>/{html,enigma}/
# =============================================================================
module "nfs_roundcube_backup_host" {
  source     = "../../../../modules/kubernetes/nfs_volume"
  name       = "roundcube-backup-host"
  namespace  = kubernetes_namespace.mailserver.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/srv/nfs/roundcube-backup"
}

resource "kubernetes_cron_job_v1" "roundcube-backup" {
  metadata {
    name      = "roundcube-backup"
    namespace = kubernetes_namespace.mailserver.metadata[0].name
  }
  spec {
    concurrency_policy        = "Replace"
    failed_jobs_history_limit = 5
    # +10 min offset vs mailserver-backup (03:00) to avoid NFS contention.
    schedule                      = "10 3 * * *"
    starting_deadline_seconds     = 10
    successful_jobs_history_limit = 10
    job_template {
      metadata {}
      spec {
        backoff_limit              = 3
        ttl_seconds_after_finished = 10
        template {
          metadata {}
          spec {
            # RWO co-location: Roundcube PVCs are ReadWriteOnce; the backup
            # pod must land on the same node as the Roundcube pod (single
            # replica, Recreate strategy — see roundcubemail.tf).
            affinity {
              pod_affinity {
                required_during_scheduling_ignored_during_execution {
                  label_selector {
                    match_labels = {
                      app = "roundcubemail"
                    }
                  }
                  topology_key = "kubernetes.io/hostname"
                }
              }
            }
            container {
              name  = "roundcube-backup"
              image = "docker.io/library/alpine"
              command = ["/bin/sh", "-c", <<-EOT
                set -euxo pipefail
                apk add --no-cache rsync
                _t0=$(date +%s)
                _rb0=$(awk '/^read_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)
                _wb0=$(awk '/^write_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)

                week=$(date +"%Y-%W")
                prev_week=$(date -d "-7 days" +"%Y-%W" 2>/dev/null || echo "")
                dst=/backup/$week
                mkdir -p "$dst"

                # Use --link-dest against previous week for space-efficient
                # incrementals (unchanged files are hardlinked, not re-copied).
                link_dest_arg=""
                if [ -n "$prev_week" ] && [ -d "/backup/$prev_week" ]; then
                  link_dest_arg="--link-dest=/backup/$prev_week"
                fi

                # Roundcube data layout (from deployment volume mounts in roundcubemail.tf):
                #   /src/html   -> roundcubemail-html-encrypted   (html PVC)
                #   /src/enigma -> roundcubemail-enigma-encrypted (enigma PVC, PGP keys)
                for src in /src/html /src/enigma; do
                  [ -d "$src" ] || { echo "SKIP missing $src"; continue; }
                  name=$(basename "$src")
                  rsync -aH --delete $link_dest_arg "$src/" "$dst/$name/"
                done

                # Rotate — keep 8 weekly snapshots (~2 months)
                find /backup -maxdepth 1 -mindepth 1 -type d -regex '.*/[0-9]+-[0-9]+$' | sort | head -n -8 | xargs -r rm -rf

                _dur=$(($(date +%s) - _t0))
                _rb1=$(awk '/^read_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)
                _wb1=$(awk '/^write_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0)
                echo "=== Backup IO Stats ==="
                echo "duration: $${_dur}s"
                echo "read:    $(( (_rb1 - _rb0) / 1048576 )) MiB"
                echo "written: $(( (_wb1 - _wb0) / 1048576 )) MiB"
                echo "output:  $(du -sh "$dst" | awk '{print $1}')"

                _out_bytes=$(du -sb "$dst" | awk '{print $1}')
                wget -qO- --post-data "backup_duration_seconds $${_dur}
                backup_read_bytes $(( _rb1 - _rb0 ))
                backup_written_bytes $(( _wb1 - _wb0 ))
                backup_output_bytes $${_out_bytes}
                backup_last_success_timestamp $(date +%s)
                " "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/roundcube-backup" || true
              EOT
              ]
              volume_mount {
                name       = "html"
                mount_path = "/src/html"
                read_only  = true
              }
              volume_mount {
                name       = "enigma"
                mount_path = "/src/enigma"
                read_only  = true
              }
              volume_mount {
                name       = "backup"
                mount_path = "/backup"
              }
            }
            volume {
              name = "html"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.roundcube_html_encrypted.metadata[0].name
                read_only  = true
              }
            }
            volume {
              name = "enigma"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.roundcube_enigma_encrypted.metadata[0].name
                read_only  = true
              }
            }
            volume {
              name = "backup"
              persistent_volume_claim {
                claim_name = module.nfs_roundcube_backup_host.claim_name
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
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}


# =============================================================================
# Spam mailbox targeted retention (code-oy4)
#
# The @viktorbarzin.me catch-all routes to spam@viktorbarzin.me. Unbounded
# growth (~43 MiB baseline on 2026-04-18, 519 messages, top sender
# tldrnewsletter.com = 138 msgs / 8.2 MiB) makes it painful to triage.
# Profile (2026-04-18):
#   - 502/519 messages older than 14 days (97 %)
#   - 342/519 carry List-Unsubscribe:     (66 %)
#   -  21/519 carry Precedence: bulk      ( 4 %)
#   - 177/519 carry neither marker (= human-ish, 34 %)
#
# Strategy (user-signed-off 2026-04-18, do NOT blind-age-expunge):
#   - Messages older than 14 days carrying List-Unsubscribe OR
#     Precedence: bulk|list|junk OR Auto-Submitted: auto-* -> DELETE
#   - Messages older than 90 days with no automated-sender marker
#     -> DELETE (long-tail human forwards)
#   - Everything else -> KEEP
#
# Implementation: kubectl exec into the mailserver pod because the
# Maildir lives on a RWO encrypted PVC; a sibling CronJob would fail to
# attach the volume while the mailserver pod holds it. Pattern mirrors
# the `nextcloud-watchdog` in stacks/nextcloud/main.tf.
# =============================================================================
resource "kubernetes_service_account" "spam_retention" {
  metadata {
    name      = "spam-retention"
    namespace = kubernetes_namespace.mailserver.metadata[0].name
  }
}

resource "kubernetes_role" "spam_retention" {
  metadata {
    name      = "spam-retention"
    namespace = kubernetes_namespace.mailserver.metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["list", "get"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create"]
  }
}

resource "kubernetes_role_binding" "spam_retention" {
  metadata {
    name      = "spam-retention"
    namespace = kubernetes_namespace.mailserver.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.spam_retention.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.spam_retention.metadata[0].name
    namespace = kubernetes_namespace.mailserver.metadata[0].name
  }
}

resource "kubernetes_cron_job_v1" "spam_retention" {
  metadata {
    name      = "spam-retention"
    namespace = kubernetes_namespace.mailserver.metadata[0].name
  }
  spec {
    schedule                      = "17 */4 * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 2
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 300
    job_template {
      metadata {}
      spec {
        active_deadline_seconds    = 600
        backoff_limit              = 1
        ttl_seconds_after_finished = 600
        template {
          metadata {}
          spec {
            service_account_name = kubernetes_service_account.spam_retention.metadata[0].name
            restart_policy       = "Never"
            container {
              name  = "spam-retention"
              image = "bitnami/kubectl:latest"
              command = ["/bin/bash", "-c", <<-EOF
                set -euo pipefail

                POD=$(kubectl -n mailserver get pods -l app=mailserver -o jsonpath='{.items[0].metadata.name}')
                if [ -z "$POD" ]; then
                  echo "ERROR: no mailserver pod found" >&2
                  exit 1
                fi
                echo "Targeting pod $POD"

                # Stream the retention script to python3 inside the mailserver
                # container via stdin. Keeping the logic in Python avoids the
                # POSIX-sh/awk fragility around stat(1) differences and header
                # matching.
                kubectl -n mailserver exec -i "$POD" -c docker-mailserver -- python3 - <<'PYEOF'
                import os
                import re
                import sys
                import time

                SPAM = "/var/mail/viktorbarzin.me/spam/cur"
                # Retention thresholds, in days, one per rule.
                AUTOMATED_MAX_AGE_DAYS = 14
                HUMAN_MAX_AGE_DAYS     = 90
                HEADER_SCAN_BYTES      = 65536

                AUTO_PATTERNS = (
                    re.compile(rb"^list-unsubscribe:", re.IGNORECASE),
                    re.compile(rb"^precedence:\s*(bulk|list|junk)", re.IGNORECASE),
                    re.compile(rb"^auto-submitted:\s*auto-", re.IGNORECASE),
                )

                def is_automated(path):
                    try:
                        with open(path, "rb") as fh:
                            head = fh.read(HEADER_SCAN_BYTES)
                    except OSError:
                        return False
                    hdr, _, _ = head.partition(b"\r\n\r\n")
                    if hdr == head:
                        hdr, _, _ = head.partition(b"\n\n")
                    for line in hdr.splitlines():
                        for pat in AUTO_PATTERNS:
                            if pat.search(line):
                                return True
                    return False

                if not os.path.isdir(SPAM):
                    print(f"SKIP: {SPAM} does not exist")
                    sys.exit(0)

                now = time.time()
                scanned = auto_deleted = human_deleted = kept = errors = 0

                for entry in sorted(os.listdir(SPAM)):
                    path = os.path.join(SPAM, entry)
                    try:
                        st = os.stat(path)
                    except OSError:
                        errors += 1
                        continue
                    if not os.path.isfile(path):
                        continue
                    scanned += 1
                    age_days = (now - st.st_mtime) / 86400
                    automated = is_automated(path)

                    if automated and age_days > AUTOMATED_MAX_AGE_DAYS:
                        try:
                            os.unlink(path)
                            auto_deleted += 1
                        except OSError:
                            errors += 1
                        continue
                    if (not automated) and age_days > HUMAN_MAX_AGE_DAYS:
                        try:
                            os.unlink(path)
                            human_deleted += 1
                        except OSError:
                            errors += 1
                        continue
                    kept += 1

                # Metric lines (Pushgateway-compatible format). The parent
                # kubectl wrapper logs them for now; Pushgateway integration
                # is a follow-up.
                print(f"spam_retention_scanned_total {scanned}")
                print(f"spam_retention_auto_deleted_total {auto_deleted}")
                print(f"spam_retention_human_deleted_total {human_deleted}")
                print(f"spam_retention_kept_total {kept}")
                print(f"spam_retention_errors_total {errors}")

                sys.exit(1 if errors else 0)
                PYEOF

                # Refresh Dovecot index so IMAP sees the deletions immediately.
                kubectl -n mailserver exec "$POD" -c docker-mailserver -- \
                  doveadm force-resync -u spam@viktorbarzin.me INBOX/spam || true

                echo "Retention pass complete"
              EOF
              ]
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
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}
