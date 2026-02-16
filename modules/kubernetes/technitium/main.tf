variable "tls_secret_name" {}
variable "tier" { type = string }
variable "homepage_token" {}

resource "kubernetes_namespace" "technitium" {
  metadata {
    name = "technitium"
    # stale cache error when trying to resolve
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.technitium.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# CoreDNS Corefile - manages cluster DNS resolution
# The viktorbarzin.lan block forwards to Technitium via LoadBalancer.
# The cluster.local.viktorbarzin.lan and viktorbarzin.lan.viktorbarzin.lan blocks
# short-circuit junk queries caused by ndots:5 search domain expansion
# (e.g. redis.redis.svc.cluster.local.viktorbarzin.lan, idrac.viktorbarzin.lan.viktorbarzin.lan)
# which would otherwise flood Technitium with NxDomain queries.
resource "kubernetes_config_map" "coredns" {
  metadata {
    name      = "coredns"
    namespace = "kube-system"
  }

  data = {
    Corefile = <<-EOF
      .:53 {
        #log
          errors
          health {
              lameduck 5s
          }
          ready
          kubernetes cluster.local in-addr.arpa ip6.arpa {
              pods insecure
              fallthrough in-addr.arpa ip6.arpa
              ttl 30
          }
          prometheus :9153
          #forward . 1.1.1.1
          forward . 10.0.20.1
          #forward . /etc/resolv.conf
          cache {
            success 10000 300 6
            denial 10000 300 60
          }
          loop
          reload
          loadbalance
      }
      cluster.local.viktorbarzin.lan:53 {
        errors
        template ANY ANY {
          rcode NXDOMAIN
        }
        cache {
          denial 10000 3600
        }
      }
      viktorbarzin.lan.viktorbarzin.lan:53 {
        errors
        template ANY ANY {
          rcode NXDOMAIN
        }
        cache {
          denial 10000 3600
        }
      }
      viktorbarzin.lan:53 {
        #log
        errors
        forward . 10.0.20.204 # Technitium LoadBalancer
        cache {
          success 10000 300 6
          denial 10000 300 60
        }
      }
    EOF
  }
}

resource "kubernetes_deployment" "technitium" {
  # resource "kubernetes_daemonset" "technitium" {
  metadata {
    name      = "technitium"
    namespace = kubernetes_namespace.technitium.metadata[0].name
    labels = {
      app  = "technitium"
      tier = var.tier
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
        annotations = {
          "diun.enable" = "false"
          # "diun.include_tags" = "^\\d+(?:\\.\\d+)?(?:\\.\\d+)?$"
          "diun.include_tags" = "latest"
        }
        labels = {
          app = "technitium"
        }
      }
      spec {
        # Prefer nodes running Traefik for network locality
        affinity {
          pod_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                label_selector {
                  match_expressions {
                    key      = "app.kubernetes.io/name"
                    operator = "In"
                    values   = ["traefik"]
                  }
                }
                topology_key = "kubernetes.io/hostname"
              }
            }
          }
        }
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
    namespace = kubernetes_namespace.technitium.metadata[0].name
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
    namespace = kubernetes_namespace.technitium.metadata[0].name
    labels = {
      "app" = "technitium"
    }
  }

  spec {
    type = "LoadBalancer"
    port {
      name     = "technitium-dns"
      port     = 53
      protocol = "UDP"
    }
    external_traffic_policy = "Local"
    selector = {
      app = "technitium"
    }
  }
}
module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.technitium.metadata[0].name
  name            = "technitium"
  tls_secret_name = var.tls_secret_name
  port            = 5380
  service_name    = "technitium-web"
  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/description" = "Internal DNS Server and Recursive Resolver"
    # gethomepage.dev/group: Media
    "gethomepage.dev/icon" : "technitium.png"
    "gethomepage.dev/name"        = "Technitium"
    "gethomepage.dev/widget.type" = "technitium"
    "gethomepage.dev/widget.url"  = "http://technitium-web.technitium.svc.cluster.local:5380"
    "gethomepage.dev/widget.key"  = var.homepage_token

    "gethomepage.dev/widget.range"  = "LastWeek"
    "gethomepage.dev/widget.fields" = "[\"totalQueries\", \"totalCached\", \"totalBlocked\", \"totalRecursive\"]"
    "gethomepage.dev/pod-selector"  = ""
  }
}

module "ingress-doh" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.technitium.metadata[0].name
  name            = "technitium-doh"
  tls_secret_name = var.tls_secret_name
  host            = "dns"
  service_name    = "technitium-web"
}

