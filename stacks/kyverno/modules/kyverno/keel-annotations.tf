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

resource "kubectl_manifest" "policy_inject_keel_annotations" {
  yaml_body = yamlencode({
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
                # Namespaces that must NEVER be auto-updated by Keel.
                # Each has a domain-aware upgrade flow (operator, Helm chart
                # version bump, schema migration, etc.) that Keel would fight.
                #
                # - keel: supervisor self-update (decision #11)
                # - calico-system: tigera-operator owns Installation CR
                # - authentik: 2026-05-17 incident — minor bump 2026.2.2→2026.2.3
                #   broke pgbouncer connections; rolled back manually
                # - vault, cnpg-system, dbaas: state-coupled with TF backend
                # - monitoring: kube-prometheus-stack multi-component coordination
                # - traefik, metallb-system, technitium: networking critical path
                # - kyverno, external-secrets, sealed-secrets, reloader,
                #   descheduler, vpa, kube-system: cluster-level operators
                # - proxmox-csi, nfs-csi, nvidia, tigera-operator: hardware/CNI
                #   coordination
                # - cloudflared, headscale, wireguard, xray: VPN/tunnel critical
                # - infra-maintenance: cluster utilities
                #
                # 2026-05-17 ENROLLMENT EXPANSION (final round): removed an
                # additional 9 namespaces from the exclude list per explicit
                # user decision (auto-updates now allowed in authentik,
                # kyverno, metallb-system, external-secrets, proxmox-csi,
                # nfs-csi, vpa, sealed-secrets, infra-maintenance), plus
                # aiostreams + woodpecker which were unenrolled by namespace
                # label only. The `force + match-tag` pairing limits each
                # workload to digest-only watches under the deployment's
                # CURRENT tag string — no tag-switching, just rolls on
                # upstream digest changes for that pinned tag.
                #
                # Risks to monitor (worth catching regressions on):
                # - kyverno: cluster admission engine. `forceFailurePolicyIgnore`
                #   keeps the cluster admitting pods if Kyverno is down, and
                #   the admission controller runs 2 replicas, so a bad-digest
                #   roll can be recovered from by deleting the bad pod.
                # - nfs-csi + proxmox-csi: CSI plugins. We pinned the helm
                #   chart versions today (commit 128cfbbc for nfs-csi); Keel
                #   tracks the image's digest under the CURRENT tag — if
                #   upstream re-pushes a patch under the same tag, Keel rolls.
                # - external-secrets + sealed-secrets: cluster bootstrappers.
                #   Multi-replica + tightly-versioned upstream.
                # - metallb-system: networking critical path. Speaker is a
                #   DaemonSet, controller has 1 replica — a bad roll can
                #   briefly flap LB IPs.
                # - authentik: 2026-05-17 incident bit us when minor bump
                #   2026.2.2 → 2026.2.3 broke pgbouncer connections. With
                #   match-tag=true, digest changes under the same tag string
                #   are rare (upstream stable patch repushes are uncommon).
                #   If they happen we get rolled; restore via helm rollback.
                #
                # Remaining exclusions (7) are irreducible: keel itself,
                # calico-system + tigera-operator (operator-managed),
                # cnpg-system + dbaas (state-coupled), nvidia (pinned to
                # 570.195.03 until NVIDIA ships ubuntu26.04 images per
                # code-8vr0), kube-system (k8s built-ins).
                #
                # 2026-05-29: ADDED postiz. Two Keel failure modes, both
                # unfixable while postiz stays enrolled:
                #   1. Bundled redis StatefulSets run docker.io/bitnamilegacy/
                #      redis (the Broadcom archive repo). Keel hourly resolves
                #      newer patch tags (7.4.0→7.4.1/7.4.2) and tries to roll,
                #      but require-trusted-registries (security-policies.tf)
                #      denies bitnamilegacy/* (only bitnami/* is allowlisted).
                #      Endless deny→retry→Slack-ping loop.
                #   2. Keel bumped postiz-app v2.21.7→v2.21.8 (2026-05-26); the
                #      surge pod can't schedule under the 3Gi tier-4-aux quota,
                #      wedging the rollout for 3 days (rolled back to v2.21.7).
                # postiz Terraform state is heavily drifted (~2/30 resources
                # tracked — memory id=2798/2840), so per-workload opt-out can't
                # be applied from the postiz stack. Namespace exclude here
                # (clean kyverno state) is the reliable guard. Workloads also
                # carry keel.sh/policy=never (annotation+label) set via kubectl
                # since the postiz stack can't apply.
                namespaces = [
                  "keel",
                  "calico-system",
                  "cnpg-system",
                  "dbaas",
                  "nvidia",
                  "kube-system",
                  "tigera-operator",
                  "postiz",
                ]
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
                # 2026-05-26: switched default from `force + match-tag=true`
                # to `patch` after the 2026-05-26 incident proved match-tag
                # does NOT reliably constrain Keel — tag strings got rewritten
                # (uptime-kuma :2→:1, n8n :1.80.5→:0.1.2, dolt-workbench
                # :0.3.73→:0.1.0, wealthfolio :3.2.1→:2.0→:3.2 truncated).
                #
                # `patch` is semver-parser-bounded:
                #   - Only patch bumps within current major.minor
                #     (e.g. 1.2.3 → 1.2.4; never 1.3.x or 2.x).
                #   - Non-semver tags (`:latest`, `:v4`, `:2`, SHA, `:nightly`)
                #     are IGNORED entirely — Keel does nothing for them.
                #   - No more string-comparison surprises.
                #
                # `match-tag` annotation dropped — it was only meaningful as
                # the (failed) safety net under `force`. Irrelevant under
                # semver-bounded policies.
                #
                # `+(...)` anchor = "add only if missing". With the anchor,
                # this policy ONLY sets defaults on new workloads — existing
                # per-workload overrides (set via TF or kubectl annotate)
                # are preserved across policy updates. This was DROPPED for
                # one apply on 2026-05-26 to migrate the 151 stale `force`
                # annotations to `patch`, then re-added in the same session
                # after observing that the label-based exclude rule below
                # doesn't reliably filter mutateExistingOnPolicyUpdate scans
                # (22 workloads with LABEL keel.sh/policy=never still got
                # their ANNOTATION rewritten and had to be repatched). Keep
                # the anchor unless you genuinely want a cluster-wide flip.
                #
                # To override per workload, set the ANNOTATION directly:
                #   - keel.sh/policy=never  (Keel won't touch)
                #   - keel.sh/policy=minor  (wider semver bumps, still bounded)
                #   - keel.sh/policy=major  (any semver bump)
                # The corresponding LABEL keel.sh/policy=never is for the
                # exclude rule below (defense-in-depth against future mutations).
                "+(keel.sh/policy)"       = "patch"
                "+(keel.sh/trigger)"      = "poll"
                "+(keel.sh/pollSchedule)" = "@every 1h"
              }
            }
          }
        }
      }]
    }
  })
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
