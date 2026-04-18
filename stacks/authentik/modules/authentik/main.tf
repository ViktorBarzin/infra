variable "tls_secret_name" {}
variable "secret_key" {}
variable "postgres_password" {}
variable "tier" { type = string }
variable "redis_host" { type = string }
variable "homepage_token" {
  type      = string
  default   = ""
  sensitive = true
}


module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.authentik.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# The embedded outpost auto-creates an ingress expecting this secret name
module "tls_secret_outpost" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.authentik.metadata[0].name
  tls_secret_name = "authentik-outpost-tls"
}

resource "kubernetes_namespace" "authentik" {
  metadata {
    name = "authentik"
    labels = {
      tier                               = var.tier
      "resource-governance/custom-quota" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_resource_quota" "authentik" {
  metadata {
    name      = "authentik-quota"
    namespace = kubernetes_namespace.authentik.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "16"
      "requests.memory" = "16Gi"
      "limits.memory"   = "96Gi"
      pods              = "50"
    }
  }
}

resource "helm_release" "authentik" {
  namespace        = kubernetes_namespace.authentik.metadata[0].name
  create_namespace = true
  name             = "goauthentik"

  repository = "https://charts.goauthentik.io/"
  chart      = "authentik"
  # version    = "2025.10.3"
  # version    = "2025.12.4"
  version = "2026.2.2"
  atomic  = true
  timeout = 6000

  values = [templatefile("${path.module}/values.yaml", { postgres_password = var.postgres_password, secret_key = var.secret_key })]
}


module "ingress" {
  source           = "../../../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace        = kubernetes_namespace.authentik.metadata[0].name
  name             = "authentik"
  service_name     = "goauthentik-server"
  tls_secret_name  = var.tls_secret_name
  anti_ai_scraping = false
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Authentik"
    "gethomepage.dev/description"  = "Identity provider"
    "gethomepage.dev/icon"         = "authentik.png"
    "gethomepage.dev/group"        = "Identity & Security"
    "gethomepage.dev/pod-selector" = ""
    "gethomepage.dev/widget.type"  = "authentik"
    "gethomepage.dev/widget.url"   = "http://goauthentik-server.authentik.svc.cluster.local"
    "gethomepage.dev/widget.key"   = var.homepage_token
  }
}

module "ingress-outpost" {
  source           = "../../../../modules/kubernetes/ingress_factory"
  namespace        = kubernetes_namespace.authentik.metadata[0].name
  name             = "authentik-outpost"
  host             = "authentik"
  service_name     = "ak-outpost-authentik-embedded-outpost"
  port             = 9000
  ingress_path     = ["/outpost.goauthentik.io"]
  tls_secret_name  = var.tls_secret_name
  anti_ai_scraping = false
  exclude_crowdsec = true
}
