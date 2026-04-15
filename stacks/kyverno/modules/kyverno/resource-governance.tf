
# =============================================================================
# Tier-Based Resource Governance
# =============================================================================
# default (limit) = defaultRequest (request) to give Guaranteed QoS and prevent
# memory overcommit. Changed 2026-03-14 after node2 OOM crash caused by 250%
# memory overcommit (61GB limits on 24GB node).
#
# Four layers of protection against noisy neighbor issues:
# 1. PriorityClasses - critical services survive resource pressure
# 2. LimitRange defaults (Kyverno generate) - auto-inject defaults for containers without resources
# 3. ResourceQuotas (Kyverno generate) - hard ceiling on namespace resource consumption
# 4. Priority injection (Kyverno mutate) - set priorityClassName based on namespace tier label

locals {
  governance_tiers    = ["0-core", "1-cluster", "2-gpu", "3-edge", "4-aux"]
  excluded_namespaces = ["kube-system", "metallb-system", "kyverno", "calico-system", "calico-apiserver"]
}

# -----------------------------------------------------------------------------
# Layer 1: PriorityClasses
# -----------------------------------------------------------------------------
# Values stay well below system-cluster-critical (2,000,000,000)

resource "kubernetes_priority_class" "tier_0_core" {
  metadata {
    name = "tier-0-core"
  }
  value             = 1000000
  global_default    = false
  preemption_policy = "PreemptLowerPriority"
  description       = "Critical infrastructure: ingress, DNS, VPN, auth, monitoring"
}

resource "kubernetes_priority_class" "tier_1_cluster" {
  metadata {
    name = "tier-1-cluster"
  }
  value             = 800000
  global_default    = false
  preemption_policy = "PreemptLowerPriority"
  description       = "Cluster services: Redis, metrics, security"
}

resource "kubernetes_priority_class" "tier_2_gpu" {
  metadata {
    name = "tier-2-gpu"
  }
  value             = 600000
  global_default    = false
  preemption_policy = "PreemptLowerPriority"
  description       = "GPU workloads: Immich, Ollama, Frigate"
}

resource "kubernetes_priority_class" "gpu_workload" {
  metadata {
    name = "gpu-workload"
  }
  value             = 1200000
  global_default    = false
  preemption_policy = "PreemptLowerPriority"
  description       = "GPU-pinned workloads. Higher than all user tiers. Auto-injected by Kyverno on pods requesting nvidia.com/gpu."
}

resource "kubernetes_priority_class" "tier_3_edge" {
  metadata {
    name = "tier-3-edge"
  }
  value             = 400000
  global_default    = false
  preemption_policy = "PreemptLowerPriority"
  description       = "User-facing services: mail, file sync, dashboards"
}

resource "kubernetes_priority_class" "tier_4_aux" {
  metadata {
    name = "tier-4-aux"
  }
  value             = 200000
  global_default    = false
  preemption_policy = "Never"
  description       = "Optional services: blogs, tools, experiments. Will not preempt other aux services."
}

# -----------------------------------------------------------------------------
# Layer 2: LimitRange Defaults (Kyverno Generate)
# -----------------------------------------------------------------------------
# Creates a LimitRange in each namespace based on its tier label.
# Only affects containers WITHOUT explicit resource requests/limits.

resource "kubernetes_manifest" "generate_limitrange_by_tier" {
  manifest = {
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "generate-limitrange-by-tier"
      annotations = {
        "policies.kyverno.io/title"       = "Generate LimitRange by Tier"
        "policies.kyverno.io/description" = "Creates tier-appropriate LimitRange defaults in namespaces based on their tier label. Only affects containers without explicit resource specifications. Excludes namespaces with resource-governance/custom-limitrange label."
      }
    }
    spec = {
      generateExisting = true
      rules = [
        # Tier 0-core
        {
          name = "limitrange-tier-0-core"
          match = {
            any = [
              {
                resources = {
                  kinds = ["Namespace"]
                  selector = {
                    matchLabels = {
                      tier = "0-core"
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
                  selector = {
                    matchLabels = {
                      "resource-governance/custom-limitrange" = "true"
                    }
                  }
                }
              }
            ]
          }
          generate = {
            synchronize = true
            apiVersion  = "v1"
            kind        = "LimitRange"
            name        = "tier-defaults"
            namespace   = "{{request.object.metadata.name}}"
            data = {
              spec = {
                limits = [
                  {
                    type = "Container"
                    default = {
                      memory = "256Mi"
                    }
                    defaultRequest = {
                      cpu    = "100m"
                      memory = "256Mi"
                    }
                    max = {
                      memory = "8Gi"
                    }
                  }
                ]
              }
            }
          }
        },
        # Tier 1-cluster
        {
          name = "limitrange-tier-1-cluster"
          match = {
            any = [
              {
                resources = {
                  kinds = ["Namespace"]
                  selector = {
                    matchLabels = {
                      tier = "1-cluster"
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
                  selector = {
                    matchLabels = {
                      "resource-governance/custom-limitrange" = "true"
                    }
                  }
                }
              }
            ]
          }
          generate = {
            synchronize = true
            apiVersion  = "v1"
            kind        = "LimitRange"
            name        = "tier-defaults"
            namespace   = "{{request.object.metadata.name}}"
            data = {
              spec = {
                limits = [
                  {
                    type = "Container"
                    default = {
                      memory = "256Mi"
                    }
                    defaultRequest = {
                      cpu    = "100m"
                      memory = "256Mi"
                    }
                    max = {
                      memory = "8Gi"
                    }
                  }
                ]
              }
            }
          }
        },
        # Tier 2-gpu
        {
          name = "limitrange-tier-2-gpu"
          match = {
            any = [
              {
                resources = {
                  kinds = ["Namespace"]
                  selector = {
                    matchLabels = {
                      tier = "2-gpu"
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
                  selector = {
                    matchLabels = {
                      "resource-governance/custom-limitrange" = "true"
                    }
                  }
                }
              }
            ]
          }
          generate = {
            synchronize = true
            apiVersion  = "v1"
            kind        = "LimitRange"
            name        = "tier-defaults"
            namespace   = "{{request.object.metadata.name}}"
            data = {
              spec = {
                limits = [
                  {
                    type = "Container"
                    default = {
                      memory = "1Gi"
                    }
                    defaultRequest = {
                      cpu    = "200m"
                      memory = "1Gi"
                    }
                    max = {
                      memory = "16Gi"
                    }
                  }
                ]
              }
            }
          }
        },
        # Tier 3-edge — Burstable QoS: request < limit to reduce scheduler pressure
        {
          name = "limitrange-tier-3-edge"
          match = {
            any = [
              {
                resources = {
                  kinds = ["Namespace"]
                  selector = {
                    matchLabels = {
                      tier = "3-edge"
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
                  selector = {
                    matchLabels = {
                      "resource-governance/custom-limitrange" = "true"
                    }
                  }
                }
              }
            ]
          }
          generate = {
            synchronize = true
            apiVersion  = "v1"
            kind        = "LimitRange"
            name        = "tier-defaults"
            namespace   = "{{request.object.metadata.name}}"
            data = {
              spec = {
                limits = [
                  {
                    type = "Container"
                    default = {
                      memory = "256Mi"
                    }
                    defaultRequest = {
                      cpu    = "50m"
                      memory = "128Mi"
                    }
                    max = {
                      memory = "8Gi"
                    }
                  }
                ]
              }
            }
          }
        },
        # Tier 4-aux — Burstable QoS: request < limit to reduce scheduler pressure
        {
          name = "limitrange-tier-4-aux"
          match = {
            any = [
              {
                resources = {
                  kinds = ["Namespace"]
                  selector = {
                    matchLabels = {
                      tier = "4-aux"
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
                  selector = {
                    matchLabels = {
                      "resource-governance/custom-limitrange" = "true"
                    }
                  }
                }
              }
            ]
          }
          generate = {
            synchronize = true
            apiVersion  = "v1"
            kind        = "LimitRange"
            name        = "tier-defaults"
            namespace   = "{{request.object.metadata.name}}"
            data = {
              spec = {
                limits = [
                  {
                    type = "Container"
                    default = {
                      memory = "256Mi"
                    }
                    defaultRequest = {
                      cpu    = "50m"
                      memory = "64Mi"
                    }
                    max = {
                      memory = "4Gi"
                    }
                  }
                ]
              }
            }
          }
        },
        # Fallback: namespaces without a tier label get aux-level defaults
        # requests = limits to prevent memory overcommit (2026-03-14 node2 OOM incident)
        {
          name = "limitrange-no-tier-fallback"
          match = {
            any = [
              {
                resources = {
                  kinds = ["Namespace"]
                }
              }
            ]
          }
          exclude = {
            any = [
              {
                resources = {
                  selector = {
                    matchExpressions = [
                      {
                        key      = "tier"
                        operator = "Exists"
                      }
                    ]
                  }
                }
              },
              {
                resources = {
                  namespaces = ["kube-system", "metallb-system", "kyverno", "calico-system", "calico-apiserver"]
                }
              }
            ]
          }
          generate = {
            synchronize = true
            apiVersion  = "v1"
            kind        = "LimitRange"
            name        = "tier-defaults"
            namespace   = "{{request.object.metadata.name}}"
            data = {
              spec = {
                limits = [
                  {
                    type = "Container"
                    default = {
                      memory = "192Mi"
                    }
                    defaultRequest = {
                      cpu    = "50m"
                      memory = "128Mi"
                    }
                    max = {
                      memory = "4Gi"
                    }
                  }
                ]
              }
            }
          }
        },
      ]
    }
  }
}

# -----------------------------------------------------------------------------
# Layer 3: ResourceQuotas (Kyverno Generate)
# -----------------------------------------------------------------------------
# Creates a ResourceQuota in each namespace based on its tier label.
# Sets hard ceiling on total namespace resource consumption.
# Namespaces with label resource-governance/custom-quota=true are excluded.
#
# IMPORTANT: LimitRange (Layer 2) must exist before ResourceQuota takes effect,
# because ResourceQuota requires all pods to have resource requests set.

resource "kubernetes_manifest" "generate_resourcequota_by_tier" {
  depends_on = [kubernetes_manifest.generate_limitrange_by_tier]

  manifest = {
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "generate-resourcequota-by-tier"
      annotations = {
        "policies.kyverno.io/title"       = "Generate ResourceQuota by Tier"
        "policies.kyverno.io/description" = "Creates tier-appropriate ResourceQuota in namespaces based on their tier label. Excludes namespaces with resource-governance/custom-quota label."
      }
    }
    spec = {
      generateExisting = true
      rules = [
        # Tier 0-core
        {
          name = "quota-tier-0-core"
          match = {
            any = [
              {
                resources = {
                  kinds = ["Namespace"]
                  selector = {
                    matchLabels = {
                      tier = "0-core"
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
                  selector = {
                    matchLabels = {
                      "resource-governance/custom-quota" = "true"
                    }
                  }
                }
              }
            ]
          }
          generate = {
            synchronize = true
            apiVersion  = "v1"
            kind        = "ResourceQuota"
            name        = "tier-quota"
            namespace   = "{{request.object.metadata.name}}"
            data = {
              spec = {
                hard = {
                  "requests.cpu"    = "8"
                  "requests.memory" = "8Gi"
                  "limits.memory"   = "64Gi"
                  pods              = "100"
                }
              }
            }
          }
        },
        # Tier 1-cluster
        {
          name = "quota-tier-1-cluster"
          match = {
            any = [
              {
                resources = {
                  kinds = ["Namespace"]
                  selector = {
                    matchLabels = {
                      tier = "1-cluster"
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
                  selector = {
                    matchLabels = {
                      "resource-governance/custom-quota" = "true"
                    }
                  }
                }
              }
            ]
          }
          generate = {
            synchronize = true
            apiVersion  = "v1"
            kind        = "ResourceQuota"
            name        = "tier-quota"
            namespace   = "{{request.object.metadata.name}}"
            data = {
              spec = {
                hard = {
                  "requests.cpu"    = "4"
                  "requests.memory" = "4Gi"
                  "limits.memory"   = "32Gi"
                  pods              = "30"
                }
              }
            }
          }
        },
        # Tier 2-gpu
        {
          name = "quota-tier-2-gpu"
          match = {
            any = [
              {
                resources = {
                  kinds = ["Namespace"]
                  selector = {
                    matchLabels = {
                      tier = "2-gpu"
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
                  selector = {
                    matchLabels = {
                      "resource-governance/custom-quota" = "true"
                    }
                  }
                }
              }
            ]
          }
          generate = {
            synchronize = true
            apiVersion  = "v1"
            kind        = "ResourceQuota"
            name        = "tier-quota"
            namespace   = "{{request.object.metadata.name}}"
            data = {
              spec = {
                hard = {
                  "requests.cpu"    = "8"
                  "requests.memory" = "12Gi"
                  "limits.memory"   = "32Gi"
                  pods              = "40"
                }
              }
            }
          }
        },
        # Tier 3-edge
        {
          name = "quota-tier-3-edge"
          match = {
            any = [
              {
                resources = {
                  kinds = ["Namespace"]
                  selector = {
                    matchLabels = {
                      tier = "3-edge"
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
                  selector = {
                    matchLabels = {
                      "resource-governance/custom-quota" = "true"
                    }
                  }
                }
              }
            ]
          }
          generate = {
            synchronize = true
            apiVersion  = "v1"
            kind        = "ResourceQuota"
            name        = "tier-quota"
            namespace   = "{{request.object.metadata.name}}"
            data = {
              spec = {
                hard = {
                  "requests.cpu"    = "4"
                  "requests.memory" = "4Gi"
                  "limits.memory"   = "32Gi"
                  pods              = "30"
                }
              }
            }
          }
        },
        # Tier 4-aux
        {
          name = "quota-tier-4-aux"
          match = {
            any = [
              {
                resources = {
                  kinds = ["Namespace"]
                  selector = {
                    matchLabels = {
                      tier = "4-aux"
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
                  selector = {
                    matchLabels = {
                      "resource-governance/custom-quota" = "true"
                    }
                  }
                }
              }
            ]
          }
          generate = {
            synchronize = true
            apiVersion  = "v1"
            kind        = "ResourceQuota"
            name        = "tier-quota"
            namespace   = "{{request.object.metadata.name}}"
            data = {
              spec = {
                hard = {
                  "requests.cpu"    = "2"
                  "requests.memory" = "3Gi"
                  "limits.memory"   = "16Gi"
                  pods              = "20"
                }
              }
            }
          }
        },
      ]
    }
  }
}

# -----------------------------------------------------------------------------
# Layer 4: PriorityClassName Injection (Kyverno Mutate)
# -----------------------------------------------------------------------------
# Automatically sets priorityClassName on Pods based on their namespace's tier label.
# Skips pods that already have a priorityClassName set.
# Uses namespaceSelector instead of API calls — no round-trip to the API server.

resource "kubernetes_manifest" "mutate_priority_from_tier" {
  manifest = {
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "inject-priority-class-from-tier"
      annotations = {
        "policies.kyverno.io/title"       = "Inject PriorityClass from Tier"
        "policies.kyverno.io/description" = "Sets priorityClassName on Pods based on the namespace tier label. Skips pods that already have a priorityClassName."
      }
    }
    spec = {
      rules = [for tier in local.governance_tiers : {
        name = "inject-priority-${tier}"
        match = {
          any = [
            {
              resources = {
                kinds      = ["Pod"]
                operations = ["CREATE"]
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
                namespaces = local.excluded_namespaces
              }
            }
          ]
        }
        preconditions = {
          all = [
            {
              key      = "{{request.object.spec.priorityClassName || ''}}"
              operator = "Equals"
              value    = ""
            }
          ]
        }
        mutate = {
          patchesJson6902 = yamlencode([
            {
              op   = "remove"
              path = "/spec/priority"
            },
            {
              op   = "remove"
              path = "/spec/preemptionPolicy"
            },
            {
              op    = "add"
              path  = "/spec/priorityClassName"
              value = "tier-${tier}"
            }
          ])
        }
      }]
    }
  }
}


# --- ndots:2 injection ---
# Kubernetes defaults to ndots:5, which causes 4 wasted NxDomain queries per
# external DNS lookup (search domain expansion). This policy injects ndots:2
# on all pods to reduce NxDomain flood while still allowing short-name service
# resolution (e.g. "redis.redis" has 1 dot, so it still expands).
resource "kubernetes_manifest" "mutate_ndots" {
  manifest = {
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "inject-ndots"
      annotations = {
        "policies.kyverno.io/title"       = "Inject ndots:2 DNS Config"
        "policies.kyverno.io/description" = "Sets ndots:2 on all Pods to reduce NxDomain query flood from search domain expansion. Skips pods that already have ndots configured."
      }
    }
    spec = {
      rules = [
        {
          name = "inject-ndots-2"
          match = {
            any = [
              {
                resources = {
                  kinds = ["Pod"]
                }
              }
            ]
          }
          exclude = {
            any = [
              {
                resources = {
                  namespaces = ["kube-system", "metallb-system", "kyverno", "calico-system", "calico-apiserver"]
                }
              }
            ]
          }
          preconditions = {
            all = [
              {
                key      = "{{ request.object.spec.dnsConfig.options || `[]` | [?name == 'ndots'] | length(@) }}"
                operator = "Equals"
                value    = "0"
              }
            ]
          }
          mutate = {
            patchStrategicMerge = {
              spec = {
                dnsConfig = {
                  options = [
                    {
                      name  = "ndots"
                      value = "2"
                    }
                  ]
                }
              }
            }
          }
        }
      ]
    }
  }
}

# -----------------------------------------------------------------------------
# Layer 5: GPU Workload Priority Override (Kyverno Mutate)
# -----------------------------------------------------------------------------
# Overrides the tier-based priorityClassName with gpu-workload for pods that
# actually request nvidia.com/gpu resources. This ensures GPU pods can preempt
# non-GPU pods on the GPU node, regardless of namespace tier.
# Runs after Layer 4 (tier injection), so it overrides the tier-based priority.

resource "kubernetes_manifest" "mutate_gpu_priority" {
  manifest = {
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "inject-gpu-workload-priority"
      annotations = {
        "policies.kyverno.io/title"       = "Inject GPU Workload Priority"
        "policies.kyverno.io/description" = "Overrides priorityClassName to gpu-workload for pods requesting nvidia.com/gpu resources. Runs after tier-based injection."
      }
    }
    spec = {
      rules = [
        {
          name = "gpu-priority-override"
          match = {
            any = [
              {
                resources = {
                  kinds      = ["Pod"]
                  operations = ["CREATE"]
                }
              }
            ]
          }
          exclude = {
            any = [
              {
                resources = {
                  namespaces = local.excluded_namespaces
                }
              }
            ]
          }
          preconditions = {
            any = [
              {
                key      = "{{ request.object.spec.containers[].resources.requests.\"nvidia.com/gpu\" || '' }}"
                operator = "NotEquals"
                value    = ""
              },
              {
                key      = "{{ request.object.spec.containers[].resources.limits.\"nvidia.com/gpu\" || '' }}"
                operator = "NotEquals"
                value    = ""
              }
            ]
          }
          mutate = {
            patchesJson6902 = yamlencode([
              {
                op    = "replace"
                path  = "/spec/priorityClassName"
                value = "gpu-workload"
              },
              {
                op    = "replace"
                path  = "/spec/priority"
                value = 1200000
              },
              {
                op    = "replace"
                path  = "/spec/preemptionPolicy"
                value = "PreemptLowerPriority"
              }
            ])
          }
        }
      ]
    }
  }
}
