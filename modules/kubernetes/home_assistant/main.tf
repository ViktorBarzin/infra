variable "tls_secret_name" {}
variable "client_certificate_secret_name" {}
variable "configuration_yaml" {}

# resource "kubernetes_namespace" "home_assistant" {
#   metadata {
#     name = "home-assistant"
#   }
# }

# resource "kubernetes_config_map" "home_assistant_config_map" {
#   metadata {
#     name      = "home-assistant-configmap"
#     namespace = "home-assistant"

#     annotations = {
#       "reloader.stakater.com/match" = "true"
#     }
#   }

#   data = {
#     # "db.viktorbarzin.lan"         = var.db_viktorbarzin_lan
#     # "db.viktorbarzin.me"          = format("%s%s", var.db_viktorbarzin_me, file("${path.module}/extra/viktorbarzin.me"))
#     # "db.181.191.213.in-addr.arpa" = var.db_ptr
#     "configuration.yaml" = var.configuration_yaml
#   }
# }

# module "tls_secret" {
#   source          = "../setup_tls_secret"
#   namespace       = "home-assistant"
#   tls_secret_name = var.tls_secret_name
# }

# resource "helm_release" "home_assistant" {
#   namespace        = "home-assistant"
#   create_namespace = true
#   name             = "home-assistant"

#   repository = "https://k8s-at-home.com/charts/"
#   chart      = "home-assistant"

#   values = [templatefile("${path.module}/home_assistant_chart_values.tpl", { tls_secret_name = var.tls_secret_name, client_certificate_secret_name = var.client_certificate_secret_name })]
# }

# resource "kubernetes_deployment" "home_assistant" {
#   metadata {
#     name      = "home-assistant"
#     namespace = "home-assistant"

#     labels = {
#       "app.kubernetes.io/instance" = "home-assistant"
#       "app.kubernetes.io/name"     = "home-assistant"
#       "app.kubernetes.io/version"  = "2022.5.4"
#     }
#   }

#   spec {
#     replicas = 1

#     selector {
#       match_labels = {
#         "app.kubernetes.io/instance" = "home-assistant"
#         "app.kubernetes.io/name"     = "home-assistant"
#       }
#     }

#     template {
#       metadata {
#         labels = {
#           "app.kubernetes.io/instance" = "home-assistant"

#           "app.kubernetes.io/name" = "home-assistant"
#         }
#       }

#       spec {
#         container {
#           name = "home-assistant"
#           # image = "ghcr.io/home-assistant/home-assistant:2022.5.4"
#           image = "ghcr.io/home-assistant/home-assistant:2022.5.5"
#           #   image = "ghcr.io/home-assistant/home-assistant"
#           port {
#             name           = "http"
#             container_port = 8123
#             protocol       = "TCP"
#           }
#           env {
#             name  = "TZ"
#             value = "UTC+3"
#           }

#           volume_mount {
#             name       = "configuration"
#             mount_path = "/config"
#             # sub_path   = "hackmd"
#           }
#           liveness_probe {
#             tcp_socket {
#               port = "8123"
#             }
#             timeout_seconds   = 1
#             period_seconds    = 10
#             success_threshold = 1
#             failure_threshold = 3
#           }

#           readiness_probe {
#             tcp_socket {
#               port = "8123"
#             }

#             timeout_seconds   = 1
#             period_seconds    = 10
#             success_threshold = 1
#             failure_threshold = 3
#           }

#           startup_probe {
#             tcp_socket {
#               port = "8123"
#             }

#             timeout_seconds   = 1
#             period_seconds    = 5
#             success_threshold = 1
#             failure_threshold = 30
#           }

#           termination_message_path = "/dev/termination-log"
#           image_pull_policy        = "IfNotPresent"
#         }

#         volume {
#           name = "configuration"
#           iscsi {
#             target_portal = "iscsi.viktorbarzin.lan:3260"
#             fs_type       = "ext4"
#             iqn           = "iqn.2020-12.lan.viktorbarzin:storage:home-assistant"
#             lun           = 0
#             read_only     = false
#           }
#         }

#         restart_policy                   = "Always"
#         termination_grace_period_seconds = 30
#         dns_policy                       = "ClusterFirst"
#         service_account_name             = "default"
#       }
#     }

#     strategy {
#       type = "Recreate"
#     }
#     revision_history_limit = 3
#   }
# }
# resource "kubernetes_service" "home_assistant" {
#   metadata {
#     name      = "home-assistant"
#     namespace = "home-assistant"

#     labels = {
#       "app.kubernetes.io/instance" = "home-assistant"

#       "app.kubernetes.io/managed-by" = "Helm"

#       "app.kubernetes.io/name" = "home-assistant"

#       "app.kubernetes.io/version" = "2022.5.4"

#       "helm.sh/chart" = "home-assistant-13.2.0"
#     }

#     annotations = {
#       "meta.helm.sh/release-name" = "home-assistant"

#       "meta.helm.sh/release-namespace" = "home-assistant"
#     }
#   }

#   spec {
#     port {
#       name        = "http"
#       protocol    = "TCP"
#       port        = 8123
#       target_port = "http"
#     }

#     selector = {
#       "app.kubernetes.io/instance" = "home-assistant"

#       "app.kubernetes.io/name" = "home-assistant"
#     }

#     # cluster_ip       = "10.102.20.150"
#     type             = "ClusterIP"
#     session_affinity = "None"
#   }
# }



# resource "kubernetes_ingress_v1" "home-assistant-ui" {
#   metadata {
#     name      = "home-assistant-ui-ingress"
#     namespace = "home-assistant"
#     annotations = {
#       "kubernetes.io/ingress.class"                        = "nginx"
#       "nginx.ingress.kubernetes.io/force-ssl-redirect"     = "true"
#       "nginx.ingress.kubernetes.io/auth-tls-verify-client" = "on"
#       "nginx.ingress.kubernetes.io/auth-tls-secret"        = var.client_certificate_secret_name
#     }
#   }

#   spec {
#     tls {
#       hosts       = ["home-assistant.viktorbarzin.me"]
#       secret_name = var.tls_secret_name
#     }
#     rule {
#       host = "home-assistant.viktorbarzin.me"
#       http {
#         path {
#           path = "/"
#           backend {
#             service {
#               name = "home-assistant"
#               port {
#                 number = 8123
#               }
#             }
#           }
#         }
#       }
#     }
#   }
# }
