# Telemetry for wrongmove (infra ADR-0041, docs/runbooks/product-analytics.md;
# realestate-crawler docs/adr/0004-product-events.md). The API sends Product
# events to the Event pipeline in rybbit, and the API and Celery processes send
# errors to GlitchTip, both over the cluster network rather than the public
# Ingest path.

data "vault_kv_secret_v2" "rybbit" {
  mount = "secret"
  name  = "rybbit"
}

data "vault_kv_secret_v2" "glitchtip" {
  mount = "secret"
  name  = "glitchtip"
}

locals {
  # dsn_wrongmove is the browser form, https://<key>@wrongmove.viktorbarzin.me/_t/x/<id>.
  # The backend uses the same key and project against the in-cluster Service.
  glitchtip_wrongmove_key     = regex("^https://([^@]+)@", data.vault_kv_secret_v2.glitchtip.data["dsn_wrongmove"])[0]
  glitchtip_wrongmove_project = regex("/([0-9]+)$", data.vault_kv_secret_v2.glitchtip.data["dsn_wrongmove"])[0]
}

resource "kubernetes_secret" "wrongmove_telemetry" {
  metadata {
    name      = "wrongmove-telemetry"
    namespace = kubernetes_namespace.realestate-crawler.metadata[0].name
  }
  data = {
    write_key  = jsondecode(data.vault_kv_secret_v2.rybbit.data["write_keys"])["wrongmove"]
    sentry_dsn = "http://${local.glitchtip_wrongmove_key}@glitchtip.glitchtip.svc.cluster.local/${local.glitchtip_wrongmove_project}"
  }
}
