# ha-london's recorder (Home Assistant history) on the shared CNPG cluster,
# since 2026-11-28, to take the history writes off the London Pi's SD card
# (docs/architecture/london-site.md, "History (recorder)").
#
# A static role, not an app_databases entry: the Pi keeps its db_url in its
# own secrets.yaml and cannot follow the Tuesday Vault rotation. The password
# is Vault secret/viktor pg_ha_london_password. Changing it there re-runs this
# provisioner, which sets the new password; then update the Pi's secrets.yaml.
# The Pi reaches Postgres through postgresql-lb (10.0.20.200:5432) with the
# Flint's infra-ha role (scripts/london-flint/london-roles.sh).

variable "pg_ha_london_password" {
  type      = string
  sensitive = true
}

resource "null_resource" "pg_ha_london" {
  depends_on = [null_resource.pg_cluster]

  triggers = {
    db_name       = "ha_london"
    username      = "ha_london"
    password_hash = sha256(var.pg_ha_london_password)
    # Bump to re-run the script after changing it.
    script = "2"
  }

  # The password goes to psql on stdin, so it is not in any process's argv.
  # CONNECTION LIMIT 20: the recorder's writer, its read executor and the
  # watchdog's SQL sensor use a handful. cnpg_metrics_exporter needs
  # SELECT on states for the ha_london_recorder query (pg_custom_queries in
  # main.tf); the default privilege gives it SELECT on the tables HA creates
  # after a rebuild, which is the only way to cover a states table that does
  # not exist yet.
  provisioner "local-exec" {
    command = <<-EOT
      PRIMARY=$(kubectl --kubeconfig ${var.kube_config_path} get cluster -n dbaas ${var.pg_active_cluster} -o jsonpath='{.status.currentPrimary}')
      kubectl --kubeconfig ${var.kube_config_path} exec -i -n dbaas $PRIMARY -c postgres -- \
        psql -U postgres -v ON_ERROR_STOP=1 <<'SQL'
      SELECT 'CREATE ROLE ha_london LOGIN CONNECTION LIMIT 20'
        WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ha_london')\gexec
      ALTER ROLE ha_london WITH LOGIN CONNECTION LIMIT 20 PASSWORD '${var.pg_ha_london_password}';
      SELECT 'CREATE DATABASE ha_london OWNER ha_london'
        WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'ha_london')\gexec
      REVOKE CONNECT ON DATABASE ha_london FROM PUBLIC;
      GRANT ALL PRIVILEGES ON DATABASE ha_london TO ha_london;
      GRANT CONNECT ON DATABASE ha_london TO cnpg_metrics_exporter;
      \c ha_london
      ALTER DEFAULT PRIVILEGES FOR ROLE ha_london IN SCHEMA public GRANT SELECT ON TABLES TO cnpg_metrics_exporter;
      SELECT 'GRANT SELECT ON public.states TO cnpg_metrics_exporter'
        WHERE to_regclass('public.states') IS NOT NULL\gexec
      SQL
    EOT
  }
}
