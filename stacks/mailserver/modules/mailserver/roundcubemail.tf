variable "roundcube_db_password" {
  type      = string
  sensitive = true
}
variable "mysql_host" { type = string }

resource "kubernetes_config_map" "roundcubemail_config" {
  metadata {
    name      = "roundcubemail.config"
    namespace = "mailserver"

    labels = {
      app = "roundcubemail"
    }
    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    # Disable TLS peer verification for internal service name connections
    # The mailserver cert is issued for mail.viktorbarzin.me, not the k8s service name
    "custom.php" = <<-EOF
    <?php
      $config['imap_conn_options'] = [
        'ssl' => [
          'verify_peer' => false,
          'verify_peer_name' => false,
        ],
      ];
      $config['smtp_conn_options'] = [
        'ssl' => [
          'verify_peer' => false,
          'verify_peer_name' => false,
        ],
      ];
    ?>
    EOF
  }
}


resource "kubernetes_persistent_volume_claim" "roundcube_html_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "roundcubemail-html-encrypted"
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
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "roundcube_enigma_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "roundcubemail-enigma-encrypted"
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
          volume_mount {
            name       = "roundcube-config"
            mount_path = "/var/roundcube/config/custom.php"
            sub_path   = "custom.php"
          }
          env {
            name  = "ROUNDCUBEMAIL_DEFAULT_HOST"
            value = "ssl://mailserver" # internal k8s service name
          }
          env {
            name  = "ROUNDCUBEMAIL_DEFAULT_PORT"
            value = "993"
          }
          env {
            name  = "ROUNDCUBEMAIL_SMTP_SERVER"
            value = "tls://mailserver" # internal k8s service name
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

        volume {
          name = "roundcube-config"
          config_map {
            name = kubernetes_config_map.roundcubemail_config.metadata[0].name
          }
        }

        volume {
          name = "html"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.roundcube_html_encrypted.metadata[0].name
          }
        }
        volume {
          name = "enigma"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.roundcube_enigma_encrypted.metadata[0].name
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
  dns_type        = "non-proxied"
  namespace       = "mailserver"
  name            = "mail"
  service_name    = "roundcubemail"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Roundcube Mail"
    "gethomepage.dev/description"  = "Webmail client"
    "gethomepage.dev/icon"         = "roundcube.png"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}
