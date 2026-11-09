# Telemetry for health (infra ADR-0041, health ADR-0014,
# docs/runbooks/product-analytics.md). The backend sends Product events to the
# Event pipeline in rybbit and errors to GlitchTip, both over the cluster
# network rather than the public Ingest path.

data "vault_kv_secret_v2" "rybbit" {
  mount = "secret"
  name  = "rybbit"
}

data "vault_kv_secret_v2" "glitchtip" {
  mount = "secret"
  name  = "glitchtip"
}

locals {
  # dsn_health is the browser form, https://<key>@health.viktorbarzin.me/_t/x/<id>.
  # The backend uses the same key and project against the in-cluster Service.
  glitchtip_health_key     = regex("^https://([^@]+)@", data.vault_kv_secret_v2.glitchtip.data["dsn_health"])[0]
  glitchtip_health_project = regex("/([0-9]+)$", data.vault_kv_secret_v2.glitchtip.data["dsn_health"])[0]
}

resource "kubernetes_secret" "health_telemetry" {
  metadata {
    name      = "health-telemetry"
    namespace = kubernetes_namespace.health.metadata[0].name
  }
  data = {
    write_key  = jsondecode(data.vault_kv_secret_v2.rybbit.data["write_keys"])["health"]
    sentry_dsn = "http://${local.glitchtip_health_key}@glitchtip.glitchtip.svc.cluster.local/${local.glitchtip_health_project}"
  }
}
