variable "tls_secret_name" {}
variable "tier" { type = string }
variable "homepage_token" {}
variable "technitium_db_password" {}
variable "nfs_server" { type = string }
variable "mysql_host" { type = string }
variable "technitium_username" { type = string }
variable "technitium_password" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "technitium" {
  metadata {
    name = "technitium"
    labels = {
      tier = var.tier
    }
    # stale cache error when trying to resolve
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.technitium.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# CoreDNS Corefile - manages cluster DNS resolution
# The viktorbarzin.lan block forwards to Technitium via LoadBalancer.
# A template regex in the viktorbarzin.lan block short-circuits junk queries
# caused by ndots:5 search domain expansion (e.g. www.cloudflare.com.viktorbarzin.lan,
# redis.redis.svc.cluster.local.viktorbarzin.lan) by returning NXDOMAIN for any
# query with 2+ labels before .viktorbarzin.lan. Legitimate single-label queries
# (e.g. idrac.viktorbarzin.lan) fall through to Technitium.
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
          forward . 8.8.8.8 1.1.1.1 10.0.20.1
          cache {
            success 10000 300 6
            denial 10000 300 60
          }
          loop
          reload
          loadbalance
      }
      viktorbarzin.lan:53 {
        #log
        errors
        template ANY ANY viktorbarzin.lan {
          match ".*\..*\.viktorbarzin\.lan\.$"
          rcode NXDOMAIN
          fallthrough
        }
        forward . 10.0.20.200 # Technitium LoadBalancer
        cache {
          success 10000 300 6
          denial 10000 300 60
        }
      }
    EOF
  }
}

module "nfs_config" {
  source     = "../../../../modules/kubernetes/nfs_volume"
  name       = "technitium-config"
  namespace  = kubernetes_namespace.technitium.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/technitium"
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
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = "0"
        max_surge       = "1"
      }
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
          app          = "technitium"
          "dns-server" = "true"
        }
      }
      spec {
        affinity {
          # Prefer nodes running Traefik for network locality
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
          # Spread DNS pods across nodes for HA
          pod_anti_affinity {
            required_during_scheduling_ignored_during_execution {
              label_selector {
                match_expressions {
                  key      = "dns-server"
                  operator = "In"
                  values   = ["true"]
                }
              }
              topology_key = "kubernetes.io/hostname"
            }
          }
        }
        container {
          image = "technitium/dns-server:latest"
          name  = "technitium"
          resources {
            requests = {
              cpu    = "25m"
              memory = "512Mi"
            }
            limits = {
              memory = "512Mi"
            }
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
          liveness_probe {
            tcp_socket {
              port = 53
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
          readiness_probe {
            tcp_socket {
              port = 53
            }
            initial_delay_seconds = 5
            period_seconds        = 5
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
          persistent_volume_claim {
            claim_name = module.nfs_config.claim_name
          }
        }
        volume {
          name = "tls-cert"
          secret {
            secret_name = var.tls_secret_name
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
    annotations = {
      "metallb.io/loadBalancerIPs" = "10.0.20.200"
      "metallb.io/allow-shared-ip" = "shared"
    }
  }

  spec {
    type = "LoadBalancer"
    port {
      name     = "technitium-dns"
      port     = 53
      protocol = "UDP"
    }
    external_traffic_policy = "Cluster"
    selector = {
      "dns-server" = "true"
    }
  }
}
module "ingress" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.technitium.metadata[0].name
  name            = "technitium"
  tls_secret_name = var.tls_secret_name
  port            = 5380
  service_name    = "technitium-web"
  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/description" = "Internal DNS Server and Recursive Resolver"
    "gethomepage.dev/group"       = "Infrastructure"
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
  source          = "../../../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.technitium.metadata[0].name
  name            = "technitium-doh"
  tls_secret_name = var.tls_secret_name
  host            = "dns"
  service_name    = "technitium-web"
}

# Grafana datasource for Technitium DNS query logs in MySQL
resource "kubernetes_config_map" "grafana_technitium_datasource" {
  metadata {
    name      = "grafana-technitium-datasource"
    namespace = "monitoring"
    labels = {
      grafana_datasource = "1"
    }
  }
  data = {
    "technitium-datasource.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name     = "Technitium MySQL"
        type     = "mysql"
        access   = "proxy"
        url      = "${var.mysql_host}:3306"
        database = "technitium"
        user     = "technitium"
        uid      = "technitium-mysql"
        secureJsonData = {
          password = var.technitium_db_password
        }
      }]
    })
  }
}

# Grafana dashboard for Technitium DNS query logs
resource "kubernetes_config_map" "grafana_technitium_dashboard" {
  metadata {
    name      = "grafana-technitium-dashboard"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
    }
  }
  data = {
    "technitium-dns.json" = file("${path.module}/../monitoring/dashboards/technitium-dns.json")
  }
}

