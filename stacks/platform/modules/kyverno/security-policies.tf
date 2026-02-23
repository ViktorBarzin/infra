# =============================================================================
# Pod Security Policies (Audit Mode)
# =============================================================================
# Kyverno validate policies for pod security standards.
# All policies start in Audit mode - violations are logged but not blocked.

resource "kubernetes_manifest" "policy_deny_privileged" {
  manifest = {
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "deny-privileged-containers"
      annotations = {
        "policies.kyverno.io/title"       = "Deny Privileged Containers"
        "policies.kyverno.io/category"    = "Pod Security"
        "policies.kyverno.io/severity"    = "high"
        "policies.kyverno.io/description" = "Privileged containers have full host access. Deny unless explicitly exempted."
      }
    }
    spec = {
      validationFailureAction = "Audit"
      background              = true
      rules = [{
        name = "deny-privileged"
        match = {
          any = [{
            resources = {
              kinds = ["Pod"]
            }
          }]
        }
        exclude = {
          any = [{
            resources = {
              namespaces = ["frigate", "nvidia", "monitoring"]
            }
          }]
        }
        validate = {
          message = "Privileged containers are not allowed. Use specific capabilities instead."
          pattern = {
            spec = {
              containers = [{
                "=(securityContext)" = {
                  "=(privileged)" = false
                }
              }]
              "=(initContainers)" = [{
                "=(securityContext)" = {
                  "=(privileged)" = false
                }
              }]
            }
          }
        }
      }]
    }
  }

  depends_on = [helm_release.kyverno]
}

resource "kubernetes_manifest" "policy_deny_host_namespaces" {
  manifest = {
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "deny-host-namespaces"
      annotations = {
        "policies.kyverno.io/title"       = "Deny Host Namespaces"
        "policies.kyverno.io/category"    = "Pod Security"
        "policies.kyverno.io/severity"    = "high"
        "policies.kyverno.io/description" = "Sharing host namespaces enables container escapes. Deny hostNetwork, hostPID, hostIPC."
      }
    }
    spec = {
      validationFailureAction = "Audit"
      background              = true
      rules = [{
        name = "deny-host-namespaces"
        match = {
          any = [{
            resources = {
              kinds = ["Pod"]
            }
          }]
        }
        exclude = {
          any = [{
            resources = {
              namespaces = ["frigate", "monitoring"]
            }
          }]
        }
        validate = {
          message = "Host namespaces (hostNetwork, hostPID, hostIPC) are not allowed."
          pattern = {
            spec = {
              "=(hostNetwork)" = false
              "=(hostPID)"     = false
              "=(hostIPC)"     = false
            }
          }
        }
      }]
    }
  }

  depends_on = [helm_release.kyverno]
}

resource "kubernetes_manifest" "policy_restrict_capabilities" {
  manifest = {
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "restrict-sys-admin"
      annotations = {
        "policies.kyverno.io/title"       = "Restrict SYS_ADMIN Capability"
        "policies.kyverno.io/category"    = "Pod Security"
        "policies.kyverno.io/severity"    = "high"
        "policies.kyverno.io/description" = "SYS_ADMIN is nearly equivalent to root. Restrict to explicitly exempted namespaces."
      }
    }
    spec = {
      validationFailureAction = "Audit"
      background              = true
      rules = [{
        name = "restrict-sys-admin"
        match = {
          any = [{
            resources = {
              kinds = ["Pod"]
            }
          }]
        }
        exclude = {
          any = [{
            resources = {
              namespaces = ["nvidia", "monitoring"]
            }
          }]
        }
        validate = {
          message = "Adding SYS_ADMIN capability is not allowed."
          deny = {
            conditions = {
              any = [{
                key      = "{{ request.object.spec.containers[].securityContext.capabilities.add[] || `[]` }}"
                operator = "AnyIn"
                value    = ["SYS_ADMIN"]
              }]
            }
          }
        }
      }]
    }
  }

  depends_on = [helm_release.kyverno]
}

resource "kubernetes_manifest" "policy_require_trusted_registries" {
  manifest = {
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "require-trusted-registries"
      annotations = {
        "policies.kyverno.io/title"       = "Require Trusted Image Registries"
        "policies.kyverno.io/category"    = "Pod Security"
        "policies.kyverno.io/severity"    = "medium"
        "policies.kyverno.io/description" = "Images must come from trusted registries to prevent supply chain attacks."
      }
    }
    spec = {
      validationFailureAction = "Audit"
      background              = true
      rules = [{
        name = "validate-registries"
        match = {
          any = [{
            resources = {
              kinds = ["Pod"]
            }
          }]
        }
        validate = {
          message = "Images must be from trusted registries (docker.io, ghcr.io, quay.io, registry.k8s.io, or local cache)."
          pattern = {
            spec = {
              containers = [{
                image = "docker.io/* | ghcr.io/* | quay.io/* | registry.k8s.io/* | 10.0.20.10* | */*"
              }]
            }
          }
        }
      }]
    }
  }

  depends_on = [helm_release.kyverno]
}
