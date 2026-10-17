variable "image_tag" {
  type        = string
  default     = "482bd42e"
  description = "Image tag used when the Deployment is (re)created. The running tag is set by the Woodpecker deploy (kubectl set image)."
}

variable "postgresql_host" { type = string }

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

# tasks on the shared first-party app module (ADR-0001 in ~/code/docs/adr,
# modules/kubernetes/tanstack_app/README.md). The module owns the namespace,
# ExternalSecrets, Deployment with the `migrate` init container, Service,
# ingress, NetworkPolicy and the Authentik application, groups and tokens.
#
# secret/tasks in Vault KV holds better_auth_secret, oidc_client_id and
# oidc_client_secret (seeded by hand on 2026-10-16), and fernet_key, which
# encrypts the per-user Nextcloud app passwords stored in the Connected
# Accounts table (tasks ADR-0002). The `tasks` database and the Vault static
# role pg-tasks come from the dbaas app_databases and vault pg_app_roles maps.
module "app" {
  source = "../../modules/kubernetes/tanstack_app"

  name         = "tasks"
  display_name = "Tasks"
  tier         = local.tiers.aux

  # ADR-0002: built by GitHub Actions in the tasks repo and pushed to a public
  # ghcr package, so pulls are anonymous.
  image     = "ghcr.io/viktorbarzin/tasks"
  image_tag = var.image_tag

  postgresql_host = var.postgresql_host
  tls_secret_name = var.tls_secret_name

  app_secret_env = { TASKS_FERNET_KEY = "fernet_key" }
  extra_env = [
    { name = "TASKS_CALDAV_BASE_URL", value = "https://nextcloud.viktorbarzin.me/remote.php/dav" },
    { name = "TASKS_LOCAL_TZ", value = "Europe/Sofia" },
  ]
  # tasks reads AUTH_USERS_GROUP and AUTH_ADMINS_GROUP since it runs on the
  # @viktorbarzin packages; the values equal its built-in defaults.
  emit_group_env = true

  # Usernames in this instance are email addresses. On 2026-10-16 the tasks
  # database had one Connected Account, so Tasks Users was seeded with it.
  initial_user_pks  = [data.authentik_user.viktor.id]
  admin_user_pks    = [data.authentik_user.viktor.id]
  reader_managed_by = "infra/stacks/tasks/authentik.tf"

  ingress = {
    homepage_description = "Reminders-style task PWA over Nextcloud CalDAV"
    homepage_icon        = "mdi-format-list-checks"
  }
}
