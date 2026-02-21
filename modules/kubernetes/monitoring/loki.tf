resource "helm_release" "loki" {
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = true
  name             = "loki"

  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"

  values  = [templatefile("${path.module}/loki.yaml", {})]
  timeout = 600

  depends_on = [kubernetes_config_map.loki_alert_rules]
}

resource "kubernetes_persistent_volume" "loki" {
  metadata {
    name = "loki"
  }
  spec {
    capacity = {
      storage = "15Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      nfs {
        path   = "/mnt/main/loki/loki"
        server = "10.0.10.15"
      }
    }
    persistent_volume_reclaim_policy = "Retain"
    volume_mode                      = "Filesystem"
  }
}

# https://grafana.com/docs/alloy/latest/configure/kubernetes/
resource "helm_release" "alloy" {
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = true
  name             = "alloy"

  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"

  values = [file("${path.module}/alloy.yaml")]
  atomic = true

  depends_on = [helm_release.loki]
}

resource "kubernetes_daemon_set_v1" "sysctl-inotify" {
  metadata {
    name      = "sysctl-inotify"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app = "sysctl-inotify"
    }
  }
  spec {
    selector {
      match_labels = {
        app = "sysctl-inotify"
      }
    }
    template {
      metadata {
        labels = {
          app = "sysctl-inotify"
        }
      }
      spec {
        init_container {
          name  = "sysctl"
          image = "busybox:1.37"
          command = [
            "sh", "-c",
            "sysctl -w fs.inotify.max_user_watches=1048576 && sysctl -w fs.inotify.max_user_instances=8192 && sysctl -w fs.inotify.max_queued_events=1048576"
          ]
          security_context {
            privileged = true
          }
        }
        container {
          name  = "pause"
          image = "registry.k8s.io/pause:3.10"
          resources {
            requests = {
              cpu    = "1m"
              memory = "4Mi"
            }
            limits = {
              cpu    = "1m"
              memory = "4Mi"
            }
          }
        }
        host_pid = true
        toleration {
          operator = "Exists"
        }
      }
    }
  }
}

# resource "helm_release" "k8s-monitoring" {
#  namespace = kubernetes_namespace.monitoring.metadata[0].name
#   create_namespace = true
#   name             = "k8s-monitoring"

#   repository = "https://grafana.github.io/helm-charts"
#   chart      = "k8s-monitoring"

#   values = [templatefile("${path.module}/k8s-monitoring-values.yaml", {})]
#   atomic = true
# }

resource "kubernetes_config_map" "loki_alert_rules" {
  metadata {
    name      = "loki-alert-rules"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "rules.yaml" = yamlencode({
      groups = [{
        name = "log-alerts"
        rules = [
          {
            alert = "HighErrorRate"
            expr  = "sum(rate({namespace=~\".+\"} |= \"error\" [5m])) by (namespace) > 10"
            for   = "5m"
            labels = {
              severity = "warning"
            }
            annotations = {
              summary = "High error rate in {{ $labels.namespace }}"
            }
          },
          {
            alert = "PodCrashLoopBackOff"
            expr  = "count_over_time({namespace=~\".+\"} |= \"CrashLoopBackOff\" [5m]) > 0"
            for   = "1m"
            labels = {
              severity = "critical"
            }
            annotations = {
              summary = "CrashLoopBackOff detected in {{ $labels.namespace }}"
            }
          },
          {
            alert = "OOMKilled"
            expr  = "count_over_time({namespace=~\".+\"} |= \"OOMKilled\" [5m]) > 0"
            for   = "1m"
            labels = {
              severity = "critical"
            }
            annotations = {
              summary = "OOMKilled detected in {{ $labels.namespace }}"
            }
          }
        ]
      }]
    })
  }
}

resource "kubernetes_config_map" "grafana_loki_datasource" {
  metadata {
    name      = "grafana-loki-datasource"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      grafana_datasource = "1"
    }
  }
  data = {
    "loki-datasource.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name      = "Loki"
        type      = "loki"
        access    = "proxy"
        url       = "http://loki.monitoring.svc.cluster.local:3100"
        isDefault = false
      }]
    })
  }
}
