variable "roundcube_db_password" { type = string }

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


resource "kubernetes_deployment" "roundcubemail" {
  metadata {
    name      = "roundcubemail"
    namespace = "mailserver"
    labels = {
      "app" = "roundcubemail"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = "1"
    strategy {
      type = "RollingUpdate"
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
          image = "roundcube/roundcubemail:latest"
          volume_mount {
            name       = "imap-config"
            mount_path = "/var/roundcube/config/imap.php"
            sub_path   = "imap.php"
          }
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

          env {
            name  = "ROUNDCUBEMAIL_DB_TYPE"
            value = "mysql"
          }
          env {
            name  = "ROUNDCUBEMAIL_DB_HOST"
            value = "mysql.dbaas"
          }
          env {
            name  = "ROUNDCUBEMAIL_DB_USER"
            value = "roundcubemail"
          }
          env {
            name  = "ROUNDCUBEMAIL_DB_PASSWORD"
            value = var.roundcube_db_password
          }
          env {
            name  = "ROUNDCUBEMAIL_SMTP_DEBUG"
            value = "true"
          }
          env {
            name  = "ROUNDCUBEMAIL_DEBUG_LEVEL"
            value = "6"
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
        }

        volume {
          name = "imap-config"
          config_map {
            name = "roundcubemail.config"
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
  source          = "../ingress_factory"
  namespace       = "mailserver"
  name            = "mail"
  service_name    = "roundcubemail"
  tls_secret_name = var.tls_secret_name
}
