# Telemetry for fire-planner (infra ADR-0041, fire-planner ADR-0002,
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
  # dsn_fire-planner is the browser form, https://<key>@fire-planner.viktorbarzin.me/_t/x/<id>.
  # The backend uses the same key and project against the in-cluster Service.
  glitchtip_fire_planner_key     = regex("^https://([^@]+)@", data.vault_kv_secret_v2.glitchtip.data["dsn_fire-planner"])[0]
  glitchtip_fire_planner_project = regex("/([0-9]+)$", data.vault_kv_secret_v2.glitchtip.data["dsn_fire-planner"])[0]
}

resource "kubernetes_secret" "fire_planner_telemetry" {
  metadata {
    name      = "fire-planner-telemetry"
    namespace = kubernetes_namespace.fire_planner.metadata[0].name
  }
  data = {
    write_key  = jsondecode(data.vault_kv_secret_v2.rybbit.data["write_keys"])["fire-planner"]
    sentry_dsn = "http://${local.glitchtip_fire_planner_key}@glitchtip.glitchtip.svc.cluster.local/${local.glitchtip_fire_planner_project}"
  }
}
