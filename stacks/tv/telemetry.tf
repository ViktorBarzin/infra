# Telemetry for tv, the pilot app of the analytics pipeline (infra ADR-0041,
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
  # dsn_tv is the browser form, https://<key>@tv.viktorbarzin.me/_t/x/1.
  # The backend uses the same key and project against the in-cluster Service.
  glitchtip_tv_key     = regex("^https://([^@]+)@", data.vault_kv_secret_v2.glitchtip.data["dsn_tv"])[0]
  glitchtip_tv_project = regex("/([0-9]+)$", data.vault_kv_secret_v2.glitchtip.data["dsn_tv"])[0]
}

resource "kubernetes_secret" "tv_telemetry" {
  metadata {
    name      = "tv-telemetry"
    namespace = kubernetes_namespace.tv.metadata[0].name
  }
  data = {
    write_key  = jsondecode(data.vault_kv_secret_v2.rybbit.data["write_keys"])["tv"]
    sentry_dsn = "http://${local.glitchtip_tv_key}@glitchtip.glitchtip.svc.cluster.local/${local.glitchtip_tv_project}"
  }
}
