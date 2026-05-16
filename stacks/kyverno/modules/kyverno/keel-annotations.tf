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
        "policies.kyverno.io/description" = "Adds keel.sh/policy: force + match-tag: true + trigger: poll annotations to workloads in namespaces labeled keel.sh/enrolled=true. force+match-tag is the safe pairing: Keel watches the deployment's CURRENT tag for digest changes only, never rewrites the tag string. Phase rollout per docs/plans/2026-05-16-auto-upgrade-apps-{design,plan}.md."
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
                # DEFAULT IS `force` + `match-tag: true` — the safe-force
                # pairing learned from the 2026-05-16 :17 incident.
                #
                # How safe-force works:
                #   - `force` alone polls the registry and grabs the NEWEST
                #     tag (any tag), which is what downgraded claude-memory
                #     from :71b32438 → :17 (numeric "17" sorted higher than
                #     hex SHA). UNSAFE on its own.
                #   - `match-tag: "true"` constrains `force` to watch ONLY
                #     the deployment's CURRENT tag string for DIGEST changes.
                #     Keel never rewrites the tag — it just rolls the pod
                #     when the digest behind that tag changes. This is the
                #     correct primitive for `:latest` (and `:major`-style
                #     floating tags).
                #
                # Effect per tag type:
                #   - `:latest` / `:nightly` / `:v1` (mutable): Keel rolls
                #     whenever upstream pushes a new digest under that tag.
                #     ⇐ This is the auto-update behaviour the design wants.
                #   - `:1.2.3` / `:71b32438` (immutable/content-addressed):
                #     digest never changes ⇒ Keel does nothing ⇒ pinned.
                #     ⇐ Safe-by-default for SHA-pinned workloads.
                #
                # `+(...)` is anchor-preserve (add only if missing). We DROP
                # `+()` on `policy` and `match-tag` so an apply migrates
                # existing workloads from the old `patch` default to the new
                # `force + match-tag` pair. Annotation-only changes do NOT
                # restart pods; future digest changes do.
                #
                # Per-workload overrides (set via kubectl/Terraform):
                #   "keel.sh/policy" = "never"  — opt out (set the LABEL too
                #                                 to bypass this mutation)
                # Per-namespace opt-out:
                #   Remove the `keel.sh/enrolled=true` namespace label.
                "keel.sh/policy"          = "force"
                "keel.sh/match-tag"       = "true"
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
