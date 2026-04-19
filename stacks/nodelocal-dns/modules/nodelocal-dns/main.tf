// NodeLocal DNSCache — per-node DNS cache as a DaemonSet.
//
// Why: insulates pods from transient CoreDNS / pfSense issues. Each node
// runs a CoreDNS-based cache listening on the link-local IP (169.254.20.10)
// AND on the kube-dns ClusterIP (10.96.0.10) via hostNetwork + NET_ADMIN
// iptables NOTRACK rules. Pods already use 10.96.0.10 as their resolver
// (verified in /etc/resolv.conf), so traffic is transparently intercepted
// on the node and served from the local cache — no kubelet clusterDNS
// change required.
//
// Upstream CoreDNS is reached via a separate headless service
// `kube-dns-upstream` that selects the CoreDNS pods directly (distinct
// ClusterIP from kube-dns so we can forward without looping back to
// ourselves).
//
// Sources:
//   https://kubernetes.io/docs/tasks/administer-cluster/nodelocaldns/
//   https://github.com/kubernetes/kubernetes/blob/master/cluster/addons/dns/nodelocaldns/nodelocaldns.yaml

variable "link_local_ip" {
  type    = string
  default = "169.254.20.10"
}

variable "kube_dns_ip" {
  type    = string
  default = "10.96.0.10"
}

variable "technitium_ip" {
  type    = string
  default = "10.96.0.53"
}

variable "image" {
  type    = string
  default = "registry.k8s.io/dns/k8s-dns-node-cache:1.23.1"
}

variable "tier" {
  type    = string
  default = "0-core"
}

locals {
  namespace = "kube-system"
  app_label = "node-local-dns"
}

// ---------------------------------------------------------------------------
// ServiceAccount + RBAC
// ---------------------------------------------------------------------------

resource "kubernetes_service_account" "node_local_dns" {
  metadata {
    name      = "node-local-dns"
    namespace = local.namespace
    labels = {
      "k8s-app" = local.app_label
    }
  }
}

// ---------------------------------------------------------------------------
// Upstream service — routes cache misses to CoreDNS pods (not the kube-dns
// ClusterIP, because we're co-listening on that IP ourselves).
// ---------------------------------------------------------------------------

resource "kubernetes_service" "kube_dns_upstream" {
  metadata {
    name      = "kube-dns-upstream"
    namespace = local.namespace
    labels = {
      "k8s-app"                       = "kube-dns"
      "kubernetes.io/cluster-service" = "true"
      "kubernetes.io/name"            = "KubeDNSUpstream"
    }
  }
  spec {
    selector = {
      "k8s-app" = "kube-dns"
    }
    port {
      name        = "dns"
      port        = 53
      protocol    = "UDP"
      target_port = "53"
    }
    port {
      name        = "dns-tcp"
      port        = 53
      protocol    = "TCP"
      target_port = "53"
    }
  }
}

// ---------------------------------------------------------------------------
// Headless service — Prometheus metrics scrape target (one endpoint per node).
// ---------------------------------------------------------------------------

resource "kubernetes_service" "node_local_dns" {
  metadata {
    name      = "node-local-dns"
    namespace = local.namespace
    labels = {
      "k8s-app"                       = local.app_label
      "kubernetes.io/cluster-service" = "true"
    }
    annotations = {
      "prometheus.io/port"   = "9253"
      "prometheus.io/scrape" = "true"
    }
  }
  spec {
    cluster_ip = "None"
    selector = {
      "k8s-app" = local.app_label
    }
    port {
      name        = "metrics"
      port        = 9253
      target_port = "9253"
    }
  }
}

// ---------------------------------------------------------------------------
// Corefile — inline here so changes are reviewable via Terraform plan.
// The node-cache binary does string replacement for __PILLAR__ tokens at
// startup; we pre-fill LOCAL/DNS_SERVER with our real IPs and leave
// __PILLAR__CLUSTER__DNS__ for the runtime substitution from
// kube-dns-upstream endpoints.
// ---------------------------------------------------------------------------

resource "kubernetes_config_map" "node_local_dns" {
  metadata {
    name      = "node-local-dns"
    namespace = local.namespace
    labels = {
      "k8s-app" = local.app_label
    }
  }
  data = {
    "Corefile" = <<-EOF
      cluster.local:53 {
          errors
          cache {
              success 9984 30
              denial 9984 5
          }
          reload
          loop
          bind ${var.link_local_ip} ${var.kube_dns_ip}
          forward . __PILLAR__CLUSTER__DNS__ {
              force_tcp
          }
          prometheus :9253
          health ${var.link_local_ip}:8080
      }
      in-addr.arpa:53 {
          errors
          cache 30
          reload
          loop
          bind ${var.link_local_ip} ${var.kube_dns_ip}
          forward . __PILLAR__CLUSTER__DNS__ {
              force_tcp
          }
          prometheus :9253
      }
      ip6.arpa:53 {
          errors
          cache 30
          reload
          loop
          bind ${var.link_local_ip} ${var.kube_dns_ip}
          forward . __PILLAR__CLUSTER__DNS__ {
              force_tcp
          }
          prometheus :9253
      }
      viktorbarzin.lan:53 {
          errors
          cache 30
          reload
          loop
          bind ${var.link_local_ip} ${var.kube_dns_ip}
          forward . ${var.technitium_ip}
          prometheus :9253
      }
      .:53 {
          errors
          cache 30
          reload
          loop
          bind ${var.link_local_ip} ${var.kube_dns_ip}
          forward . __PILLAR__CLUSTER__DNS__
          prometheus :9253
      }
      EOF
  }
}

// ---------------------------------------------------------------------------
// DaemonSet
// ---------------------------------------------------------------------------

resource "kubernetes_daemon_set_v1" "node_local_dns" {
  metadata {
    name      = "node-local-dns"
    namespace = local.namespace
    labels = {
      "k8s-app" = local.app_label
      tier      = var.tier
    }
  }
  spec {
    selector {
      match_labels = {
        "k8s-app" = local.app_label
      }
    }
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = "10%"
      }
    }
    template {
      metadata {
        labels = {
          "k8s-app" = local.app_label
        }
        annotations = {
          # Ensure pods pick up Corefile changes without waiting for a
          # reload (CoreDNS reload plugin picks up changes within 30s,
          # but a hash annotation forces an immediate rollout).
          "node-local-dns/corefile-hash" = sha256(kubernetes_config_map.node_local_dns.data["Corefile"])
        }
      }
      spec {
        priority_class_name              = "system-node-critical"
        service_account_name             = kubernetes_service_account.node_local_dns.metadata[0].name
        host_network                     = true
        dns_policy                       = "Default"
        termination_grace_period_seconds = 0

        toleration {
          operator = "Exists"
        }

        container {
          name              = "node-cache"
          image             = var.image
          image_pull_policy = "IfNotPresent"

          resources {
            # Per cluster CPU-limits-removed policy: requests only, no limit.
            requests = {
              cpu    = "25m"
              memory = "32Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }

          args = [
            "-localip",
            "${var.link_local_ip},${var.kube_dns_ip}",
            "-conf",
            "/etc/Corefile",
            "-upstreamsvc",
            kubernetes_service.kube_dns_upstream.metadata[0].name,
            "-skipteardown=true",
          ]

          security_context {
            capabilities {
              add = ["NET_ADMIN"]
            }
          }

          port {
            name           = "dns"
            container_port = 53
            protocol       = "UDP"
          }
          port {
            name           = "dns-tcp"
            container_port = 53
            protocol       = "TCP"
          }
          port {
            name           = "metrics"
            container_port = 9253
            protocol       = "TCP"
          }

          liveness_probe {
            http_get {
              host = var.link_local_ip
              path = "/health"
              port = "8080"
            }
            initial_delay_seconds = 60
            timeout_seconds       = 5
          }

          volume_mount {
            name       = "xtables-lock"
            mount_path = "/run/xtables.lock"
            read_only  = false
          }
          volume_mount {
            name       = "config-volume"
            mount_path = "/etc/coredns"
          }
          volume_mount {
            name       = "kube-dns-config"
            mount_path = "/etc/kube-dns"
          }
        }

        volume {
          name = "xtables-lock"
          host_path {
            path = "/run/xtables.lock"
            type = "FileOrCreate"
          }
        }
        volume {
          name = "kube-dns-config"
          config_map {
            name     = "kube-dns"
            optional = true
          }
        }
        volume {
          name = "config-volume"
          config_map {
            name = kubernetes_config_map.node_local_dns.metadata[0].name
            items {
              key  = "Corefile"
              path = "Corefile.base"
            }
          }
        }
      }
    }
  }

  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with
    # ndots=2 on every pod; ignoring avoids spurious plan drift.
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}
