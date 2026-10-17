# Same layout as the android-emulator public ingresses: the gate owns `/`
# (visiting wakes a sleeping app), the noVNC asset and socket paths go straight
# to the app's Service. Both behind Authentik forward auth; WebSockets work
# through forward auth same-origin (stacks/terminal ttyd, android-emulator).
locals {
  novnc_paths = [
    "/vnc.html", "/app", "/core", "/vendor",
    "/websockify", "/package.json", "/defaults.json", "/mandatory.json",
  ]
}

module "ingress_gate" {
  source          = "../ingress_factory"
  auth            = "required"
  allowed_groups  = var.allowed_groups
  dns_type        = "proxied"
  namespace       = var.namespace
  name            = var.name
  host            = var.host
  service_name    = kubernetes_service.gate.metadata[0].name
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/description" = "${var.title} (Windows app, starts on visit)"
    "gethomepage.dev/icon"        = "mdi-microsoft-windows"
    "gethomepage.dev/name"        = var.title
  }
}

module "ingress_novnc" {
  source           = "../ingress_factory"
  auth             = "required"
  allowed_groups   = var.allowed_groups
  namespace        = var.namespace
  name             = "${var.name}-novnc"
  homepage_enabled = false
  host             = var.host
  service_name     = kubernetes_service.app.metadata[0].name
  ingress_path     = local.novnc_paths
  tls_secret_name  = var.tls_secret_name
  # noVNC loads ~60 unbundled ES modules in parallel; the default 10/50
  # limiter 429s the tail and the loader hangs. The android-emulator limiter
  # (stacks/traefik middleware.tf, 50/300) is sized for exactly this.
  skip_default_rate_limit = true
  extra_middlewares       = ["traefik-android-emulator-rate-limit@kubernetescrd"]
}
