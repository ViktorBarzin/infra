variable "roundcube_db_password" {
  type      = string
  sensitive = true
}
variable "mysql_host" { type = string }

module "nfs_roundcube_html" {
  source     = "../../../../modules/kubernetes/nfs_volume"
  name       = "roundcubemail-html"
  namespace  = kubernetes_namespace.mailserver.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/roundcubemail/html"
}

module "nfs_roundcube_enigma" {
  source     = "../../../../modules/kubernetes/nfs_volume"
  name       = "roundcubemail-enigma"
  namespace  = kubernetes_namespace.mailserver.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/roundcubemail/enigma"
}

# If you want to override settings mount this in /var/roundcube/config
# more info in https://github.com/roundcube/roundcubemail-docker?tab=readme-ov-file
# resource "kubernetes_config_map" "roundcubemail_config" {
#   metadata {
#     name      = "roundcubemail.config"
#     namespace = "mailserver"

#     labels = {
#       app = "mailserver"
#     }
#     annotations = {
#       "reloader.stakater.com/match" = "true"
#     }
#   }

#   data = {
#     # if you want to override things see https://github.com/roundcube/roundcubemail/blob/master/config/defaults.inc.php
#     "imap.php" = <<-EOF
#     <?php
#       $config['imap_host'] = 'ssl://mail.viktorbarzin.me:993';
#     ?>
#     EOF
#   }
# }


resource "kubernetes_persistent_volume_claim" "roundcube_html_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "roundcubemail-html-proxmox"
    namespace = kubernetes_namespace.mailserver.metadata[0].name
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

resource "kubernetes_persistent_volume_claim" "roundcube_enigma_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "roundcubemail-enigma-proxmox"
    namespace = kubernetes_namespace.mailserver.metadata[0].name
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

resource "kubernetes_deployment" "roundcubemail" {
  metadata {
    name      = "roundcubemail"
    namespace = "mailserver"
    labels = {
      "app" = "roundcubemail"
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
        "app" = "roundcubemail"
      }
    }
    template {
      metadata {
        labels = {
          "app" = "roundcubemail"
        }
      }
      spec {
        container {
          name  = "roundcube"
          image = "roundcube/roundcubemail:1.6.13-apache"
          # Uncomment me to mount additional settings
          #   volume_mount {
          #     name       = "imap-config"
          #     mount_path = "/var/roundcube/config/imap.php"
          #     sub_path   = "imap.php"
          #   }
          env {
            name  = "ROUNDCUBEMAIL_DEFAULT_HOST"
            value = "ssl://mail.viktorbarzin.me" # tls cert must be valid!
          }
          env {
            name  = "ROUNDCUBEMAIL_DEFAULT_PORT"
            value = "993"
          }
          env {
            name  = "ROUNDCUBEMAIL_SMTP_SERVER"
            value = "tls://mail.viktorbarzin.me" # tls cert must be valid!
          }

          env {
            name  = "ROUNDCUBEMAIL_SMTP_PORT"
            value = 587
          }

          # DB Settings
          env {
            name  = "ROUNDCUBEMAIL_DB_TYPE"
            value = "mysql"
          }
          env {
            name  = "ROUNDCUBEMAIL_DB_HOST"
            value = var.mysql_host
          }
          env {
            name  = "ROUNDCUBEMAIL_DB_USER"
            value = "roundcubemail"
          }
          env {
            name  = "ROUNDCUBEMAIL_DB_PASSWORD"
            value = var.roundcube_db_password
          }
          # Plugins
          env {
            name  = "ROUNDCUBEMAIL_COMPOSER_PLUGINS"
            value = "mmvi/twofactor_webauthn,texxasrulez/persistent_login,dsoares/rcguard"
          }
          env {
            name  = "ROUNDCUBEMAIL_PLUGINS"
            value = "attachment_reminder,database_attachments,enigma,twofactor_webauthn,persistent_login,rcguard"
          }

          env {
            name  = "ROUNDCUBEMAIL_SMTP_DEBUG"
            value = "false"
          }
          env {
            name  = "ROUNDCUBEMAIL_DEBUG_LEVEL"
            value = "1"
          }
          env {
            name = "ROUNDCUBEMAIL_LOG_DRIVER"
            # value = "file"
            value = "syslog"
          }
          port {
            name           = "web"
            container_port = 80
            protocol       = "TCP"
          }
          volume_mount {
            name       = "html"
            mount_path = "/var/www/html"
          }
          volume_mount {
            name       = "enigma"
            mount_path = "/var/roundcube/enigma"
          }
          resources {
            requests = {
              cpu    = "25m"
              memory = "192Mi"
            }
            limits = {
              memory = "192Mi"
            }
          }
        }

        # volume {
        #   name = "imap-config"
        #   config_map {
        #     name = "roundcubemail.config"
        #   }
        # }

        volume {
          name = "html"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.roundcube_html_proxmox.metadata[0].name
          }
        }
        volume {
          name = "enigma"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.roundcube_enigma_proxmox.metadata[0].name
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

resource "kubernetes_service" "roundcubemail" {
  metadata {
    name      = "roundcubemail"
    namespace = "mailserver"

    labels = {
      app = "roundcubemail"
    }
  }

  spec {
    selector = {
      app = "roundcubemail"
    }

    port {
      name     = "roundcube"
      protocol = "TCP"
      port     = 80
    }
  }
}

module "ingress" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  namespace       = "mailserver"
  name            = "mail"
  service_name    = "roundcubemail"
  tls_secret_name = var.tls_secret_name
  rybbit_site_id  = "082f164faa7d"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Roundcube Mail"
    "gethomepage.dev/description"  = "Webmail client"
    "gethomepage.dev/icon"         = "roundcube.png"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}
