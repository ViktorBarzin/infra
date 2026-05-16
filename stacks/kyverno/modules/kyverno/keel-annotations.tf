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
      background = true
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
                namespaces = ["keel"]
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
          patchStrategicMerge = {
            metadata = {
              annotations = {
                # `+(...)` only adds if not present; per-workload overrides win.
                "+(keel.sh/policy)"       = "force"
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
