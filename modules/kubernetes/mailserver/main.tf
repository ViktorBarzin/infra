variable "tls_secret_name" {}
variable "mailserver_accounts" {}
variable "postfix_account_aliases" {}
variable "opendkim_key" {}

resource "kubernetes_namespace" "mailserver" {
  metadata {
    name = "mailserver"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "mailserver"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_config_map" "mailserver_env_config" {
  metadata {
    name      = "mailserver.env.config"
    namespace = "mailserver"
    labels = {
      app = "mailserver"
    }
  }

  data = {
    DMS_DEBUG           = "0"
    ENABLE_CLAMAV       = "0"
    ENABLE_FAIL2BAN     = "1"
    ENABLE_FETCHMAIL    = "0"
    ENABLE_POSTGREY     = "0"
    ENABLE_SPAMASSASSIN = "0"
    ENABLE_SRS          = "1"
    FETCHMAIL_POLL      = "120"
    ONE_DIR             = "1"
    OVERRIDE_HOSTNAME   = "mail.viktorbarzin.me"
    TLS_LEVEL           = "intermediate"
    SSL_TYPE            = "manual"
    SSL_CERT_PATH       = "/tmp/ssl/tls.crt"
    SSL_KEY_PATH        = "/tmp/ssl/tls.key"
  }
}

locals {
  postfix_accounts_cf = join("\n", [for user, pass in var.mailserver_accounts : "${user}|${bcrypt(pass, 6)}"])
  #   postfix_accounts_cf = join("\n", [for user, pass in var.mailserver_accounts : format("%s%s%s", user, "|{SHA512-CRYPT}$6$$", sha512(pass))])  # Does not work :/
}

resource "kubernetes_config_map" "mailserver_config" {
  metadata {
    name      = "mailserver.config"
    namespace = "mailserver"

    labels = {
      app = "mailserver"
    }
    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    # Actual mail settings
    "postfix-accounts.cf" = local.postfix_accounts_cf
    "postfix-main.cf"     = var.postfix_cf
    "postfix-virtual.cf"  = var.postfix_account_aliases

    KeyTable     = "mail._domainkey.viktorbarzin.me viktorbarzin.me:mail:/etc/opendkim/keys/viktorbarzin.me-mail.key\n"
    SigningTable = "*@viktorbarzin.me mail._domainkey.viktorbarzin.me\n"
    TrustedHosts = "127.0.0.1\nlocalhost\n"
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
#     namespace = "mailserver"
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
    namespace = "mailserver"
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
    namespace = "mailserver"
    labels = {
      "app" = "mailserver"
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
        labels = {
          "app"  = "mailserver"
          "role" = "mail"
          "tier" = "backend"
        }
      }
      spec {
        container {
          name              = "docker-mailserver"
          image             = "tvial/docker-mailserver:release-v7.2.0"
          image_pull_policy = "IfNotPresent"

          # lifecycle {
          #   post_start {
          #     exec {
          #       command = [
          #         "/bin/sh",
          #         "-c",
          #         "cp -f /tmp/user-patches.sh /tmp/docker-mailserver/user-patches.sh && chown root:root /var/log/mail && chmod 755 /var/log/mail",
          #       ]
          #     }
          #   }
          # }

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
            name           = "imap"
            container_port = 143
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
          iscsi {
            target_portal = "iscsi.viktorbarzin.lan:3260"
            iqn           = "iqn.2020-12.lan.viktorbarzin:storage:mailserver"
            lun           = 0
            fs_type       = "ext4"
          }
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
