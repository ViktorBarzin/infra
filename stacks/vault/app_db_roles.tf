# Vault static roles for app databases (ADR-0001 in ~/code/docs/adr,
# "Provisioning"). The databases and roles come from the dbaas app_databases
# map. Each role pg-<key> is also appended to the postgresql connection's
# allowed_roles in main.tf.
#
# A variable with a default rather than a local, because the entries mix
# rotation_period and rotation_schedule and optional() fills the gaps with null.
# New apps use a schedule with a window, e.g.
#   myapp = { username = "myapp", rotation_schedule = "0 10 * * WED", rotation_window = 3600 }
# With a window, Vault rotates a schedule slot it missed only while that slot's
# window is still open, so switching an existing role outside the window does
# not rotate at apply time.

variable "pg_app_roles" {
  description = "Vault static roles for app databases (ADR-0001, Provisioning). Key = role suffix with hyphens (pg-<key>)."
  type = map(object({
    username          = string
    rotation_period   = optional(number)
    rotation_schedule = optional(string)
    rotation_window   = optional(number)
  }))
  default = {
    # tasks stays on its 7-day period. Moving it to a schedule is a planned
    # update of the role, kept out of the zero-change move.
    tasks = { username = "tasks", rotation_period = 604800 }
  }
}

# Consumed by each app's `<name>-db-creds` ExternalSecret
# (remoteRef static-creds/pg-<key>), mounted as a file the app reads on every
# new connection.
resource "vault_database_secret_backend_static_role" "pg_app" {
  for_each          = var.pg_app_roles
  backend           = vault_mount.database.path
  db_name           = vault_database_secret_backend_connection.postgresql.name
  name              = "pg-${each.key}"
  username          = each.value.username
  rotation_period   = each.value.rotation_period
  rotation_schedule = each.value.rotation_schedule
  rotation_window   = each.value.rotation_window
}

moved {
  from = vault_database_secret_backend_static_role.pg_tasks
  to   = vault_database_secret_backend_static_role.pg_app["tasks"]
}
