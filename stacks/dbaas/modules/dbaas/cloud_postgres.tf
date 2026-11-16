# Cloud's fixed Postgres roles and the cloud_state database, on the primary of
# var.pg_active_cluster. The SQL and the pg_hba rules are locals in
# cloud_postgres_rules.tf (tested by tests/cloud-postgres.test.sh); the pg_hba
# rules reach the cluster through null_resource.pg_cluster_v18 in main.tf.
#
#   cloud_projects     NOLOGIN group; every Project role the reconciler creates
#                      is a member, for grants only. pg_hba keeps each p_*
#                      role in the database of its own name by matching the
#                      name, not this group.
#   cloud_provisioner  LOGIN CREATEDB CREATEROLE, CONNECTION LIMIT 10, ADMIN
#                      OPTION on cloud_projects. Vault static role
#                      pg-cloud-provisioner. Each reconciler worker's
#                      OpenTofu holds at most 4 (-parallelism=2, each
#                      operation at most 2 of a provider pool of 3), plus the
#                      database-size loop (1): 2 workers (Cloud backlog B24)
#                      use 9 of 10. databases.md has the budget.
#   cloud_state        LOGIN, CONNECTION LIMIT 10, owns database cloud_state
#                      (the reconciler's OpenTofu state, one schema per
#                      Project). Vault static role pg-cloud-state. It has no
#                      grant on terraform_state and pg_hba refuses it there.
#
# Cloud's console database (`cloud`) is the standard app_databases entry.
#
# Connection ceiling: the reconciler keeps the sum of the CONNECTION LIMITs of
# all Project roles at or under 80, each 4, 8 or 16 by Size;
# docs/agents/databases.md ("Cloud on the shared CNPG cluster") shows the
# arithmetic. Postgres cannot enforce a sum, so an audit pages when it does not
# hold (local.cloud_role_limits_audit_sql in cloud_postgres_rules.tf).
#
# The script reruns whenever the SQL text changes. It is idempotent and sets no
# password, so a rerun never undoes a Vault rotation.
resource "null_resource" "pg_cloud_roles" {
  depends_on = [null_resource.pg_cluster_v18]

  triggers = {
    sql_sha1 = sha1(local.cloud_roles_sql)
    cluster  = var.pg_active_cluster
  }

  provisioner "local-exec" {
    environment = {
      CLOUD_ROLES_SQL = local.cloud_roles_sql
    }
    command = <<-EOT
      set -e
      PRIMARY=$(kubectl --kubeconfig ${var.kube_config_path} get cluster -n dbaas ${var.pg_active_cluster} -o jsonpath='{.status.currentPrimary}')
      printf '%s\n' "$CLOUD_ROLES_SQL" | kubectl --kubeconfig ${var.kube_config_path} exec -i -n dbaas "$PRIMARY" -c postgres -- \
        psql -U postgres -v ON_ERROR_STOP=1 -X -q -f -
    EOT
  }
}
