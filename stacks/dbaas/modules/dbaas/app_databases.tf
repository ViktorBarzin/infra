# App databases on the shared CNPG cluster (ADR-0001 in app-kit docs/adr,
# "Provisioning"). One entry per app; the key is the database name and the
# owner role (underscores). The role starts with a placeholder password that
# the Vault static role pg-<app> (stacks/vault app_db_roles.tf, pg_app_roles)
# rotates on its first run. `{ owner = "<role>" }` makes the database owned by
# another entry's role instead, for an app that needs two databases under one
# user (prowlarr).
#
# Adding `<db> = {}` creates one null_resource on the next dbaas apply, which
# runs the script below once. Provisioners run only on create, and a
# null_resource is replaced only when its triggers change, so editing the
# script never re-runs it for existing entries.
#
# Other per-app databases in main.tf keep their own null_resource for now. The
# uniform ones can join this map with a one-line moved block each;
# nextcloud_todos (schema plus search_path) and verify_probe (grants) do not
# fit this shape.

locals {
  app_databases = {
    # tasks PWA (TanStack Start, ~/code/tasks). Drizzle migrations run from the
    # app's `migrate` init container.
    tasks = {}
    # alexa-assistant (TanStack Start, Forgejo viktor/alexa-assistant): the
    # London Echo skill's state and its pg-boss queue (schema pgboss).
    alexa_assistant = {}
    # Cloud's console (TanStack Start, Forgejo viktor/cloud): Users, Projects,
    # Budgets and the change history. Project databases are not in this map;
    # Cloud's reconciler creates them as cloud_provisioner (cloud_postgres.tf).
    cloud = {}
    # GlitchTip error tracker (stacks/glitchtip, ADR-0041). Migrations run
    # from the deployment's `migrate` init container.
    glitchtip = {}
    # learning (Python, ~/code/learning). Tables come from SQLAlchemy
    # create_all at app start. Moved off SQLite on a block volume 2026-11-09.
    learning = {}
    # ntfy (stacks/ntfy): users, access rules, tokens, and the message cache if
    # one is ever enabled. ntfy creates its own schema on start (database-url,
    # v2.18+). Moved off SQLite on a block volume 2026-11-09 with ntfy's pgimport.
    ntfy = {}
    # prowlarr (stacks/servarr/prowlarr) needs a main and a log database
    # reachable by one user, so prowlarr_log is owned by the prowlarr role.
    prowlarr     = {}
    prowlarr_log = { owner = "prowlarr" }
    # reels (TanStack Start web app + Python worker, Forgejo viktor/trip-reel):
    # trips, cuts, renders and the job queue between them. Drizzle migrations
    # run from the web app's `migrate` init container.
    reels = {}
    # vermont-access (stacks/vermont-access, infra#176): two years of the
    # Vermont complex access-control events. The weekly CronJob creates its
    # table with CREATE TABLE IF NOT EXISTS.
    vermont_access = {}
  }
}

resource "null_resource" "pg_app_db" {
  for_each   = local.app_databases
  depends_on = [null_resource.pg_cluster]

  # Exactly these two keys: a change here replaces the resource and re-runs
  # the script.
  triggers = {
    db_name  = each.key
    username = lookup(each.value, "owner", each.key)
  }

  lifecycle {
    # The key goes unquoted into CREATE ROLE / CREATE DATABASE. A dashed app
    # slug (my-app) needs the underscore form (my_app) here.
    precondition {
      condition     = can(regex("^[a-z][a-z0-9_]*$", each.key))
      error_message = "app_databases keys are Postgres identifiers: lowercase letters, digits and underscores, starting with a letter (use my_app for the slug my-app)."
    }
  }

  provisioner "local-exec" {
    command = <<-EOT
      PRIMARY=$(kubectl --kubeconfig ${var.kube_config_path} get cluster -n dbaas ${var.pg_active_cluster} -o jsonpath='{.status.currentPrimary}')
      kubectl --kubeconfig ${var.kube_config_path} exec -n dbaas $PRIMARY -c postgres -- \
        bash -c '
          psql -U postgres -tc "SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '"'"'${lookup(each.value, "owner", each.key)}'"'"'" | grep -q 1 || \
            psql -U postgres -c "CREATE ROLE ${lookup(each.value, "owner", each.key)} WITH LOGIN PASSWORD '"'"'changeme-vault-will-rotate'"'"'"
          psql -U postgres -tc "SELECT 1 FROM pg_catalog.pg_database WHERE datname = '"'"'${each.key}'"'"'" | grep -q 1 || \
            psql -U postgres -c "CREATE DATABASE ${each.key} OWNER ${lookup(each.value, "owner", each.key)}"
          psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE ${each.key} TO ${lookup(each.value, "owner", each.key)}"
        '
    EOT
  }
}
