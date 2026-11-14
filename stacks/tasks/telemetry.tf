# Telemetry for tasks (infra ADR-0041, app-kit ADR-0002,
# docs/runbooks/product-analytics.md). The server sends Product events to the
# Event pipeline in rybbit and errors to GlitchTip over the cluster network;
# the browser sends through the Ingest path on its own host, so it gets the
# public DSN. The module reads these keys through secret_env (main.tf).

data "vault_kv_secret_v2" "rybbit" {
  mount = "secret"
  name  = "rybbit"
}

data "vault_kv_secret_v2" "glitchtip" {
  mount = "secret"
  name  = "glitchtip"
}

locals {
  # dsn_tasks is the browser form,
  # https://<key>@tasks.viktorbarzin.me/_t/x/<project>. The server uses the
  # same key and project against the in-cluster Service.
  glitchtip_dsn     = data.vault_kv_secret_v2.glitchtip.data["dsn_tasks"]
  glitchtip_key     = regex("^https://([^@]+)@", local.glitchtip_dsn)[0]
  glitchtip_project = regex("/([0-9]+)$", local.glitchtip_dsn)[0]

  telemetry_secret = "tasks-telemetry"
  telemetry_env = [
    { name = "TELEMETRY_HOST", value = "http://event-pipeline.rybbit.svc.cluster.local" },
    { name = "TELEMETRY_ENVIRONMENT", value = "production" },
  ]
  telemetry_secret_env = [
    { name = "TELEMETRY_WRITE_KEY", secret = local.telemetry_secret, key = "write_key" },
    { name = "SENTRY_DSN", secret = local.telemetry_secret, key = "sentry_dsn" },
    { name = "SENTRY_BROWSER_DSN", secret = local.telemetry_secret, key = "sentry_browser_dsn" },
  ]
}

resource "kubernetes_secret" "telemetry" {
  metadata {
    name      = local.telemetry_secret
    namespace = module.app.namespace
  }
  data = {
    write_key          = jsondecode(data.vault_kv_secret_v2.rybbit.data["write_keys"])["tasks"]
    sentry_dsn         = "http://${local.glitchtip_key}@glitchtip.glitchtip.svc.cluster.local/${local.glitchtip_project}"
    sentry_browser_dsn = local.glitchtip_dsn
  }
}
