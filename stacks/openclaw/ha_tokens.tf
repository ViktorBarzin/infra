# Dedicated secret holding ONLY the Home Assistant API tokens, split out of
# openclaw-secrets so the `homelab ha token` CLI verb can serve non-admin
# operators (emo = emil.barzin@gmail.com, group "Home Server Admins") WITHOUT
# granting them read on the full skill_secrets blob (which also carries
# slack_webhook + uptime_kuma_password). openclaw's own deployment keeps reading
# openclaw-secrets — this is purely an additive, least-privilege carve-out for
# the CLI. See infra/cli/cmd_ha.go + docs/adr/0012.
resource "kubernetes_secret" "ha_tokens" {
  metadata {
    name      = "ha-tokens"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
  data = {
    # keys match the homelab `ha token --instance <sofia|london>` mapping
    sofia  = local.skill_secrets["home_assistant_sofia_token"]
    london = local.skill_secrets["home_assistant_token"]
  }
  type = "Opaque"
}

# get on JUST the ha-tokens secret (resource_names pins it to this one object),
# bound to the "Home Server Admins" OIDC group — the group emo authenticates
# into. Scope deliberately excludes openclaw-secrets and every other secret.
resource "kubernetes_role" "ha_tokens_reader" {
  metadata {
    name      = "ha-tokens-reader"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = [kubernetes_secret.ha_tokens.metadata[0].name]
    verbs          = ["get"]
  }
}

resource "kubernetes_role_binding" "ha_tokens_reader" {
  metadata {
    name      = "ha-tokens-reader"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.ha_tokens_reader.metadata[0].name
  }
  subject {
    kind      = "Group"
    name      = "Home Server Admins"
    api_group = "rbac.authorization.k8s.io"
  }
}
