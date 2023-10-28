# variable "host" {
#   type = string
# }

resource "kubernetes_namespace" "oauth2" {
  metadata {
    name = "oauth2"
  }
}
variable "tls_secret_name" {
  type = string
}

variable "oauth2_proxy_client_secret" {
  type = string
}

variable "oauth2_proxy_client_id" {
  type = string
}
variable "authenticated_emails" {
  type    = string
  default = ""
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "oauth2"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_config_map" "config" {
  metadata {
    name      = "oauth2-proxy-nginx"
    namespace = "oauth2"

    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    "nginx.conf" = <<-EOT
    worker_processes 5;

    events {
    }

    http {
      server {
        listen 80 default_server;

        location = /healthcheck {
          add_header Content-Type text/plain;
          return 200 'ok';
        }

        location ~ /redirect/(.*) {
          return 307 https://$1$is_args$args;
        }
      }
    }
    EOT
  }
}

resource "kubernetes_config_map" "authorized-emails" {
  metadata {
    name      = "authorized-emails"
    namespace = "oauth2"

    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    "authorized_emails.txt" = var.authenticated_emails
  }
}

resource "random_password" "cookie" {
  length           = 16
  special          = true
  override_special = "_%@"
}

resource "kubernetes_deployment" "oauth2-proxy" {
  metadata {
    name      = "oauth2-proxy"
    namespace = "oauth2"
    labels = {
      app = "oauth2"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "oauth2"
      }
    }
    template {
      metadata {
        labels = {
          app = "oauth2"
        }
      }
      spec {
        container {
          image = "nginx:latest"
          name  = "nginx"

          port {
            name           = "http"
            container_port = 80
            protocol       = "TCP"
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/nginx/"
          }
          liveness_probe {
            http_get {
              path = "/healthcheck"
              port = 80
            }
          }
        }
        container {
          image = "quay.io/pusher/oauth2_proxy:latest"
          name  = "oauth2-proxy"
          args  = ["--provider=google", "--upstream=file:///dev/null", "--upstream=http://localhost/redirect/", "--http-address=0.0.0.0:4180", "--cookie-domain=.viktorbarzin.me", "--footer=-", "--authenticated-emails-file=/etc/authorized_emails/authorized_emails.txt"]
          # args = ["--provider=google", "--upstream=file:///dev/null", "--upstream=http://localhost/redirect/", "--http-address=0.0.0.0:4180", "--cookie-domain=.viktorbarzin.me", "--footer=-", "--email-domain=*", "--google-group=barzini-lab-admins@googlegroups.com", "--google-admin-email=vbarzin@gmail.com", "--google-service-account-json=/etc/google_service_account/google_service_account.json"]
          # args = ["--provider=google", "--upstream=file:///dev/null", "--upstream=http://localhost/redirect/", "--http-address=0.0.0.0:4180", "--cookie-domain=.viktorbarzin.me", "--footer=-", "--email-domain=*", "--google-group=barzini-lab-admins", "--google-admin-email=533122798643-compute@developer.gserviceaccount.com", "--google-service-account-json=/etc/google_service_account/google_service_account.json"]
          env {
            name  = "OAUTH2_PROXY_CLIENT_ID"
            value = var.oauth2_proxy_client_id
          }
          env {
            name  = "OAUTH2_PROXY_CLIENT_SECRET"
            value = var.oauth2_proxy_client_secret
          }
          env {
            name  = "OAUTH2_PROXY_COOKIE_SECRET"
            value = random_password.cookie.result
          }
          port {
            name           = "oauth"
            container_port = 4180
            protocol       = "TCP"
          }
          volume_mount {
            name       = "authorized-emails"
            mount_path = "/etc/authorized_emails"
          }
          # volume_mount {
          #   name       = "sa-json"
          #   mount_path = "/etc/google_service_account/"
          # }
        }
        volume {
          name = "config"
          config_map {
            name = "oauth2-proxy-nginx"
          }
        }
        volume {
          name = "authorized-emails"
          config_map {
            name = "authorized-emails"
          }
        }
        # volume {
        #   name = "sa-json"
        #   config_map {
        #     name = "google-service-account"
        #   }
        # }
      }
    }
  }
}

resource "kubernetes_service" "oauth_proxy" {
  metadata {
    name      = "oauth2"
    namespace = "oauth2"
    labels = {
      app = "oauth2"
    }
  }

  spec {
    selector = {
      app = "oauth2"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = 4180
    }
  }
}

resource "kubernetes_ingress_v1" "oauth" {
  metadata {
    name      = "oauth2"
    namespace = "oauth2"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  spec {
    tls {
      hosts       = ["oauth2.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "oauth2.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "oauth2"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}





# variable "svc_name" {
#   type = string
# }
# variable "client_id" {}
# variable "client_secret" {}


# resource "kubernetes_deployment" "oauth_proxy" {
#   metadata {
#     name      = "oauth-proxy"
#     namespace = var.namespace
#     labels = {
#       run = "oauth-proxy"
#     }
#   }
#   spec {
#     replicas = 1
#     selector {
#       match_labels = {
#         run = "oauth-proxy"
#       }
#     }
#     template {
#       metadata {
#         labels = {
#           run = "oauth-proxy"
#         }
#       }
#       spec {
#         container {
#           image             = "quay.io/oauth2-proxy/oauth2-proxy:latest"
#           args              = ["--provider=google", "--email-domain=*", "upstream=file:///dev/null", "--http-address=0.0.0.0:4180"]
#           name              = "oauth-proxy"
#           image_pull_policy = "IfNotPresent"
#           resources {
#             limits = {
#               cpu    = "0.5"
#               memory = "512Mi"
#             }
#             requests = {
#               cpu    = "250m"
#               memory = "50Mi"
#             }
#           }
#           port {
#             container_port = 4180
#           }
#           env {
#             name  = "OAUTH2_PROXY_CLIENT_ID"
#             value = var.client_id
#           }
#           env {
#             name  = "OAUTH2_PROXY_CLIENT_SECRET"
#             value = var.client_secret
#           }
#           env {
#             name  = "OAUTH2_PROXY_COOKIE_SECRET"
#             value = random_password.cookie.result
#           }
#         }
#       }
#     }
#   }
# }

# resource "kubernetes_service" "oauth_proxy" {
#   metadata {
#     name      = var.svc_name
#     namespace = var.namespace
#     labels = {
#       run = "oauth-proxy"
#     }
#   }

#   spec {
#     selector = {
#       run = "oauth-proxy"
#     }
#     port {
#       name        = "http"
#       port        = "80"
#       target_port = "4180"
#     }
#   }
# }

# resource "kubernetes_ingress_v1" "oauth" {
#   metadata {
#     name      = "oauth-ingress"
#     namespace = var.namespace
#     annotations = {
#       "kubernetes.io/ingress.class"           = "nginx"
#       "nginx.ingress.kubernetes.io/use-regex" = "true"
#     }
#   }

#   spec {
#     tls {
#       hosts       = [var.host]
#       secret_name = var.tls_secret_name
#     }
#     rule {
#       host = var.host
#       http {
#         path {
#           path = "/oauth2/.*"
#           backend {
#             service {
#               name = var.svc_name
#               port {
#                 number = 80
#               }
#             }
#           }
#         }
#       }
#     }
#   }
# }

# apiVersion: apps/v1
# kind: Deployment
# metadata:
#   labels:
#     k8s-app: oauth2-proxy
#   name: oauth2-proxy
#   namespace: kube-system
# spec:
#   replicas: 1
#   selector:
#     matchLabels:
#       k8s-app: oauth2-proxy
#   template:
#     metadata:
#       labels:
#         k8s-app: oauth2-proxy
#     spec:
#       containers:
#       - args:
#         - --provider=github
#         - --email-domain=*
#         - --upstream=file:///dev/null
#         - --http-address=0.0.0.0:4180
#         # Register a new application
#         # https://github.com/settings/applications/new
#         env:
#         - name: OAUTH2_PROXY_CLIENT_ID
#           value: <Client ID>
#         - name: OAUTH2_PROXY_CLIENT_SECRET
#           value: <Client Secret>
#         # docker run -ti --rm python:3-alpine python -c 'import secrets,base64; print(base64.b64encode(base64.b64encode(secrets.token_bytes(16))));'
#         - name: OAUTH2_PROXY_COOKIE_SECRET
#           value: SECRET
#         image: quay.io/oauth2-proxy/oauth2-proxy:latest
#         imagePullPolicy: Always
#         name: oauth2-proxy
#         ports:
#         - containerPort: 4180
#           protocol: TCP

# ---

# apiVersion: v1
# kind: Service
# metadata:
#   labels:
#     k8s-app: oauth2-proxy
#   name: oauth2-proxy
#   namespace: kube-system
# spec:
#   ports:
#   - name: http
#     port: 4180
#     protocol: TCP
#     targetPort: 4180
#   selector:
#     k8s-app: oauth2-proxy
