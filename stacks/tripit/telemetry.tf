# Telemetry for tripit (infra ADR-0041, tripit ADR-0076 and ADR-0077,
# docs/runbooks/product-analytics.md). The backend sends Product events to the
# Event pipeline in rybbit and errors to GlitchTip, both over the cluster
# network rather than the public Ingest path. The Deployment, the mail listener
# and every worker CronJob read this Secret through an optional env_from, so a
# missing Secret changes nothing, and Reloader restarts the long-running pods
# when it changes.

data "vault_kv_secret_v2" "rybbit" {
  mount = "secret"
  name  = "rybbit"
}

data "vault_kv_secret_v2" "glitchtip" {
  mount = "secret"
  name  = "glitchtip"
}

locals {
  # dsn_tripit is the browser form, https://<key>@tripit.viktorbarzin.me/_t/x/<id>.
  # The backend uses the same key and project against the in-cluster Service.
  glitchtip_tripit_key     = regex("^https://([^@]+)@", data.vault_kv_secret_v2.glitchtip.data["dsn_tripit"])[0]
  glitchtip_tripit_project = regex("/([0-9]+)$", data.vault_kv_secret_v2.glitchtip.data["dsn_tripit"])[0]
}

resource "kubernetes_secret" "tripit_telemetry" {
  metadata {
    name      = "tripit-telemetry"
    namespace = kubernetes_namespace.tripit.metadata[0].name
    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }
  # Keys are the env var names: containers take the whole Secret with env_from.
  data = {
    TELEMETRY_WRITE_KEY = jsondecode(data.vault_kv_secret_v2.rybbit.data["write_keys"])["tripit"]
    SENTRY_DSN          = "http://${local.glitchtip_tripit_key}@glitchtip.glitchtip.svc.cluster.local/${local.glitchtip_tripit_project}"
  }
}
