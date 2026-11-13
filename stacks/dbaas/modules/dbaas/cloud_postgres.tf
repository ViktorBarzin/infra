# Cloud's fixed Postgres roles and the cloud_state database, on the primary of
# var.pg_active_cluster. The SQL and the pg_hba rules are locals in
# cloud_postgres_rules.tf (tested by tests/cloud-postgres.test.sh); the pg_hba
# rules reach the cluster through null_resource.pg_cluster_v18 in main.tf.
#
#   cloud_projects     NOLOGIN group; every Project role the reconciler creates
#                      is a member, for grants only. pg_hba keeps each p_*
#                      role in the database of its own name by matching the
#                      name, not this group.
#   cloud_provisioner  LOGIN CREATEDB CREATEROLE, CONNECTION LIMIT 5, ADMIN
#                      OPTION on cloud_projects. Vault static role
#                      pg-cloud-provisioner. The reconciler stays within 5:
#                      OpenTofu -parallelism=2, each operation holding at
#                      most 2 of a provider pool of 3 (4), plus its
#                      database-size loop (1); databases.md has the budget.
#                      A second replica needs a higher limit.
#   cloud_state        LOGIN, CONNECTION LIMIT 10, owns database cloud_state
#                      (the reconciler's OpenTofu state, one schema per
#                      Project). Vault static role pg-cloud-state. It has no
#                      grant on terraform_state and pg_hba refuses it there.
#
# Cloud's console database (`cloud`) is the standard app_databases entry.
#
# Connection ceiling: the reconciler keeps the sum of the CONNECTION LIMITs of
# all Project roles at or under 20, each 2, 4 or 8 by Size;
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
