# Opportunistic nodes (ADR-0045): workers whose default state is off, such as
# dell-worker. This stack removes the Node object of one that is switched off,
# so an offline Opportunistic worker is absent from the cluster instead of a
# NotReady node with Pending DaemonSet pods. Alerts, health checks and agents
# then need no exclusion for it while it is off.
#
# The rule (files/remove-offline.sh, tested by test_remove_offline.py): remove
# the node when it is not Ready and kubelet has not renewed its Lease for 15
# minutes. On boot kubelet registers the node again with the label and taint
# from its kubeadm flags. docs/runbooks/physical-node.md, "Offline and back".

locals {
  name = "opportunistic-nodes"
  labels = {
    app = local.name
  }
}

resource "kubernetes_namespace" "this" {
  metadata {
    name = local.name
    labels = {
      tier = local.tiers.cluster
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_service_account" "remover" {
  metadata {
    name      = "offline-node-remover"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
}

resource "kubernetes_cluster_role" "remover" {
  metadata {
    name = "offline-node-remover"
  }
  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list", "delete"]
  }
}

resource "kubernetes_cluster_role_binding" "remover" {
  metadata {
    name = "offline-node-remover"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.remover.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.remover.metadata[0].name
    namespace = kubernetes_namespace.this.metadata[0].name
  }
}

# Lease renewTime is the kubelet heartbeat; reading it needs only this namespace.
resource "kubernetes_role" "leases" {
  metadata {
    name      = "offline-node-remover"
    namespace = "kube-node-lease"
  }
  rule {
    api_groups = ["coordination.k8s.io"]
    resources  = ["leases"]
    verbs      = ["get"]
  }
}

resource "kubernetes_role_binding" "leases" {
  metadata {
    name      = "offline-node-remover"
    namespace = "kube-node-lease"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.leases.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.remover.metadata[0].name
    namespace = kubernetes_namespace.this.metadata[0].name
  }
}

resource "kubernetes_config_map" "script" {
  metadata {
    name      = "remove-offline"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  data = {
    "remove-offline.sh" = file("${path.module}/files/remove-offline.sh")
  }
}

resource "kubernetes_cron_job_v1" "remover" {
  metadata {
    name      = "remove-offline"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels    = local.labels
  }
  spec {
    schedule                      = "*/5 * * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 300
    job_template {
      metadata {
        labels = local.labels
      }
      spec {
        backoff_limit              = 0
        active_deadline_seconds    = 120
        ttl_seconds_after_finished = 3600
        template {
          metadata {
            labels = local.labels
          }
          spec {
            service_account_name = kubernetes_service_account.remover.metadata[0].name
            restart_policy       = "Never"
            enable_service_links = false
            volume {
              name = "script"
              config_map {
                name         = kubernetes_config_map.script.metadata[0].name
                default_mode = "0555"
              }
            }
            container {
              name = "remove-offline"
              # bitnami/kubectl publishes only :latest on Docker Hub; the digest
              # pins it and Renovate bumps it (same pin as stacks/kured).
              image             = "bitnami/kubectl:latest@sha256:ae71f848f057a71029d092e98548cabf7cd17b11da0adad0a8f4145a9c87c830"
              image_pull_policy = "IfNotPresent"
              command           = ["/bin/bash", "/script/remove-offline.sh"]
              volume_mount {
                name       = "script"
                mount_path = "/script"
                read_only  = true
              }
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "64Mi"
                }
                limits = {
                  memory = "256Mi"
                }
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
}
