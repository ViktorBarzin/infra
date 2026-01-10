
resource "kubernetes_namespace" "kyverno" {
  metadata {
    name = "kyverno"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

resource "helm_release" "kyverno" {
  namespace        = kubernetes_namespace.kyverno.metadata[0].name
  create_namespace = false
  name             = "kyverno"
  atomic           = true

  repository = "https://kyverno.github.io/kyverno/"
  chart      = "kyverno"

  #   values = [templatefile("${path.module}/grafana_chart_values.yaml", { db_password = var.grafana_db_password })]
}

# To unlabel all:
# kubectl label deployment,statefulset,daemonset --all-namespaces -l tier tier-
resource "kubernetes_manifest" "mutate_tier_from_namespace" {
  manifest = {
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "sync-tier-label-from-namespace"
    }
    spec = {
      rules = [
        {
          name = "lookup-and-add-tier"
          match = {
            any = [
              {
                resources = {
                  kinds = ["Deployment", "StatefulSet", "DaemonSet"]
                }
              }
            ]
          }
          exclude = {
            any = [
              {
                resources = {
                  namespaces = ["kube-system", "metallb-system", "n8n"]
                }
              }
            ]
          }
          # Context allows us to perform an API call to get Namespace metadata
          context = [
            {
              name = "namespaceLabel"
              apiCall = {
                urlPath  = "/api/v1/namespaces/{{request.namespace}}"
                jmesPath = "metadata.labels.tier || 'default'"
              }
            }
          ]
          mutate = {
            patchStrategicMerge = {
              metadata = {
                labels = {
                  # Injects the variable discovered in the context above
                  "+(tier)" = "{{namespaceLabel}}"
                }
              }
            }
          }
        }
      ]
    }
  }
}

# resource "kubernetes_manifest" "enforce_pod_tier_label" {
#   manifest = {
#     apiVersion = "kyverno.io/v1"
#     kind       = "ClusterPolicy"
#     metadata = {
#       name = "enforce-pod-tier-label"
#       annotations = {
#         "policies.kyverno.io/description" = "Rejects any pod that does not have a tier label."
#       }
#     }
#     spec = {
#       # 'Enforce' blocks the creation. 'Audit' just reports it.
#       validationFailureAction = "Enforce"
#       background              = true
#       rules = [
#         {
#           name = "check-for-tier-label"
#           match = {
#             any = [
#               {
#                 resources = {
#                   kinds = ["Pod"]
#                 }
#               }
#             ]
#           }
#           validate = {
#             message = "The label 'tier' is required for all pods in this cluster."
#             pattern = {
#               metadata = {
#                 labels = {
#                   "tier" = "?*" # The "?*" syntax means the value must not be empty
#                 }
#               }
#             }
#           }
#         }
#       ]
#     }
#   }
# }
