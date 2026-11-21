variable "image_tag" {
  type        = string
  default     = "latest" # used only when the Deployment is created; CI sets the running tag
  description = "Image tag used when the Deployment is (re)created. The running tag is set by the Woodpecker deploy (kubectl set image)."
}

variable "postgresql_host" { type = string }

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

# Date Night: a private app that finds one new London date a week (Forgejo
# viktor/datenight; plan in that repo at docs/plans/2026-11-21-datenight-plan.md,
# why Muse drives the week in docs/adr/0001-muse-drives-the-week.md). Only
# Viktor is in Date Night Users. Meta's Muse calls /api/muse/* with a static
# bearer token, so the ingress stays open and the app checks every caller.
#
# secret/datenight in Vault KV (seeded by hand on 2026-11-21) holds
# better_auth_secret, oidc_client_id, oidc_client_secret, muse_token,
# scout_token (same value as secret/claude-agent-service datenight_scout_token),
# caldav_password (the admin Nextcloud app password, as secret/nextcloud-todos
# caldav_app_password), owner_name, owner_email, partner_name, partner_email,
# actual_api_key and actual_sync_id (actualbudget-http-api-viktor), immich_api_key
# (secret/immich frame_api_key), tripit_feed_url (Viktor's signed TripIt .ics
# feed) and home_lat, home_lon.
locals {
  vault_env = {
    MUSE_TOKEN      = "muse_token"
    SCOUT_TOKEN     = "scout_token"
    CALDAV_PASSWORD = "caldav_password" # gitleaks:allow (a Vault property name, not a value)
    OWNER_NAME      = "owner_name"
    OWNER_EMAIL     = "owner_email"
    PARTNER_NAME    = "partner_name"
    PARTNER_EMAIL   = "partner_email"
    ACTUAL_API_KEY  = "actual_api_key"
    ACTUAL_SYNC_ID  = "actual_sync_id"
    IMMICH_API_KEY  = "immich_api_key"
    TRIPIT_FEED_URL = "tripit_feed_url"
    HOME_LAT        = "home_lat"
    HOME_LON        = "home_lon"
  }
}

module "app" {
  source = "../../modules/kubernetes/tanstack_app"

  name         = "datenight"
  display_name = "Date Night"
  tier         = local.tiers.aux

  # Built by GitHub Actions in the datenight repo and pushed to a public ghcr
  # package, so pulls are anonymous.
  image     = "ghcr.io/viktorbarzin/datenight"
  image_tag = var.image_tag

  postgresql_host = var.postgresql_host
  tls_secret_name = var.tls_secret_name

  app_secret_env = local.vault_env
  extra_env = [
    { name = "SCHEDULER", value = "on" },
    { name = "SCOUT_URL", value = "http://claude-agent-restricted.claude-agent.svc.cluster.local:8080/v1/datenight/scout" },
    { name = "CALDAV_BASE_URL", value = "https://nextcloud.viktorbarzin.me/remote.php/dav" },
    { name = "CALDAV_USER", value = "admin" },
    { name = "CALDAV_CALENDAR", value = "personal" },
    { name = "NOTICING_CALENDAR", value = "noticing-file" },
    { name = "ACTUAL_URL", value = "http://budget-http-api-viktor.actualbudget.svc.cluster.local" },
    { name = "IMMICH_URL", value = "http://immich-server.immich:2283" },
  ]
  emit_group_env = true

  initial_user_pks = [data.authentik_user.viktor.id]
  admin_user_pks   = [data.authentik_user.viktor.id]

  ingress = {
    homepage_description = "One new London date a week"
    homepage_icon        = "mdi-glass-wine"
    homepage_group       = "Productivity"
  }
}
