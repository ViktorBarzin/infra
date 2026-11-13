# Vault access for Cloud (Cloud v1 plan in the cloud repo, "How do App pods
# get secrets?"). Locals only, so tests/cloud-access.test.sh can load the exact
# policy text into a dev Vault wired to a kind cluster. The resources that use
# them are in cloud.tf.
#
# Paths:
#   secret/cloud/system         the reconciler's own credentials, written by
#                               Terraform (stacks/authentik/cloud-reconciler.tf);
#                               the reconciler reads it and cannot change it.
#   secret/cloud/<namespace>/*  one tree per Project namespace (p-<project>),
#                               written by the reconciler, read by that
#                               namespace's SecretStore and by nothing else.
# Both trees are owned by Cloud, not this repo (AGENTS.md, "Cloud-owned
# objects"), except secret/cloud/system.

locals {
  # Kubernetes auth role cloud-reconciler (service account cloud-reconciler in
  # namespace cloud). Write on the Cloud tree, read on its two database
  # credentials, nothing else: no policy, auth role or other secret path.
  # The exact secret/cloud/system paths are more specific than the globs, so
  # Vault applies their read-only grant there.
  cloud_reconciler_policy = <<-EOT
    path "secret/data/cloud/*" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "secret/metadata/cloud/*" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "secret/data/cloud/system" {
      capabilities = ["read"]
    }
    path "secret/metadata/cloud/system" {
      capabilities = ["read"]
    }
    path "database/static-creds/pg-cloud-provisioner" {
      capabilities = ["read"]
    }
    path "database/static-creds/pg-cloud-state" {
      capabilities = ["read"]
    }
  EOT

  # Kubernetes auth role cloud-project: one templated policy for every Project.
  # The token of service account cloud-secrets in namespace p-x reads
  # secret/cloud/p-x/* and nothing else. The namespace comes from the
  # Kubernetes auth alias metadata that Vault filled in at login, so a pod
  # cannot choose it. cloud.tf replaces @@KUBERNETES_ACCESSOR@@ with the
  # accessor of the kubernetes auth mount.
  cloud_project_policy_template = <<-EOT
    path "secret/data/cloud/{{identity.entity.aliases.@@KUBERNETES_ACCESSOR@@.metadata.service_account_namespace}}/*" {
      capabilities = ["read"]
    }
  EOT

  # Which namespaces may log in to cloud-project. Vault reads the namespace's
  # labels at login, so it needs `get` on namespaces (vault_namespace_reader).
  cloud_project_namespace_selector = jsonencode({
    matchLabels = { "cloud.viktorbarzin.me/managed" = "true" }
  })

  # Bound to the vault service account. The kubernetes auth mount uses
  # Vault's own pod token (disable_local_ca_jwt = false) both to review login
  # tokens and to read the namespace for bound_service_account_namespace_selector.
  # Without this rule, every cloud-project login fails.
  vault_namespace_reader_rules = [
    { api_groups = [""], resources = ["namespaces"], verbs = ["get"] },
  ]
}
