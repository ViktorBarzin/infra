# Tenant namespaces read only their own Vault path (enforced-identity plan,
# docs/plans/2026-11-15-enforced-identity-design.md, step 5).
#
# A tenant namespace is one where a person who is not an admin holds rights:
# each namespace-owner's namespaces (k8s_users), and novelapp, whose owner
# binding lives in stacks/novelapp. Until 2026-11-15 an ExternalSecret there
# could name the vault-kv ClusterSecretStore, which reads all of secret/*, so
# a namespace-owner could copy any secret into their namespace. Now vault-kv
# and vault-database refuse these namespaces (stacks/external-secrets), and
# each one gets a SecretStore that logs in as the tenant-secrets account
# through this role. The templated policy names the caller's own namespace,
# so plotting-book reads secret/plotting-book and secret/plotting-book/*,
# and nothing else. Same shape as cloud-project (cloud.tf).

locals {
  tenant_namespaces = sort(tolist(setunion(nonsensitive(local.user_namespaces), ["novelapp"])))

  tenant_secrets_policy = <<-EOT
    path "secret/data/{{identity.entity.aliases.${vault_auth_backend.kubernetes.accessor}.metadata.service_account_namespace}}" {
      capabilities = ["read"]
    }
    path "secret/data/{{identity.entity.aliases.${vault_auth_backend.kubernetes.accessor}.metadata.service_account_namespace}}/*" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_policy" "tenant_secrets" {
  name   = "tenant-secrets"
  policy = local.tenant_secrets_policy
}

resource "vault_kubernetes_auth_backend_role" "tenant_secrets" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "tenant-secrets"
  bound_service_account_names      = ["tenant-secrets"]
  bound_service_account_namespaces = local.tenant_namespaces
  token_policies                   = [vault_policy.tenant_secrets.name]
  # External Secrets logs in again for each sync it cannot serve from cache.
  token_ttl     = 3600
  token_max_ttl = 3600
}
