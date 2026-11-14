# Telemetry for plotting-book (infra ADR-0041, Plotting-Your-Dream-Book
# docs/adr/2026-11-10-telemetry-in-the-browser.md,
# docs/runbooks/product-analytics.md). The Express server sends Product events
# to the Event pipeline in rybbit and errors to GlitchTip, both over the
# cluster network rather than the public Ingest path. The browser gets the
# write key from the server (GET /api/telemetry).

data "vault_kv_secret_v2" "rybbit" {
  mount = "secret"
  name  = "rybbit"
}

data "vault_kv_secret_v2" "glitchtip" {
  mount = "secret"
  name  = "glitchtip"
}

locals {
  # dsn_plotting-book is the browser form,
  # https://<key>@plotting-book.viktorbarzin.me/_t/x/<project>. The server
  # uses the same key and project against the in-cluster Service.
  glitchtip_dsn     = data.vault_kv_secret_v2.glitchtip.data["dsn_plotting-book"]
  glitchtip_key     = regex("^https://([^@]+)@", local.glitchtip_dsn)[0]
  glitchtip_project = regex("/([0-9]+)$", local.glitchtip_dsn)[0]
}

resource "kubernetes_secret" "telemetry" {
  metadata {
    name      = "plotting-book-telemetry"
    namespace = local.namespace
  }
  data = {
    write_key  = jsondecode(data.vault_kv_secret_v2.rybbit.data["write_keys"])["plotting-book"]
    sentry_dsn = "http://${local.glitchtip_key}@glitchtip.glitchtip.svc.cluster.local/${local.glitchtip_project}"
  }
}
