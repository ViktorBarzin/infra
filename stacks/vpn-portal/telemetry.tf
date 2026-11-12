# Telemetry for vpn-portal (infra ADR-0041, vpn-portal
# docs/adr/2026-11-10-telemetry-in-the-browser.md,
# docs/runbooks/product-analytics.md). The server sends Product events to the
# Event pipeline in rybbit and errors to GlitchTip, both over the cluster
# network rather than the public Ingest path. The browser gets the write key
# from the server at page load.

data "vault_kv_secret_v2" "rybbit" {
  mount = "secret"
  name  = "rybbit"
}

data "vault_kv_secret_v2" "glitchtip" {
  mount = "secret"
  name  = "glitchtip"
}

locals {
  # dsn_vpn-portal is the browser form,
  # https://<key>@vpn.viktorbarzin.me/_t/x/<project>. The server uses the same
  # key and project against the in-cluster Service.
  glitchtip_dsn     = data.vault_kv_secret_v2.glitchtip.data["dsn_vpn-portal"]
  glitchtip_key     = regex("^https://([^@]+)@", local.glitchtip_dsn)[0]
  glitchtip_project = regex("/([0-9]+)$", local.glitchtip_dsn)[0]
}

resource "kubernetes_secret" "telemetry" {
  metadata {
    name      = "vpn-portal-telemetry"
    namespace = kubernetes_namespace.vpn_portal.metadata[0].name
  }
  data = {
    write_key  = jsondecode(data.vault_kv_secret_v2.rybbit.data["write_keys"])["vpn-portal"]
    sentry_dsn = "http://${local.glitchtip_key}@glitchtip.glitchtip.svc.cluster.local/${local.glitchtip_project}"
  }
}
