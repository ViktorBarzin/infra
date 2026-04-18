
resource "kubernetes_namespace" "kyverno" {
  metadata {
    name = "kyverno"
    labels = {
      "istio-injection" : "disabled"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "helm_release" "kyverno" {
  namespace        = kubernetes_namespace.kyverno.metadata[0].name
  create_namespace = false
  name             = "kyverno"
  atomic           = true

  repository = "https://kyverno.github.io/kyverno/"
  chart      = "kyverno"
  version    = "3.6.1"

  values = [yamlencode({
    # When Kyverno is unavailable, allow pod creation to proceed without
    # mutation/validation rather than blocking all admissions cluster-wide.
    features = {
      forceFailurePolicyIgnore = {
        enabled = true
      }
      policyReports = {
        enabled = false
      }
    }

    reportsController = {
      resources = {
        limits = {
          memory = "512Mi"
        }
        requests = {
          cpu    = "100m"
          memory = "384Mi"
        }
      }
    }

    backgroundController = {
      resources = {
        limits = {
          memory = "384Mi"
        }
        requests = {
          cpu    = "100m"
          memory = "384Mi"
        }
      }
    }

    cleanupController = {
      resources = {
        limits = {
          memory = "192Mi"
        }
        requests = {
          cpu    = "100m"
          memory = "192Mi"
        }
      }
    }

    admissionController = {
      replicas = 2

      updateStrategy = {
        type = "RollingUpdate"
        rollingUpdate = {
          maxSurge       = 0
          maxUnavailable = 1
        }
      }

      container = {
        resources = {
          limits = {
            memory = "256Mi"
          }
          requests = {
            cpu    = "100m"
            memory = "256Mi"
          }
        }
      }

      # More tolerant liveness probe — API server slowness shouldn't kill the pod
      livenessProbe = {
        httpGet = {
          path   = "/health/liveness"
          port   = 9443
          scheme = "HTTPS"
        }
        initialDelaySeconds = 15
        periodSeconds       = 30
        timeoutSeconds      = 5
        failureThreshold    = 4
        successThreshold    = 1
      }

      # Spread replicas across nodes for HA
      topologySpreadConstraints = [
        {
          maxSkew           = 1
          topologyKey       = "kubernetes.io/hostname"
          whenUnsatisfiable = "DoNotSchedule"
          labelSelector = {
            matchLabels = {
              "app.kubernetes.io/component" = "admission-controller"
              "app.kubernetes.io/instance"  = "kyverno"
            }
          }
        }
      ]
    }
  })]
}

# To unlabel all:
# kubectl label deployment,statefulset,daemonset --all-namespaces -l tier tier-
#
# Uses namespaceSelector to match tiers — no API call needed.
# One rule per tier so Kyverno resolves the tier value from its informer cache.
resource "kubernetes_manifest" "mutate_tier_from_namespace" {
  manifest = {
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "sync-tier-label-from-namespace"
    }
    spec = {
      rules = [for tier in local.governance_tiers : {
        name = "sync-tier-${tier}"
        match = {
          any = [
            {
              resources = {
                kinds = ["Deployment", "StatefulSet", "DaemonSet"]
                namespaceSelector = {
                  matchLabels = {
                    tier = tier
                  }
                }
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
        mutate = {
          patchStrategicMerge = {
            metadata = {
              labels = {
                "+(tier)" = tier
              }
            }
          }
        }
      }]
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
