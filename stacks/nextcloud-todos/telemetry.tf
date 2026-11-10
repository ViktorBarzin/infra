# Telemetry for nextcloud-todos (infra ADR-0041, nextcloud-todos docs/adr/0001,
# docs/runbooks/product-analytics.md). The service sends Product events to the
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
  # dsn_nextcloud-todos is the browser form,
  # https://<key>@nextcloud-todos.viktorbarzin.me/_t/x/<project>. The service
  # uses the same key and project against the in-cluster Service.
  glitchtip_dsn     = data.vault_kv_secret_v2.glitchtip.data["dsn_nextcloud-todos"]
  glitchtip_key     = regex("^https://([^@]+)@", local.glitchtip_dsn)[0]
  glitchtip_project = regex("/([0-9]+)$", local.glitchtip_dsn)[0]

  # The Person every event names: the Authentik hashed user id (User.uid) of
  # vbarzin@gmail.com, whose Nextcloud lists (user admin) this service watches.
  # Nobody signs in to the service, so there is no request to read it from.
  telemetry_person_id = "5e9a0647161c18dc66dbbb3d9a876eced545f27cca7a24e8cf54c11beaaf6480"
}

resource "kubernetes_secret" "telemetry" {
  metadata {
    name      = "nextcloud-todos-telemetry"
    namespace = kubernetes_namespace.nextcloud_todos.metadata[0].name
  }
  data = {
    write_key  = jsondecode(data.vault_kv_secret_v2.rybbit.data["write_keys"])["nextcloud-todos"]
    sentry_dsn = "http://${local.glitchtip_key}@glitchtip.glitchtip.svc.cluster.local/${local.glitchtip_project}"
  }
}
