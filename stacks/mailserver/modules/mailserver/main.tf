variable "tls_secret_name" {}
variable "tier" { type = string }
variable "mailserver_accounts" {}
variable "postfix_account_aliases" {}
variable "opendkim_key" {}
variable "sasl_passwd" {} # For sendgrid i.e relayhost
variable "nfs_server" { type = string }
variable "brevo_api_key" {
  type      = string
  sensitive = true
}
variable "email_monitor_imap_password" {
  type      = string
  sensitive = true
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
    "postfix-virtual.cf"  = format("%s%s", var.postfix_account_aliases, file("${path.module}/extra/aliases.txt"))

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

    # Step 2: Wait for delivery, retry IMAP up to 3 min
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    found = False
    for attempt in range(9):
        time.sleep(20)
        try:
            imap = imaplib.IMAP4_SSL(IMAP_HOST, 993, ssl_context=ctx)
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
try:
    requests.put(PUSHGATEWAY, data=metrics, timeout=10)
    print("Pushed metrics to Pushgateway")
except Exception as e:
    print(f"Failed to push metrics: {e}")

# Push to Uptime Kuma on success
if success:
    try:
        requests.get("http://uptime-kuma.uptime-kuma.svc.cluster.local/api/push/hLtyRKgeZO?status=up&msg=OK&ping=" + str(int(duration)), timeout=10)
        print("Pushed to Uptime Kuma")
    except Exception as e:
        print(f"Failed to push to Uptime Kuma: {e}")

sys.exit(0 if success else 1)
'
              EOT
              ]
              env {
                name  = "BREVO_API_KEY"
                value = var.brevo_api_key
              }
              env {
                name  = "EMAIL_MONITOR_IMAP_PASSWORD"
                value = var.email_monitor_imap_password
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
}

