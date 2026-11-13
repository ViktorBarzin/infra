# Vault for Cloud (Cloud v1 plan in the cloud repo; ADR-0003 there). Policy
# text is in cloud_policies.tf. What Cloud gets here, and only here:
#
#   pg-cloud-provisioner, pg-cloud-state  static roles for the reconciler's
#     Postgres logins (stacks/dbaas cloud_postgres.tf creates the roles).
#   cloud-reconciler  policy + Kubernetes auth role for service account
#     cloud-reconciler in namespace cloud.
#   cloud-project     templated policy + Kubernetes auth role for service
#     account cloud-secrets in any namespace labelled
#     cloud.viktorbarzin.me/managed=true. Every Project's SecretStore logs in
#     with it.
#
# The reconciler never writes Vault policies or auth roles; a new Project
# needs nothing from this stack.

# Same Tuesday slot for both (10:17, table in main.tf): the reconciler reads
# both credentials from Vault at the start of each run, so a rotation costs at
# most one failed run, which it retries.
resource "vault_database_secret_backend_static_role" "pg_cloud_provisioner" {
  backend           = vault_mount.database.path
  db_name           = vault_database_secret_backend_connection.postgresql.name
  name              = "pg-cloud-provisioner"
  username          = "cloud_provisioner"
  rotation_schedule = "17 10 * * TUE"
  rotation_window   = 3600
}

resource "vault_database_secret_backend_static_role" "pg_cloud_state" {
  backend           = vault_mount.database.path
  db_name           = vault_database_secret_backend_connection.postgresql.name
  name              = "pg-cloud-state"
  username          = "cloud_state"
  rotation_schedule = "17 10 * * TUE"
  rotation_window   = 3600
}

resource "vault_policy" "cloud_reconciler" {
  name   = "cloud-reconciler"
  policy = local.cloud_reconciler_policy
}

resource "vault_kubernetes_auth_backend_role" "cloud_reconciler" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "cloud-reconciler"
  bound_service_account_names      = ["cloud-reconciler"]
  bound_service_account_namespaces = ["cloud"]
  token_policies                   = [vault_policy.cloud_reconciler.name]
  # The reconciler logs in again when a token expires.
  token_ttl     = 3600
  token_max_ttl = 86400
}

resource "vault_policy" "cloud_project" {
  name   = "cloud-project"
  policy = replace(local.cloud_project_policy_template, "@@KUBERNETES_ACCESSOR@@", vault_auth_backend.kubernetes.accessor)
}

# bound_service_account_namespace_selector needs Vault 1.16+ (live: 2.2.0)
# and `get` on namespaces for Vault's service account (below). One role and
# one policy serve every Project, so the reconciler never has to create
# either.
resource "vault_kubernetes_auth_backend_role" "cloud_project" {
  backend                                  = vault_auth_backend.kubernetes.path
  role_name                                = "cloud-project"
  bound_service_account_names              = ["cloud-secrets"]
  bound_service_account_namespace_selector = local.cloud_project_namespace_selector
  token_policies                           = [vault_policy.cloud_project.name]
  # External Secrets logs in again for each sync it cannot serve from cache.
  token_ttl     = 3600
  token_max_ttl = 3600
}

resource "kubernetes_cluster_role" "vault_namespace_reader" {
  metadata { name = "vault-namespace-reader" }
  dynamic "rule" {
    for_each = local.vault_namespace_reader_rules
    content {
      api_groups = rule.value.api_groups
      resources  = rule.value.resources
      verbs      = rule.value.verbs
    }
  }
}

resource "kubernetes_cluster_role_binding" "vault_namespace_reader" {
  metadata { name = "vault-namespace-reader" }
  subject {
    kind      = "ServiceAccount"
    name      = "vault"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.vault_namespace_reader.metadata[0].name
  }
}
