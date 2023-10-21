variable "tls_secret_name" {}

resource "kubernetes_namespace" "technitium" {
  metadata {
    name = "technitium"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "technitium"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "technitium" {
  # resource "kubernetes_daemonset" "technitium" {
  metadata {
    name      = "technitium"
    namespace = "technitium"
    labels = {
      app = "technitium"
    }
  }
  spec {
    strategy {
      type = "Recreate"
    }
    # replicas = 1
    selector {
      match_labels = {
        app = "technitium"
      }
    }
    template {
      metadata {
        labels = {
          app = "technitium"
        }
      }
      spec {
        node_name = "k8s-node1" # Horrible hack but only way I found to preserve client ip
        container {
          image = "technitium/dns-server:latest"
          name  = "technitium"
          resources {
            # limits = {
            #   cpu    = "1"
            #   memory = "1Gi"
            # }
            # requests = {
            #   cpu    = "1"
            #   memory = "1Gi"
            # }
          }
          port {
            container_port = 5380
          }
          port {
            container_port = 53
          }
          port {
            container_port = 80
          }
          volume_mount {
            mount_path = "/etc/dns"
            name       = "nfs-config"
          }
          volume_mount {
            mount_path = "/etc/tls/"
            name       = "tls-cert"
          }
        }
        volume {
          name = "nfs-config"
          nfs {
            path   = "/mnt/main/technitium"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "tls-cert"
          secret {
            secret_name = var.tls_secret_name
          }
        }
      }
    }
  }
}


resource "kubernetes_service" "technitium-web" {
  metadata {
    name      = "technitium-web"
    namespace = "technitium"
    labels = {
      "app" = "technitium"
    }
    # annotations = {
    #   "metallb.universe.tf/allow-shared-ip" : "shared"
    # }
  }

  spec {
    # type                    = "LoadBalancer"
    # external_traffic_policy = "Cluster"
    selector = {
      app = "technitium"
    }
    port {
      name     = "technitium-dns"
      port     = "5380"
      protocol = "TCP"
    }
    port {
      name     = "technitium-doh"
      port     = "80"
      protocol = "TCP"
    }
  }
}

resource "kubernetes_service" "technitium-dns" {
  metadata {
    name      = "technitium-dns"
    namespace = "technitium"
    labels = {
      "app" = "technitium"
    }
    annotations = {
      "metallb.universe.tf/allow-shared-ip" : "shared"
    }
  }

  spec {
    # type = "LoadBalancer"
    # external_traffic_policy = "Cluster"
    type = "NodePort"
    port {
      name      = "technitium-dns"
      port      = 53
      node_port = 30053
      protocol  = "UDP"
    }
    external_traffic_policy = "Local"
    selector = {
      app = "technitium"

    }
  }
}

resource "kubernetes_ingress_v1" "technitium" {
  metadata {
    name      = "technitium-ingress"
    namespace = "technitium"
    annotations = {
      "kubernetes.io/ingress.class"                        = "nginx"
      "nginx.ingress.kubernetes.io/affinity"               = "cookie"
      "nginx.ingress.kubernetes.io/auth-tls-verify-client" = "on"
      "nginx.ingress.kubernetes.io/auth-tls-secret"        = "default/ca-secret"
    }
  }

  spec {
    tls {
      hosts       = ["technitium.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "technitium.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "technitium-web"
              port {
                number = 5380
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_ingress_v1" "technitium-doh" {
  metadata {
    name      = "technitium-doh-ingress"
    namespace = "technitium"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  spec {
    tls {
      hosts       = ["dns.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "dns.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "technitium-web"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}
