resource "kubernetes_namespace" "descheduler" {
  metadata {
    name = "descheduler"
  }
}

resource "kubernetes_cluster_role" "descheduler" {
  metadata {
    name = "descheduler-cluster-role"
  }
  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["create", "update"]
  }
  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "watch", "list"]
  }
  rule {
    api_groups = [""]
    resources  = ["namespaces"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "watch", "list", "delete"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods/eviction"]
    verbs      = ["create"]
  }
  rule {
    api_groups = [""]
    resources  = ["scheduling.k8s.io"]
    verbs      = ["get", "watch", "list"]
  }
}

resource "kubernetes_service_account" "descheduler" {
  metadata {
    name      = "descheduler-sa"
    namespace = "descheduler"
  }
}

resource "kubernetes_cluster_role_binding" "descheduler" {
  metadata {
    name = "descheduler-cluster-role-binding"

  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "descheduler-cluster-role"
  }
  subject {
    name      = "descheduler-sa"
    kind      = "ServiceAccount"
    namespace = "descheduler"
  }
}

resource "kubernetes_config_map" "policy" {
  metadata {
    namespace = "descheduler"
    name      = "policy-configmap"
  }
  data = {
    "policy.yaml" = <<-EOF
          apiVersion: "descheduler/v1alpha1"
          maxNoOfPodsToEvictPerNode: 5
          kind: "DeschedulerPolicy"
          strategies:
            "RemoveDuplicates":
              enabled: true
            "RemovePodsViolatingInterPodAntiAffinity":
              enabled: true
            "LowNodeUtilization":
              enabled: true
              params:
                nodeResourceUtilizationThresholds:
                  thresholds:
                    "cpu" : 20
                    "memory": 20
                    "pods": 20
                  targetThresholds:
                    "cpu" : 50
                    "memory": 50
                    "pods": 50
            "PodLifeTime":
              enabled: true
              params:
                maxPodLifeTimeSeconds: 86400
                namespaces:
                  exclude:
                  - "monitoring"
                  - "kube-system"
    EOF
  }
}

resource "kubernetes_cron_job" "descheduler" {
  metadata {
    name      = "descheduler"
    namespace = "descheduler"
  }
  spec {
    schedule           = "0 * * * *"
    concurrency_policy = "Forbid"
    job_template {
      metadata {
        name = "descheduler"
      }
      spec {
        template {
          metadata {
            name = "descheduler"
          }
          spec {
            priority_class_name = "system-cluster-critical"
            container {
              name  = "descheduler"
              image = "us.gcr.io/k8s-artifacts-prod/descheduler/descheduler:v0.18.0"
              volume_mount {
                mount_path = "/policy-dir"
                name       = "policy-volume"
              }
              command = ["/bin/descheduler"]
              args    = ["--policy-config-file", "/policy-dir/policy.yaml", "--v", "4"]
            }
            restart_policy       = "Never"
            service_account_name = "descheduler-sa"
            volume {
              name = "policy-volume"
              config_map {
                name = "policy-configmap"
              }
            }
          }
        }
      }
    }
  }
}
