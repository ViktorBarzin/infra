resource "kubernetes_namespace" "dnscrypt" {
  metadata {
    name = "dnscrypt"
  }
}

resource "kubernetes_config_map" "dnscrypt" {
  metadata {
    name      = "dnscrypt-proxy-configmap"
    namespace = kubernetes_namespace.dnscrypt.metadata[0].name
  }
  data = {
    "dnscrypt-proxy.toml" = var.dnscrypt_proxy_toml
  }
}

resource "kubernetes_deployment" "dnscrypt" {
  metadata {
    name      = "dnscrypt-proxy"
    namespace = kubernetes_namespace.dnscrypt.metadata[0].name
    labels = {
      app                             = "dnscrypt-proxy"
      "kubernetes.io/cluster-service" = "true"
    }
  }
  spec {
    replicas = 3
    selector {
      match_labels = {
        app = "dnscrypt-proxy"
      }
    }
    template {
      metadata {
        labels = {
          app                             = "dnscrypt-proxy"
          "kubernetes.io/cluster-service" = "true"
        }
      }
      spec {
        container {
          image             = "gists/dnscrypt-proxy:latest"
          name              = "dnscrypt-proxy"
          image_pull_policy = "IfNotPresent"
          port {
            container_port = 53
            protocol       = "UDP"
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/dnscrypt-proxy/"
          }
        }
        volume {
          name = "config"
          config_map {
            name = "dnscrypt-proxy-configmap"
            items {
              key  = "dnscrypt-proxy.toml"
              path = "dnscrypt-proxy.toml"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "dnscrypt" {
  metadata {
    name      = "dnscrypt-proxy"
    namespace = kubernetes_namespace.dnscrypt.metadata[0].name
    labels = {
      "app" = "dnscrypt-proxy"
    }
    annotations = {
      "metallb.universe.tf/allow-shared-ip" = "shared"
    }
  }
  spec {
    type = "LoadBalancer"
    selector = {
      app = "dnscrypt-proxy"
    }
    port {
      name        = "dns"
      protocol    = "UDP"
      port        = "5353"
      target_port = "53"
    }
  }
}
