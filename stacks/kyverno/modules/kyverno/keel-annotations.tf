# =============================================================================
# Keel Auto-Update Annotation Injector
# =============================================================================
# Design: infra/docs/plans/2026-05-16-auto-upgrade-apps-design.md
# Plan:   infra/docs/plans/2026-05-16-auto-upgrade-apps-plan.md
#
# Mutate policy that adds keel.sh/* annotations to Deployments,
# StatefulSets and DaemonSets in *opted-in* namespaces. Opt-in is via a
# label on the namespace:
#
#   labels = { "keel.sh/enrolled" = "true" }
#
# Phase rollout = label more namespaces. No edit to this file per phase.
#
# Workloads can individually opt out with the label keel.sh/policy=never
# (used by the rollback runbook). The keel namespace itself is always
# excluded (design decision #11 — supervisor must not auto-update).

resource "kubernetes_manifest" "policy_inject_keel_annotations" {
  manifest = {
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "inject-keel-annotations"
      annotations = {
        "policies.kyverno.io/title"       = "Inject Keel Auto-Update Annotations"
        "policies.kyverno.io/category"    = "Automation"
        "policies.kyverno.io/severity"    = "low"
        "policies.kyverno.io/description" = "Adds keel.sh/policy: force + trigger: poll annotations to workloads in namespaces labeled keel.sh/enrolled=true. Phase rollout per docs/plans/2026-05-16-auto-upgrade-apps-{design,plan}.md."
      }
    }
    spec = {
      # Retroactively mutate workloads that existed BEFORE their namespace
      # got the keel.sh/enrolled=true label. Without this, Kyverno only
      # fires on admission events, so old workloads stay unannotated and
      # Keel doesn't watch them. With this flag, Kyverno's BackgroundScan
      # controller applies the mutate on existing matching resources when
      # the policy is created or updated.
      mutateExistingOnPolicyUpdate = true
      background                   = true
      rules = [{
        name = "add-keel-annotations"
        match = {
          any = [{
            resources = {
              kinds = ["Deployment", "StatefulSet", "DaemonSet"]
              namespaceSelector = {
                matchLabels = {
                  "keel.sh/enrolled" = "true"
                }
              }
            }
          }]
        }
        exclude = {
          any = [
            {
              resources = {
                # Keel must not auto-update itself (decision #11).
                # calico-system: managed by tigera-operator via Installation CR.
                #   Keel rewriting the calico-node DaemonSet image causes an
                #   hourly fight loop (Keel → v3.26.5, operator → v3.26.1).
                #   Calico version is bumped manually via the Installation CR.
                namespaces = ["keel", "calico-system"]
              }
            },
            {
              resources = {
                selector = {
                  matchLabels = {
                    "keel.sh/policy" = "never"
                  }
                }
              }
            },
          ]
        }
        mutate = {
          # Required when mutateExistingOnPolicyUpdate=true — tells the
          # background controller which existing resources to mutate.
          targets = [
            { apiVersion = "apps/v1", kind = "Deployment" },
            { apiVersion = "apps/v1", kind = "StatefulSet" },
            { apiVersion = "apps/v1", kind = "DaemonSet" },
          ]
          patchStrategicMerge = {
            metadata = {
              annotations = {
                # `+(...)` only adds if not present; per-workload overrides win.
                #
                # DEFAULT IS `patch` — Keel auto-updates only PATCH versions
                # within the current major.minor. e.g. 0.26.6 → 0.26.7 is OK,
                # 0.26.6 → 0.27.0 is NOT, 0.26.6 → :nightly-latest is NOT.
                #
                # Why not `force`: the 2026-05-16 incident — Keel's `force`
                # policy is "always update to the newest tag in the registry,"
                # not "watch current tag for digest changes." On semver-pinned
                # workloads, force triggered tag-rewrites (affine → nightly,
                # calico → master). `patch` is semver-parser-bounded and safe.
                #
                # Caveats of `patch`:
                #   - Tags that aren't parseable as semver (e.g. `:latest`,
                #     `:11`, `:nightly`, SHA tags) are ignored by Keel.
                #   - For services pinned to semver, Keel will REWRITE the
                #     tag (0.26.6 → 0.26.7). This causes Terraform drift
                #     until the stack is updated or its lifecycle adds
                #     `ignore_changes` on the container[].image field.
                #     For now, accepting periodic drift (drift_detection.yml
                #     pipeline will surface it).
                #
                # Per-workload overrides:
                #   "keel.sh/policy" = "force"  — for mutable tags (:latest)
                #   "keel.sh/policy" = "minor"  — wider semver bumps
                #   "keel.sh/policy" = "never"  — opt out (CI-bumped, deliberate pins)
                "+(keel.sh/policy)"       = "patch"
                "+(keel.sh/trigger)"      = "poll"
                "+(keel.sh/pollSchedule)" = "@every 1h"
              }
            }
          }
        }
      }]
    }
  }
  depends_on = [helm_release.kyverno]
}

# Grant the Kyverno background-controller SA permission to mutate
# Deployments / StatefulSets / DaemonSets — required for the policy
# above (mutateExistingOnPolicyUpdate=true + mutate.targets). Kyverno's
# `kyverno:background-controller` ClusterRole aggregates roles labeled
# `rbac.kyverno.io/aggregate-to-background-controller: "true"`.
resource "kubernetes_cluster_role" "keel_mutate_existing" {
  metadata {
    name = "kyverno:background-controller:keel-mutate-existing"
    labels = {
      "rbac.kyverno.io/aggregate-to-background-controller" = "true"
    }
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets", "daemonsets"]
    verbs      = ["get", "list", "watch", "update", "patch"]
  }
  depends_on = [helm_release.kyverno]
}
