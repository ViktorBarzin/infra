# =============================================================================
# Pod Security Policies
# =============================================================================
# Kyverno validate policies for pod security standards.
# Wave 1 (locked 2026-05-18, beads code-8ywc): deny-privileged-containers,
# deny-host-namespaces, restrict-sys-admin flipped from Audit → Enforce with
# a shared 32-namespace exclude list. require-trusted-registries STAYS in
# Audit until the allowlist pattern is tightened beyond `*/*` (separate work
# item — current pattern allows everything with a slash, so Enforce would be
# a no-op for supply-chain protection).
# failurePolicy stays Ignore (chart-level) to prevent admission webhook
# failures from cascading.

# Shared namespace exclude list — 31 critical namespaces from the Keel rollout
# (memory id=1970) + `frigate` (legitimately needs host access for camera RTSP).
locals {
  security_policy_exclude_namespaces = [
    "keel", "calico-system", "authentik", "vault", "cnpg-system", "dbaas",
    "monitoring", "traefik", "technitium", "mailserver", "kyverno",
    "metallb-system", "external-secrets", "proxmox-csi", "nfs-csi", "nvidia",
    "kube-system", "cloudflared", "crowdsec", "reverse-proxy", "reloader",
    "descheduler", "vpa", "redis", "sealed-secrets", "headscale", "wireguard",
    "xray", "infra-maintenance", "metrics-server", "tigera-operator", "frigate",
    # Additions discovered during wave 1 enforce flip — these contain workloads
    # that legitimately need privileged / hostNetwork / SYS_ADMIN:
    "kured",          # kured DaemonSet is privileged (manages node reboots)
    "default",        # etcd backup + defrag CronJobs use hostNetwork
    "changedetection", # uses SYS_ADMIN for chromium sandbox
    "woodpecker",     # CI pipeline pods (wp-*) run privileged docker builds
  ]
}

resource "kubectl_manifest" "policy_deny_privileged" {
  yaml_body = yamlencode({
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
      validationFailureAction = "Enforce"
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
              namespaces = local.security_policy_exclude_namespaces
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
  })

  depends_on = [helm_release.kyverno]
}

resource "kubectl_manifest" "policy_deny_host_namespaces" {
  yaml_body = yamlencode({
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
      validationFailureAction = "Enforce"
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
              namespaces = local.security_policy_exclude_namespaces
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
  })

  depends_on = [helm_release.kyverno]
}

resource "kubectl_manifest" "policy_restrict_capabilities" {
  yaml_body = yamlencode({
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
      validationFailureAction = "Enforce"
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
              namespaces = local.security_policy_exclude_namespaces
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
  })

  depends_on = [helm_release.kyverno]
}

# =============================================================================
# Image Pull Policy Governance
# =============================================================================
# Mutate imagePullPolicy to IfNotPresent for all containers with pinned tags
# (non-:latest). This prevents pods from getting stuck in ImagePullBackOff
# when the pull-through cache at 10.0.20.10 has transient failures.
# For :latest or untagged images, set to Always so stale images don't persist.

resource "kubectl_manifest" "policy_set_image_pull_policy" {
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "set-image-pull-policy"
      annotations = {
        "policies.kyverno.io/title"       = "Set Image Pull Policy"
        "policies.kyverno.io/category"    = "Best Practices"
        "policies.kyverno.io/severity"    = "medium"
        "policies.kyverno.io/description" = "Set imagePullPolicy to IfNotPresent for pinned tags and Always for :latest to prevent ImagePullBackOff from transient cache failures."
      }
    }
    spec = {
      background = false
      rules = [
        {
          name = "set-ifnotpresent-for-pinned-tags"
          match = {
            any = [{
              resources = {
                kinds = ["Pod"]
              }
            }]
          }
          mutate = {
            foreach = [{
              list = "request.object.spec.containers"
              preconditions = {
                all = [{
                  key      = "{{ ends_with(element.image, ':latest') || !contains(element.image, ':') }}"
                  operator = "Equals"
                  value    = false
                }]
              }
              patchStrategicMerge = {
                spec = {
                  containers = [{
                    name            = "{{ element.name }}"
                    imagePullPolicy = "IfNotPresent"
                  }]
                }
              }
            }]
          }
        },
        {
          name = "set-always-for-latest"
          match = {
            any = [{
              resources = {
                kinds = ["Pod"]
              }
            }]
          }
          mutate = {
            foreach = [{
              list = "request.object.spec.containers"
              preconditions = {
                all = [{
                  key      = "{{ ends_with(element.image, ':latest') || !contains(element.image, ':') }}"
                  operator = "Equals"
                  value    = true
                }]
              }
              patchStrategicMerge = {
                spec = {
                  containers = [{
                    name            = "{{ element.name }}"
                    imagePullPolicy = "Always"
                  }]
                }
              }
            }]
          }
        }
      ]
    }
  })

  depends_on = [helm_release.kyverno]
}

resource "kubectl_manifest" "policy_require_trusted_registries" {
  yaml_body = yamlencode({
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
      # Wave 1 W1.5: flipped Audit → Enforce 2026-05-19 with explicit allowlist.
      # Allowlist enumerated from `kubectl get pods -A -o jsonpath='{..image}'`
      # on 2026-05-18; covers all in-cluster image sources. Update on adding new
      # workloads from a registry NOT in this list (and ask if the new registry
      # is trusted before opening it). The `*/*` catch-all was deliberately
      # removed so unknown registries fail closed at admission.
      validationFailureAction = "Enforce"
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
        exclude = {
          any = [{
            resources = {
              namespaces = local.security_policy_exclude_namespaces
            }
          }]
        }
        validate = {
          message = "Images must be from trusted registries. Allowlist defined in stacks/kyverno/modules/kyverno/security-policies.tf — add the new registry there if intentional, otherwise switch the workload to a trusted source."
          pattern = {
            spec = {
              containers = [{
                image = join(" | ", [
                  # Explicit registries
                  "docker.io/*", "ghcr.io/*", "quay.io/*", "registry.k8s.io/*",
                  "gcr.io/*", "us-docker.pkg.dev/*", "lscr.io/*",
                  "codeberg.org/*", "mcr.microsoft.com/*", "nvcr.io/*",
                  "oci.external-secrets.io/*", "reg.kyverno.io/*",
                  "docker.n8n.io/*", "registry.gitlab.com/*",
                  # Private
                  "forgejo.viktorbarzin.me/*", "10.0.20.10*",
                  # Legacy private registry (decommissioned 2026-05-07 per CLAUDE.md
                  # but council-complaints still references — migrate to Forgejo).
                  "registry.viktorbarzin.me/*",
                  # DockerHub library (bare image names without slash)
                  "alpine*", "busybox*", "kong*", "mysql*", "nginx*", "postgres*", "python*",
                  # DockerHub user repos (no registry prefix, has slash) —
                  # enumerated from current cluster state. New entries added
                  # 2026-05-22 after Enforce caught these as unallowlisted:
                  # amruthpillai (resume), athomasson2 (ebook2audiobook),
                  # netboxcommunity (netbox), nousresearch (hermes-agent),
                  # opentripplanner (osm-routing), rhasspy (whisper/piper).
                  "actualbudget/*", "afadil/*", "amruthpillai/*", "athomasson2/*",
                  "binwiederhier/*", "bitnami/*",
                  "clickhouse/*", "cloudflare/*", "coturn/*", "crowdsecurity/*",
                  "curlimages/*", "deluan/*", "dgtlmoon/*", "dolthub/*",
                  "dpage/*", "dperson/*", "edoburu/*", "esanchezm/*",
                  "freikin/*", "freshrss/*", "hackmdio/*", "hashicorp/*",
                  "headscale/*", "jhonderson/*", "kebe/*", "library/*",
                  "lissy93/*", "louislam/*", "matrixdotorg/*", "mendhak/*",
                  "mghee/*", "mindflavor/*", "mpepping/*", "netboxcommunity/*",
                  "netsampler/*", "nousresearch/*", "nvidia/*", "onlyoffice/*",
                  "openresty/*", "opentripplanner/*", "owntracks/*",
                  "phpipam/*", "phpmyadmin/*", "privatebin/*", "prom/*",
                  "prompve/*", "rancher/*", "rhasspy/*", "roundcube/*", "sclevine/*",
                  "shadowsocks/*", "shlinkio/*", "stirlingtools/*",
                  "technitium/*", "teddysun/*", "temporalio/*",
                  "typhonragewind/*", "tzahi12345/*", "vabene1111/*",
                  "vaultwarden/*", "viktorbarzin/*", "viren070/*",
                  "woodpeckerci/*", "zelest/*",
                ])
              }]
            }
          }
        }
      }]
    }
  })

  depends_on = [helm_release.kyverno]
}
