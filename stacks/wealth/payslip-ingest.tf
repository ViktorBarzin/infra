# wealth's payslip connector reads payslip-ingest's read API
# (GET /api/v1/payslips?owner=<id>, cluster-internal at
# http://payslip-ingest.payslip-ingest.svc.cluster.local:8080) with a
# bearer token. The token lives once in Vault, secret/payslip-ingest
# `read_api_token`; stacks/payslip-ingest gives it to payslip-ingest as
# READ_API_BEARER_TOKEN, and this ExternalSecret gives it to wealth as the
# Secret `wealth-payslip-ingest`, key PAYSLIP_INGEST_TOKEN.
#
# Only the connector worker needs it, so the web Deployment does not read
# it. The worker Deployment (src/server/jobs/README.md in the wealth repo)
# takes it with env_from or a secret_key_ref on this Secret.
resource "kubernetes_manifest" "payslip_ingest_token" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "wealth-payslip-ingest"
      namespace = "wealth"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "wealth-payslip-ingest"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
        }
      }
      data = [{
        secretKey = "PAYSLIP_INGEST_TOKEN"
        remoteRef = {
          key      = "payslip-ingest"
          property = "read_api_token"
        }
      }]
    }
  }
  depends_on = [module.app]
}
