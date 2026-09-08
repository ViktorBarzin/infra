
resource "kubernetes_namespace" "kyverno" {
  metadata {
    name = "kyverno"
    labels = {
      "istio-injection" : "disabled"
      "keel.sh/enrolled" = "true"
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
  # Stepped upgrade to clear the k8s-1.35 compat-gate block (kyverno <=1.34 -> 1.35).
  # 3.6.1 (app 1.16) -> 3.7.2 (1.17) -> 3.8.1 (1.18, supports k8s 1.35), one minor at
  # a time per the kyverno upgrade guide (per-minor CRD notes). atomic=true rolls back
  # a failed rollout; forceFailurePolicyIgnore keeps admissions open if the webhook is
  # mid-roll. Each hop verified: 17 ClusterPolicies stay Ready + webhook responds.
  # 3.6.1->3.7.2 done 2026-06-21 (clean). Now 3.7.2 (1.17.2) -> 3.8.1 (1.18.1).
  version = "3.8.1"

  values = [yamlencode({
    # When Kyverno is unavailable, allow pod creation to proceed without
    # mutation/validation rather than blocking all admissions cluster-wide.
    features = {
      forceFailurePolicyIgnore = {
        enabled = true
      }
      # Reporting features disabled (2026-06-12, etcd-load-reduction); the
      # reportsController itself is now disabled too (2026-06-28, see below).
      # policyReports were already off, so admission/aggregate/background generated
      # ephemeralreports + an hourly all-resource etcd re-scan for NO user-facing
      # output. Admission enforcement (deny-* policies) and Keel mutation are
      # independent of reporting; policy violations surface via Loki->Slack. This
      # removes a steady-state etcd write/scan load (control-plane flap mitigation).
      policyReports = {
        enabled = false
      }
      admissionReports = {
        enabled = false
      }
      aggregateReports = {
        enabled = false
      }
      backgroundScan = {
        enabled = false
      }
    }

    # Fully disable the reports controller (2026-06-28). The 2026-06-12 change
    # turned off the report *features* (policy/admission/aggregate/background) but
    # LEFT this controller running with its default --enableReporting +
    # --validatingAdmissionPolicyReports=true, so it kept emitting ephemeralreports.
    # The 2026-06-21 kyverno upgrade then produced a one-time pile of ~10.5k
    # cluster/namespaced ephemeralreports (~114MB in etcd) that nothing reaps
    # (aggregation off) — and listing that range starves etcd's fdatasync hard
    # enough to flap the apiserver (observed live 2026-06-28). Reports are not
    # consumed (violations surface via Loki->Slack), so disable the controller
    # outright; enforcement (deny-* policies) + Keel mutation are independent of
    # it. Stale reports are cleared out-of-band (one-time, throttled).
    reportsController = {
      enabled = false
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
        # Bumped 2026-05-16 from 384Mi → 2Gi because the controller OOMKilled
        # while processing 176 UpdateRequests for the inject-keel-annotations
        # mutate-existing scan. With mutateExistingOnPolicyUpdate=true the
        # background controller needs significantly more memory during the
        # initial bulk scan.
        limits = {
          memory = "2Gi"
        }
        requests = {
          cpu    = "100m"
          memory = "256Mi"
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
resource "kubectl_manifest" "mutate_tier_from_namespace" {
  yaml_body = yamlencode({
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
  })
}

# resource "kubectl_manifest" "enforce_pod_tier_label" {
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
