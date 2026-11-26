# A third Woodpecker agent with one workflow slot and the label builder=true.
#
# The gha-runner pipeline (.woodpecker/gha-runner.yml) asks for this label, so
# cluster builds run one at a time: their Docker-in-Docker IO lands on the sdc
# spindle that also holds etcd. The two chart agents never carry the label, so
# they never take a gha-runner workflow. This agent also takes ordinary
# unlabelled workflows when it is idle. Plan:
# docs/plans/2026-11-26-gha-quota-fallback.md.
#
# The chart (3.7.5) renders one agent StatefulSet with one set of env, so this
# agent is its own resource with the same settings as the chart agents.
resource "kubernetes_stateful_set_v1" "woodpecker_agent_builder" {
  metadata {
    name      = "woodpecker-agent-builder"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
    labels = {
      "app.kubernetes.io/name"     = "agent-builder"
      "app.kubernetes.io/instance" = "woodpecker"
    }
  }
  spec {
    replicas     = 1
    service_name = "woodpecker-agent-builder"
    selector {
      match_labels = {
        "app.kubernetes.io/name"     = "agent-builder"
        "app.kubernetes.io/instance" = "woodpecker"
      }
    }
    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"     = "agent-builder"
          "app.kubernetes.io/instance" = "woodpecker"
        }
      }
      spec {
        service_account_name = "woodpecker-agent"
        security_context {
          fs_group = 1000
        }
        container {
          name  = "agent"
          image = "docker.io/woodpeckerci/woodpecker-agent:v3.19.0"
          env {
            name  = "WOODPECKER_SERVER"
            value = "woodpecker-server:9000"
          }
          env {
            name  = "WOODPECKER_AGENT_SECRET"
            value = data.vault_kv_secret_v2.secrets.data["agent_secret"]
          }
          env {
            name  = "WOODPECKER_BACKEND"
            value = "kubernetes"
          }
          env {
            name  = "WOODPECKER_BACKEND_K8S_NAMESPACE"
            value = "woodpecker"
          }
          env {
            name  = "WOODPECKER_BACKEND_K8S_STORAGE_RWX"
            value = "false"
          }
          env {
            name  = "WOODPECKER_BACKEND_K8S_VOLUME_SIZE"
            value = "10G"
          }
          env {
            name  = "WOODPECKER_BACKEND_K8S_PULL_SECRET_NAMES"
            value = "registry-credentials"
          }
          env {
            name  = "WOODPECKER_MAX_WORKFLOWS"
            value = "1"
          }
          env {
            name  = "WOODPECKER_AGENT_LABELS"
            value = "builder=true"
          }
          env {
            name  = "WOODPECKER_KEEPALIVE_TIME"
            value = "10s"
          }
          env {
            name  = "WOODPECKER_CONNECT_RETRY_COUNT"
            value = "1"
          }
          port {
            name           = "http"
            container_port = 3000
          }
          # Same as the chart agents get from the namespace LimitRange.
          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.woodpecker]
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}
