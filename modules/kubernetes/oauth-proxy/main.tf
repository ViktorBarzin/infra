variable "tls_secret_name" {}
variable "client_id" {}
variable "client_secret" {}

resource "kubernetes_namespace" "oauth" {
  metadata {
    name = "oauth"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "oauth"
  tls_secret_name = var.tls_secret_name
}

resource "random_password" "cookie" {
  length           = 16
  special          = true
  override_special = "_%@"
}

resource "kubernetes_deployment" "oauth_proxy" {
  metadata {
    name      = "oauth-proxy"
    namespace = "oauth"
    labels = {
      run = "oauth-proxy"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        run = "oauth-proxy"
      }
    }
    template {
      metadata {
        labels = {
          run = "oauth-proxy"
        }
      }
      spec {
        container {
          image             = "quay.io/oauth2-proxy/oauth2-proxy:latest"
          args              = ["--provider=github", "--email-domain=*", "upstream=file:///dev/null", "--http-address=0.0.0.0:4180"]
          name              = "oauth-proxy"
          image_pull_policy = "IfNotPresent"
          resources {
            limits = {
              cpu    = "0.5"
              memory = "512Mi"
            }
            requests = {
              cpu    = "250m"
              memory = "50Mi"
            }
          }
          port {
            container_port = 4180
          }
          env {
            name  = "OAUTH2_PROXY_CLIENT_ID"
            value = var.client_id
          }
          env {
            name  = "OAUTH2_PROXY_CLIENT_SECRET"
            value = var.client_secret
          }
          env {
            name  = "OAUTH2_PROXY_COOKIE_SECRET"
            value = random_password.cookie.result
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "oauth_proxy" {
  metadata {
    name      = "oauth-proxy"
    namespace = "oauth"
    labels = {
      run = "oauth-proxy"
    }
  }

  spec {
    selector = {
      run = "oauth-proxy"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "4180"
    }
  }
}

resource "kubernetes_ingress" "oauth" {
  metadata {
    name      = "oauth-ingress"
    namespace = "oauth"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  spec {
    tls {
      hosts       = ["oauth.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "oauth.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service_name = "oauth-proxy"
            service_port = "80"
          }
        }
      }
    }
  }
}

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
