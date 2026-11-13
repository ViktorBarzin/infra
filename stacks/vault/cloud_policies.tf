# Vault access for Cloud (Cloud v1 plan in the cloud repo, "How do App pods
# get secrets?"). Locals only, so tests/cloud-access.test.sh can load the exact
# policy text into a dev Vault wired to a kind cluster. The resources that use
# them are in cloud.tf.
#
# Paths (the M2 contract, point 6):
#   secret/cloud/system         written by Terraform
#                               (stacks/authentik/cloud-apps.tf): the shared
#                               Authentik client for private Apps
#                               (cloud_apps_client_id, cloud_apps_client_secret)
#                               and ghcr_pull_token, plus M5 keys Viktor writes
#                               by hand and Terraform carries over (App secrets
#                               key pair, build tokens). The reconciler reads it and
#                               cannot change it; no Project's SecretStore can
#                               read it, since it sits outside every p-* tree.
#   secret/cloud/<namespace>/<service>
#                               a Service's secrets: an App's own (created empty
#                               by the reconciler, filled through Cloud's API)
#                               or a Postgres Service's credentials.
#   secret/cloud/<namespace>/_cloud/...
#                               Cloud's own entries for the Project: the
#                               registry pull token and each private App's
#                               oauth2-proxy secrets (a copy of the shared
#                               client secret and the App's own cookie secret).
#                               A Service name starts with a letter, so it
#                               never collides.
# <namespace> is p-<project>. The reconciler writes only under p-*; each
# namespace's SecretStore reads only its own tree. Both trees are owned by
# Cloud, not this repo (AGENTS.md, "Cloud-owned objects"), except
# secret/cloud/system.

locals {
  # Kubernetes auth role cloud-reconciler (service account cloud-reconciler in
  # namespace cloud). Write on the Project trees (secret/cloud/p-*), read on
  # secret/cloud/system and on its two database credentials, nothing else: no
  # policy, auth role or other secret path. It deletes through the metadata
  # path (delete_all_versions in Cloud's modules). `patch` (M5): App secrets
  # are written as KV v2 merge patches, so the keys a write does not name
  # stay. Only on the Project trees; secret/cloud/system stays read-only.
  cloud_reconciler_policy = <<-EOT
    path "secret/data/cloud/p-*" {
      capabilities = ["create", "read", "update", "patch", "delete"]
    }
    path "secret/metadata/cloud/p-*" {
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
  # secret/cloud/p-x/* (its Services' entries and its _cloud/ entries; the
  # glob crosses "/") and nothing else. The namespace comes from the
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
