
# =============================================================================
# Tier-Based Resource Governance
# =============================================================================
# Four layers of protection against noisy neighbor issues:
# 1. PriorityClasses - critical services survive resource pressure
# 2. LimitRange defaults (Kyverno generate) - auto-inject defaults for containers without resources
# 3. ResourceQuotas (Kyverno generate) - hard ceiling on namespace resource consumption
# 4. Priority injection (Kyverno mutate) - set priorityClassName based on namespace tier label

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
        "policies.kyverno.io/description" = "Creates tier-appropriate LimitRange defaults in namespaces based on their tier label. Only affects containers without explicit resource specifications."
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
                      cpu    = "2"
                      memory = "4Gi"
                    }
                    defaultRequest = {
                      cpu    = "100m"
                      memory = "128Mi"
                    }
                    max = {
                      cpu    = "8"
                      memory = "16Gi"
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
                      cpu    = "2"
                      memory = "4Gi"
                    }
                    defaultRequest = {
                      cpu    = "100m"
                      memory = "128Mi"
                    }
                    max = {
                      cpu    = "4"
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
                      cpu    = "4"
                      memory = "8Gi"
                    }
                    defaultRequest = {
                      cpu    = "100m"
                      memory = "256Mi"
                    }
                    max = {
                      cpu    = "8"
                      memory = "16Gi"
                    }
                  }
                ]
              }
            }
          }
        },
        # Tier 3-edge
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
                      cpu    = "1"
                      memory = "2Gi"
                    }
                    defaultRequest = {
                      cpu    = "50m"
                      memory = "128Mi"
                    }
                    max = {
                      cpu    = "4"
                      memory = "8Gi"
                    }
                  }
                ]
              }
            }
          }
        },
        # Tier 4-aux
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
                      cpu    = "500m"
                      memory = "1Gi"
                    }
                    defaultRequest = {
                      cpu    = "25m"
                      memory = "64Mi"
                    }
                    max = {
                      cpu    = "2"
                      memory = "4Gi"
                    }
                  }
                ]
              }
            }
          }
        },
        # Fallback: namespaces without a tier label get aux-level defaults
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
                      cpu    = "500m"
                      memory = "1Gi"
                    }
                    defaultRequest = {
                      cpu    = "25m"
                      memory = "64Mi"
                    }
                    max = {
                      cpu    = "2"
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
                  "limits.cpu"      = "32"
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
                  "limits.cpu"      = "16"
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
                  "requests.cpu"    = "4"
                  "requests.memory" = "4Gi"
                  "limits.cpu"      = "32"
                  "limits.memory"   = "64Gi"
                  pods              = "30"
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
                  "requests.cpu"    = "2"
                  "requests.memory" = "2Gi"
                  "limits.cpu"      = "8"
                  "limits.memory"   = "16Gi"
                  pods              = "20"
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
                  "requests.cpu"    = "1"
                  "requests.memory" = "1Gi"
                  "limits.cpu"      = "4"
                  "limits.memory"   = "8Gi"
                  pods              = "15"
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
      rules = [
        {
          name = "inject-priority-class"
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
          context = [
            {
              name = "tierLabel"
              apiCall = {
                urlPath  = "/api/v1/namespaces/{{request.namespace}}"
                jmesPath = "metadata.labels.tier || ''"
              }
            }
          ]
          preconditions = {
            all = [
              {
                key      = "{{request.object.spec.priorityClassName || ''}}"
                operator = "Equals"
                value    = ""
              },
              {
                key      = "{{tierLabel}}"
                operator = "NotEquals"
                value    = ""
              }
            ]
          }
          mutate = {
            patchStrategicMerge = {
              spec = {
                priorityClassName = "tier-{{tierLabel}}"
              }
            }
          }
        }
      ]
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
