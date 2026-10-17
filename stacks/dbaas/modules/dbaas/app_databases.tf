# App databases on the shared CNPG cluster (ADR-0001 in ~/code/docs/adr,
# "Provisioning"). One entry per app; the key is the database name and the
# owner role (underscores). The role starts with a placeholder password that
# the Vault static role pg-<app> (stacks/vault app_db_roles.tf, pg_app_roles)
# rotates on its first run.
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
  }
}

resource "null_resource" "pg_app_db" {
  for_each   = local.app_databases
  depends_on = [null_resource.pg_cluster]

  # Exactly these two keys: a change here replaces the resource and re-runs
  # the script.
  triggers = {
    db_name  = each.key
    username = each.key
  }

  provisioner "local-exec" {
    command = <<-EOT
      PRIMARY=$(kubectl --kubeconfig ${var.kube_config_path} get cluster -n dbaas ${var.pg_active_cluster} -o jsonpath='{.status.currentPrimary}')
      kubectl --kubeconfig ${var.kube_config_path} exec -n dbaas $PRIMARY -c postgres -- \
        bash -c '
          psql -U postgres -tc "SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '"'"'${each.key}'"'"'" | grep -q 1 || \
            psql -U postgres -c "CREATE ROLE ${each.key} WITH LOGIN PASSWORD '"'"'changeme-vault-will-rotate'"'"'"
          psql -U postgres -tc "SELECT 1 FROM pg_catalog.pg_database WHERE datname = '"'"'${each.key}'"'"'" | grep -q 1 || \
            psql -U postgres -c "CREATE DATABASE ${each.key} OWNER ${each.key}"
          psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE ${each.key} TO ${each.key}"
        '
    EOT
  }
}
