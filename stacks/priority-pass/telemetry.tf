# Telemetry for priority-pass (infra ADR-0041, priority-pass docs/adr/0001,
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
  # dsn_priority-pass is the browser form,
  # https://<key>@priority-pass.viktorbarzin.me/_t/x/<project>. The backend
  # uses the same key and project against the in-cluster Service.
  glitchtip_dsn     = data.vault_kv_secret_v2.glitchtip.data["dsn_priority-pass"]
  glitchtip_key     = regex("^https://([^@]+)@", local.glitchtip_dsn)[0]
  glitchtip_project = regex("/([0-9]+)$", local.glitchtip_dsn)[0]
}

resource "kubernetes_secret" "telemetry" {
  metadata {
    name      = "priority-pass-telemetry"
    namespace = kubernetes_namespace.priority-pass.metadata[0].name
  }
  data = {
    write_key  = jsondecode(data.vault_kv_secret_v2.rybbit.data["write_keys"])["priority-pass"]
    sentry_dsn = "http://${local.glitchtip_key}@glitchtip.glitchtip.svc.cluster.local/${local.glitchtip_project}"
  }
}
