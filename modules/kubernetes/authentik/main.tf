variable "tls_secret_name" {}
variable "secret_key" {}
variable "postgres_password" {}
variable "tier" { type = string }


module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.authentik.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "authentik" {
  metadata {
    name = "authentik"
    labels = {
      tier                                = var.tier
      "resource-governance/custom-quota" = "true"
    }
  }
}

resource "kubernetes_resource_quota" "authentik" {
  metadata {
    name      = "authentik-quota"
    namespace = kubernetes_namespace.authentik.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "8"
      "requests.memory" = "8Gi"
      "limits.cpu"      = "24"
      "limits.memory"   = "48Gi"
      pods              = "30"
    }
  }
}

resource "helm_release" "authentik" {
  namespace        = kubernetes_namespace.authentik.metadata[0].name
  create_namespace = true
  name             = "goauthentik"

  repository = "https://charts.goauthentik.io/"
  chart      = "authentik"
  # version    = "2025.8.1"
  version = "2025.10.3"
  atomic  = true
  timeout = 6000

  values = [templatefile("${path.module}/values.yaml", { postgres_password = var.postgres_password, secret_key = var.secret_key })]
}


module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.authentik.metadata[0].name
  name            = "authentik"
  service_name    = "goauthentik-server"
  tls_secret_name = var.tls_secret_name
}

module "ingress-outpost" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.authentik.metadata[0].name
  name            = "authentik-outpost"
  host            = "authentik"
  service_name    = "ak-outpost-authentik-embedded-outpost"
  port            = 9000
  ingress_path    = ["/outpost.goauthentik.io"]
  tls_secret_name = var.tls_secret_name
}
