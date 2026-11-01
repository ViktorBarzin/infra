variable "image_tag" {
  type        = string
  default     = "latest"
  description = "Image tag used when the Deployment is (re)created. The running tag is set by the Woodpecker deploy (kubectl set image)."
}

variable "postgresql_host" { type = string }

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

# alexa-assistant: the backend of the private Alexa skill "My Assistant" on
# the London Echo, a voice front for the homelab agent. Design and decisions:
# viktor/alexa-assistant docs/plans/2026-11-01-alexa-assistant.md and its
# ADRs; runbook docs/runbooks/alexa-assistant.md (written in phase 5).
#
# Amazon calls POST /alexa directly: there is no forward-auth on the host, and
# the app checks Amazon's request signature, the skill id and the bound Alexa
# account on every request. The status page (/) uses the app-side Authentik
# sign-in like every tanstack_app. The host is in the traefik stack's
# appsec_crs_exclude_hosts, because request bodies are free-text utterances.
#
# secret/alexa-assistant in Vault KV holds better_auth_secret, oidc_client_id,
# oidc_client_secret, agent_api_token (the `alexa` Caller's token, the same
# value as secret/terminal-lobby agent_api_alexa_token) and alexa_skill_id,
# seeded 2026-11-01. ha_webhook_url is added in phase 2 with the HA config.
module "app" {
  source = "../../modules/kubernetes/tanstack_app"

  name         = "alexa-assistant"
  display_name = "Alexa assistant"
  tier         = local.tiers.aux

  # PRIVATE ghcr package (the docs name the household): the namespace is in
  # the kyverno stack's ghcr_private_namespaces, which clones ghcr-credentials.
  image              = "ghcr.io/viktorbarzin/alexa-assistant"
  image_tag          = var.image_tag
  image_pull_secrets = ["ghcr-credentials"]

  postgresql_host = var.postgresql_host
  tls_secret_name = var.tls_secret_name

  app_secret_env = {
    AGENT_API_TOKEN = "agent_api_token"
    ALEXA_SKILL_ID  = "alexa_skill_id"
  }
  extra_env = [
    # Pods resolve *.viktorbarzin.me to the Traefik LB, so this reaches
    # agent-api through Traefik's terminal-api routes, as wa-bot does.
    { name = "AGENT_API_URL", value = "https://terminal-api.viktorbarzin.me" },
  ]
  emit_group_env = true

  initial_user_pks  = [data.authentik_user.viktor.id]
  admin_user_pks    = [data.authentik_user.viktor.id]
  reader_managed_by = "infra/stacks/alexa-assistant/authentik.tf"

  ingress = {
    homepage_description = "Alexa skill backend: voice front for the homelab agent"
    homepage_icon        = "mdi-microphone-message"
    homepage_group       = "Smart Home"
  }
}
