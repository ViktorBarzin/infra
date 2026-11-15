# One SecretStore per tenant namespace (enforced-identity plan, step 5). It
# logs in to Vault as that namespace's tenant-secrets account through the
# tenant-secrets role, whose policy reads only secret/<namespace> and
# secret/<namespace>/* (stacks/vault/tenant_secrets.tf). vault-kv and
# vault-database refuse these namespaces (main.tf).
#
# The list must match stacks/vault/tenant_secrets.tf: each namespace-owner's
# namespaces from Vault secret/platform k8s_users, and novelapp.

data "vault_kv_secret_v2" "platform" {
  mount = "secret"
  name  = "platform"
}

locals {
  k8s_users = jsondecode(nonsensitive(data.vault_kv_secret_v2.platform.data["k8s_users"]))
  tenant_namespaces = sort(tolist(setunion(
    toset(flatten([for name, user in local.k8s_users : user.namespaces if user.role == "namespace-owner"])),
    ["novelapp"],
  )))
}

resource "kubernetes_service_account" "tenant_secrets" {
  for_each = toset(local.tenant_namespaces)
  metadata {
    name      = "tenant-secrets"
    namespace = each.value
  }
  automount_service_account_token = false
}

resource "kubernetes_manifest" "tenant_secret_store" {
  for_each = toset(local.tenant_namespaces)
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "SecretStore"
    metadata = {
      name      = "vault-tenant"
      namespace = each.value
    }
    spec = {
      provider = {
        vault = {
          server  = "http://vault-active.vault.svc.cluster.local:8200"
          path    = "secret"
          version = "v2"
          auth = {
            kubernetes = {
              mountPath = "kubernetes"
              role      = "tenant-secrets"
              serviceAccountRef = {
                name = kubernetes_service_account.tenant_secrets[each.value].metadata[0].name
              }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.external_secrets]
}
