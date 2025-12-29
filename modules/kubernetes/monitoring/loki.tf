# resource "helm_release" "loki" {
#  namespace = kubernetes_namespace.monitoring.metadata[0].name
#   create_namespace = true
#   name             = "loki"

#   repository = "https://grafana.github.io/helm-charts"
#   chart      = "loki"

#   values  = [templatefile("${path.module}/loki.yaml", {})]
#   atomic  = true
#   timeout = 120
# }

# resource "kubernetes_persistent_volume" "loki" {
#   metadata {
#     name = "loki"
#   }
#   spec {
#     capacity = {
#       storage = "15Gi"
#     }
#     access_modes = ["ReadWriteOnce"]
#     persistent_volume_source {
#       nfs {
#         path   = "/mnt/main/loki/loki"
#         server = "10.0.10.15"
#       }
#     }
#     persistent_volume_reclaim_policy = "Retain"
#     volume_mode                      = "Filesystem"
#   }
# }

# resource "kubernetes_persistent_volume" "loki-minio" {
#   metadata {
#     name = "loki-minio"
#   }
#   spec {
#     capacity = {
#       storage = "15Gi"
#     }
#     access_modes = ["ReadWriteMany"]
#     persistent_volume_source {
#       nfs {
#         path   = "/mnt/main/loki/minio"
#         server = "10.0.10.15"
#       }
#     }
#     persistent_volume_reclaim_policy = "Retain"
#     volume_mode                      = "Filesystem"
#   }
# }


# https://grafana.com/docs/alloy/latest/configure/kubernetes/
# resource "helm_release" "alloy" {
#  namespace = kubernetes_namespace.monitoring.metadata[0].name
#   create_namespace = true
#   name             = "alloy"

#   repository = "https://grafana.github.io/helm-charts"
#   chart      = "alloy"

#   atomic = true
# }

# Increase open file limits as alloy is reading files:
# https://serverfault.com/questions/1137211/failed-to-create-fsnotify-watcher-too-many-open-files

# run for all nodes using :
# for n in $(kbn | awk '{print $1}'); do echo $n; s wizard@$n 'sudo sysctl -w fs.inotify.max_user_watches=2099999999; sudo sysctl -w fs.inotify.max_user_instances=2099999999;sudo sysctl -w fs.inotify.max_queued_events=2099999999'; done

# resource "helm_release" "k8s-monitoring" {
#  namespace = kubernetes_namespace.monitoring.metadata[0].name
#   create_namespace = true
#   name             = "k8s-monitoring"

#   repository = "https://grafana.github.io/helm-charts"
#   chart      = "k8s-monitoring"

#   values = [templatefile("${path.module}/k8s-monitoring-values.yaml", {})]
#   atomic = true
# }
