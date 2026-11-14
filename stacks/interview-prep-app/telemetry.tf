# Telemetry for interview-prep (infra ADR-0041, interview-prep-app
# docs/adr/2026-11-10-telemetry-in-the-browser.md,
# docs/runbooks/product-analytics.md). The site has no server: nginx fills the
# write key into GET /api/telemetry when the container starts, and the browser
# sends its events to the public Ingest path on its own host. Browser errors
# use the build-time GlitchTip DSN, so there is no SENTRY_DSN here.

data "vault_kv_secret_v2" "rybbit" {
  mount = "secret"
  name  = "rybbit"
}

resource "kubernetes_secret" "telemetry" {
  metadata {
    name      = "interview-prep-app-telemetry"
    namespace = kubernetes_namespace.interview-prep-app.metadata[0].name
  }
  data = {
    write_key = jsondecode(data.vault_kv_secret_v2.rybbit.data["write_keys"])["interview-prep"]
  }
}
