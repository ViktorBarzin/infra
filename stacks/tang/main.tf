# Tang: network-bound disk encryption for Physical nodes (ADR-0045).
#
# Each Physical node keeps its secrets on a LUKS2 State volume that Clevis
# unlocks from Tang after the network is up. Every node has its own Tang key
# set and its own tangd, so deleting one node's keys (after a theft) locks that
# node for good without touching the others. Tang does not authenticate
# clients: the guarantee rests on the Service being reachable only from the
# node's own Site LAN (loadBalancerSourceRanges) through the WireGuard tunnel.
#
# Keys: Vault secret/tang-<node> (sig.jwk ES512, exc.jwk ECMR), synced by ESO
# and mounted read-only. Generate with `jose jwk gen` (docs/runbooks/physical-node.md).
#
# An in-cluster Tang cannot unlock a node that the cluster itself needs to
# start, so Physical nodes stay out of the control plane and core services.

locals {
  # Image: padhihomelab/tang builds latchset/jose and latchset/tang from pinned
  # commits on Alpine (github.com/padhi-homelab/docker_tang). Its entrypoint
  # wraps tangd in socat; tangd -l listens by itself, so it is called directly.
  image = "docker.io/padhihomelab/tang@sha256:3a9a5b1d07c70e97d6a3b56919acedf2abcd6b5e9ded132531123c719e0b267e"

  nodes = {
    "dell-worker" = {
      lb_ip = "10.0.20.214"
      # The node's Site LAN, plus the management VLAN for checks from the devvm.
      source_ranges = ["192.168.8.0/24", "10.0.10.0/24"]
    }
  }
}

resource "kubernetes_namespace" "tang" {
  metadata {
    name = "tang"
    labels = {
      tier = local.tiers.edge
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_manifest" "keys" {
  for_each = local.nodes
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "tang-${each.key}"
      namespace = kubernetes_namespace.tang.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "tang-${each.key}"
      }
      dataFrom = [{
        extract = {
          key = "tang-${each.key}"
        }
      }]
    }
  }
}

resource "kubernetes_deployment" "tang" {
  for_each = local.nodes
  metadata {
    name      = "tang-${each.key}"
    namespace = kubernetes_namespace.tang.metadata[0].name
    labels = {
      app  = "tang"
      node = each.key
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app  = "tang"
        node = each.key
      }
    }
    template {
      metadata {
        labels = {
          app  = "tang"
          node = each.key
        }
      }
      spec {
        # Never run on the node this Tang unlocks: a Physical node is not up
        # when it needs its key.
        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "kubernetes.io/hostname"
                  operator = "NotIn"
                  values   = [each.key]
                }
              }
            }
          }
        }
        security_context {
          run_as_non_root = true
          run_as_user     = 65534
          run_as_group    = 65534
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }
        container {
          name    = "tangd"
          image   = local.image
          command = ["/usr/local/bin/tangd", "-l", "-p", "8080", "/db"]
          port {
            name           = "http"
            container_port = 8080
          }
          volume_mount {
            name       = "keys"
            mount_path = "/db"
            read_only  = true
          }
          readiness_probe {
            http_get {
              path = "/adv"
              port = 8080
            }
            period_seconds = 30
          }
          liveness_probe {
            http_get {
              path = "/adv"
              port = 8080
            }
            period_seconds    = 60
            failure_threshold = 3
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
        }
        volume {
          name = "keys"
          secret {
            secret_name  = "tang-${each.key}"
            default_mode = "0444"
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
  depends_on = [kubernetes_manifest.keys]
}

resource "kubernetes_service" "tang" {
  for_each = local.nodes
  metadata {
    name      = "tang-${each.key}"
    namespace = kubernetes_namespace.tang.metadata[0].name
    annotations = {
      "metallb.io/loadBalancerIPs" = each.value.lb_ip
    }
  }
  spec {
    type                        = "LoadBalancer"
    external_traffic_policy     = "Local"
    load_balancer_source_ranges = each.value.source_ranges
    selector = {
      app  = "tang"
      node = each.key
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
  lifecycle {
    ignore_changes = [metadata[0].annotations["metallb.io/ip-allocated-from-pool"]]
  }
}
