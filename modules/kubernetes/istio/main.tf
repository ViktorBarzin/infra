variable "tls_secret_name" {}

resource "kubernetes_namespace" "istio" {
  metadata {
    name = "istio-system"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "istio-system"
  tls_secret_name = var.tls_secret_name
}

# to delete all CRDS: kubectl get crd -oname | grep --color=never 'istio.io' | xargs kubectl delete
resource "helm_release" "istio-base" {
  namespace        = "istio-system"
  create_namespace = false
  name             = "istio-base"
  atomic           = true

  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "base"
  depends_on = [kubernetes_namespace.istio]
}

resource "helm_release" "istiod" {
  namespace        = "istio-system"
  create_namespace = false
  name             = "istiod"
  atomic           = true

  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  depends_on = [kubernetes_namespace.istio]
}

resource "helm_release" "istio-gateway" {
  namespace        = "istio-system"
  create_namespace = false
  name             = "istio-gateway"
  atomic           = true

  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "gateway"
  depends_on = [kubernetes_namespace.istio]
}

# Kiali dashboard
resource "helm_release" "kiali" {
  namespace        = "istio-system"
  create_namespace = false
  name             = "kiali"
  atomic           = true

  repository = "https://kiali.org/helm-charts"
  chart      = "kiali-operator"
  set {
    name  = "cr.create"
    value = "true"
  }
  set {
    name  = "cr.namespace"
    value = "istio-system"
  }
  values = [templatefile("${path.module}/kiali.yaml", {})]

  depends_on = [kubernetes_namespace.istio]
}

resource "kubernetes_secret" "kiali-token" {
  metadata {
    name      = "kiali-secret"
    namespace = "istio-system"
    annotations = {
      "kubernetes.io/service-account.name" : "kiali-service-account"
    }
  }
  type = "kubernetes.io/service-account-token"
}

resource "kubernetes_ingress_v1" "kiali" {
  metadata {
    name      = "kiali"
    namespace = "istio-system"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      "nginx.ingress.kubernetes.io/auth-url" : "https://oauth2.viktorbarzin.me/oauth2/auth"
      "nginx.ingress.kubernetes.io/auth-signin" : "https://oauth2.viktorbarzin.me/oauth2/start?rd=/redirect/$http_host$escaped_request_uri"
    }
  }

  spec {
    tls {
      hosts       = ["kiali.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "kiali.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "kiali"
              port {
                number = 20001
              }
            }
          }
        }
      }
    }
  }
}
