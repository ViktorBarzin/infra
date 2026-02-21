variable "tls_secret_name" {}
variable "tier" { type = string }
variable "mailserver_accounts" {}
variable "postfix_account_aliases" {}
variable "opendkim_key" {}
variable "sasl_passwd" {} # For sendgrid i.e relayhost

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
  source          = "../setup_tls_secret"
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
    ENABLE_SRS                             = "1"
    FETCHMAIL_POLL                         = "120"
    ONE_DIR                                = "1"
    OVERRIDE_HOSTNAME                      = "mail.viktorbarzin.me"
    POSTFIX_MESSAGE_SIZE_LIMIT             = 1024 * 1024 * 200 # 200 MB
    POSTFIX_REJECT_UNKNOWN_CLIENT_HOSTNAME = "1"
    # TLS_LEVEL                              = "intermediate"
    # DEFAULT_RELAY_HOST = "[smtp.sendgrid.net]:587"
    DEFAULT_RELAY_HOST = "[smtp.eu.mailgun.org]:587"
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
    fail2ban_conf = <<-EOF
    [DEFAULT]

    #logtarget = /var/log/fail2ban.log
    logtarget = SYSOUT
    EOF
  }
  # Password hashes are different each time and avoid changing secret constantly. 
  # Either 1.Create consistent hashes or 2.Find a way to ignore_changes on per password
  lifecycle {
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
          # volume_mount {
          #   name       = "config"
          #   mount_path = "/tmp/docker-mailserver/dovecot.cf"
          #   sub_path   = "dovecot.cf"
          #   read_only  = true
          # }
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
          nfs {
            path   = "/mnt/main/mailserver"
            server = "10.0.10.15"
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
      "metallb.universe.tf/allow-shared-ip" = "shared"
    }
  }

  spec {
    type = "LoadBalancer"
    # external_traffic_policy = "Cluster"
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
      name     = "roundcube"
      protocol = "TCP"
      port     = 80
    }
  }
}

