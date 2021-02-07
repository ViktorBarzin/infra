variable "tls_secret_name" {}
variable "tls_crt" {}
variable "tls_key" {}
variable "web_password" {}

resource "kubernetes_namespace" "pihole" {
  metadata {
    name = "pihole"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "pihole"
  tls_secret_name = var.tls_secret_name
  tls_crt         = var.tls_crt
  tls_key         = var.tls_key
}


resource "kubernetes_config_map" "external_conf" {
  metadata {
    name      = "external-conf"
    namespace = "pihole"

    labels = {
      app = "pihole"
    }
  }
  data = {
    "external.conf" = "$HTTP[\"host\"] == \"pihole.viktorbarzin.me\" {\n    server.document-root = \"/var/www/html/admin/\"\n}\n"
  }
}

resource "kubernetes_deployment" "pihole" {
  metadata {
    name      = "pihole"
    namespace = "pihole"
    labels = {
      app = "pihole"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "pihole"
      }
    }
    template {
      metadata {
        labels = {
          app = "pihole"
        }
      }
      spec {
        container {
          image = "pihole/pihole:latest"
          name  = "pihole"
          resources {
            limits = {
              cpu    = "1"
              memory = "1Gi"
            }
            requests = {
              cpu    = "1"
              memory = "1Gi"
            }
          }
          port {
            container_port = 80
          }
          env {
            name  = "DNS1"
            value = "10.0.20.200#5354" # bind
          }
          env {
            name  = "VIRTUAL_HOST"
            value = "pihole.viktorbarzin.me"
          }
          env {
            name  = "WEBPASSWORD"
            value = var.web_password
          }
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }
          volume_mount {
            name       = "external-conf"
            mount_path = "/tmp/external.conf"
            sub_path   = "external.conf"
          }
          volume_mount {
            name       = "pihole-local-etc-volume"
            mount_path = "/etc/pihole"
          }
          volume_mount {
            name       = "pihole-local-dnsmasq-volume"
            mount_path = "/etc/dnsmasq.d"
          }
        }
        volume {
          name = "external-conf"
          config_map {
            name = "external-conf"
          }
        }
        volume {
          name = "pihole-local-etc-volume"
          empty_dir {} # no hard dependencies on truenas which needs dns
        }
        volume {
          name = "pihole-local-dnsmasq-volume"
          empty_dir {} # no hard dependencies on truenas which needs dns
        }
      }
    }
  }
}

resource "kubernetes_service" "pihole-dns" {
  metadata {
    name      = "pihole-dns"
    namespace = "pihole"
    labels = {
      "app" = "pihole"
    }
    annotations = {
      "metallb.universe.tf/allow-shared-ip" : "shared"
    }
  }

  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Cluster"
    selector = {
      app = "pihole"
    }
    port {
      name     = "dns-udp"
      port     = "53"
      protocol = "UDP"
    }
  }
}

resource "kubernetes_service" "pihole-web" {
  metadata {
    name      = "pihole-web"
    namespace = "pihole"
    labels = {
      "app" = "pihole"
    }
    annotations = {
      "metallb.universe.tf/allow-shared-ip" : "shared"
    }
  }

  spec {
    selector = {
      app = "pihole"
    }
    port {
      name = "dns-web"
      port = "80"
    }
  }
}

resource "kubernetes_ingress" "pihole" {
  metadata {
    name      = "pihole-ingress"
    namespace = "pihole"
    annotations = {
      "kubernetes.io/ingress.class"                        = "nginx"
      "nginx.ingress.kubernetes.io/auth-tls-verify-client" = "on"
      "nginx.ingress.kubernetes.io/auth-tls-secret"        = "default/ca-secret"
    }
  }

  spec {
    tls {
      hosts       = ["pihole.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "pihole.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service_name = "pihole-web"
            service_port = "80"
          }
        }
      }
    }
  }
}
