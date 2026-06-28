# Calico CNI
#
# Calico has underpinned this cluster's pod networking since 2024-07-30, installed
# as raw kubectl manifests (tigera-operator Deployment + CRDs + Installation CR).
# Bringing the full stack under Terraform is high-blast — the operator and its
# Deployment must never flap during node pressure or during any apply, because
# new pod scheduling breaks within ~seconds of a CNI outage.
#
# This stack (created 2026-04-18 Wave 5b) adopts the three namespaces only:
# calico-system, calico-apiserver, tigera-operator. The `tigera-operator`
# Deployment, the 20+ CRDs it manages, and the `Installation` CR itself are
# intentionally *not* adopted yet — they require a low-traffic window and a
# careful ignore_changes set to cover operator-generated defaults on the
# Installation CR. Follow-up tracked in beads code-3ad.
#
# The namespaces are safe to adopt (no networking impact — they're just label
# containers) and give TF an audit trail entry for the labels/tier Kyverno
# cares about.

resource "kubernetes_namespace" "calico_system" {
  metadata {
    name = "calico-system"
    labels = {
      name = "calico-system"
      # calico-system namespace is managed by tigera-operator — auto-update is
      # incompatible (operator reverts DaemonSet image from its Installation CR).
      # "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode label on every namespace.
    # pod-security.kubernetes.io/* labels are applied by the tigera-operator
    # reconciler on calico-system + calico-apiserver for PSA 'privileged'.
    ignore_changes = [
      metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"],
      metadata[0].labels["pod-security.kubernetes.io/enforce"],
      metadata[0].labels["pod-security.kubernetes.io/enforce-version"],
    ]
  }
}

resource "kubernetes_namespace" "calico_apiserver" {
  metadata {
    name = "calico-apiserver"
    labels = {
      name = "calico-apiserver"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1 + PSA labels applied by tigera-operator (see calico_system).
    ignore_changes = [
      metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"],
      metadata[0].labels["pod-security.kubernetes.io/enforce"],
      metadata[0].labels["pod-security.kubernetes.io/enforce-version"],
    ]
  }
}

resource "kubernetes_namespace" "tigera_operator" {
  metadata {
    name = "tigera-operator"
    labels = {
      name = "tigera-operator"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# Wave 1 W1.6 (beads code-8ywc): observation phase via Calico GlobalNetworkPolicy
# `action: Log`. This is the supported primitive on Calico OSS v3.26 — the
# Calico-Enterprise FelixConfiguration.flowLogsFileEnabled approach is NOT
# accepted by the OSS CRD (verified 2026-05-19: "strict decoding error").
#
# How it works:
#   - GNP selects pods by namespaceSelector
#   - egress rule action=Log writes an iptables NFLOG entry that lands in the
#     kernel log / journald with prefix "calico-packet:" on each node
#   - Alloy DaemonSet already ships node-journal to Loki (job=node-journal)
#   - LogQL query: {job="node-journal"} |= "calico-packet" surfaces egress flows
#   - After ~1 week of observation, build the empirical per-namespace egress
#     allowlist; then flip the same GNP to [Allow specific dests, Deny rest]
#
# Started with `recruiter-responder` as the pilot on 2026-05-19; expanded
# 2026-05-19 to all tier 3+4 namespaces (per locked plan — tier 3-edge has
# 17 ns, tier 4-aux has 65 ns, all use Calico's WorkloadEndpoint policy
# path). Tier 0/1/2 stay out of observation in wave 1 (cluster infra +
# GPU workloads, deferred per the plan).
#
# `apply_only = true` on the kubectl_manifest means renaming the TF resource
# does NOT destroy the old GNP via TF — we kubectl delete the legacy pilot
# GNP after this applies to clean it up. (Tracked manually.)
resource "kubectl_manifest" "wave1_egress_observe_tier34" {
  yaml_body = yamlencode({
    apiVersion = "projectcalico.org/v3"
    kind       = "GlobalNetworkPolicy"
    metadata = {
      name = "wave1-egress-observe-tier34"
      annotations = {
        "security.viktorbarzin.me/wave"    = "1"
        "security.viktorbarzin.me/purpose" = "observe-then-enforce egress for tier 3-edge + 4-aux"
      }
    }
    spec = {
      order             = 2000
      selector          = "all()"
      namespaceSelector = "tier in {\"3-edge\", \"4-aux\"}"
      types             = ["Egress"]
      egress = [
        # Rule 1: log every egress packet (LOG target writes to kernel/journal,
        # alloy ships to Loki with job=node-journal,transport=kernel).
        # LogQL: {job="node-journal"} |~ "calico-packet"
        { action = "Log" },
        # Rule 2: allow everything (observation must NOT break workloads).
        { action = "Allow" },
      ]
    }
  })
  apply_only = true
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00

# CI retrigger v3 2026-05-16T14:06:39Z

# CI retrigger v4 2026-05-16T14:13:59Z

# CI retrigger v5 2026-05-16T23:10:38Z

# CI retrigger v6 2026-05-16T23:18:58Z

# ---------------------------------------------------------------------------
# tigera-operator under Terraform via the official Helm chart (chart vX.Y.Z ==
# Calico vX.Y.Z). Manages ONLY the operator: installation.enabled=false keeps
# the live Installation CR operator-managed, so Helm NEVER touches the data
# plane (calico-node). Adopted in place at the running 3.26.1 (existing operator
# Deployment/SA/ClusterRole/ClusterRoleBinding pre-stamped with Helm ownership
# metadata 2026-06-19 — a transient migration step), then upgraded by bumping
# `version` one step at a time: 3.26 -> 3.28 -> 3.30 (restores a SUPPORTED k8s
# 1.34 pairing) -> 3.32 (supports k8s 1.36). The ~22 Calico CRDs live in the
# chart's crds/ dir, which `helm upgrade` never modifies (pre-3.32). resources
# preserves the operator's existing 256Mi limit. Apply MANUALLY + supervised
# (watch calico-node roll, maxUnavailable:1); gate each hop on tigerastatus +
# calico-node 7/7 + cross-pod connectivity. See docs/runbooks/k8s-version-upgrade.md.
resource "helm_release" "tigera_operator" {
  name             = "calico"
  namespace        = kubernetes_namespace.tigera_operator.metadata[0].name
  create_namespace = false
  repository       = "https://docs.tigera.io/calico/charts"
  chart            = "tigera-operator"
  version          = "v3.30.7"

  values = [yamlencode({
    installation = { enabled = false }
    apiServer    = { enabled = false }
    # Goldmane (flow aggregator) + Whisker (observability UI), new in Calico
    # 3.30, are kept disabled IN HELM on purpose: on a helm UPGRADE their CRs
    # render before their crds/ (which helm skips on upgrade) -> "ensure CRDs
    # are installed first". We instead enable them via the operator CRs applied
    # directly below (kubectl_manifest) now that the CRDs exist — see ADR-0014.
    goldmane = { enabled = false }
    whisker  = { enabled = false }
    # 512Mi (was 256Mi): the operator idles at ~38Mi but its STARTUP spike
    # (re-listing resources to build informer caches) exceeded 256Mi and
    # OOM-crashlooped on 2026-06-23 the first time the pod restarted (a latent
    # landmine — any restart would have triggered it). 512Mi covers the spike;
    # data plane (calico-node) is unaffected by an operator restart.
    resources = { limits = { memory = "512Mi" } }
  })]
}

# ---------------------------------------------------------------------------
# Goldmane + Whisker (Calico 3.30 OSS flow observability) — ADR-0014.
#
# Enabled via the operator CRs directly (NOT the Helm goldmane/whisker flags,
# which stay false above): the goldmanes/whiskers.operator.tigera.io CRDs are
# already installed (operator adopted them 2026-06-19), so we sidestep the
# helm-upgrade "CRs render before crds/" ordering issue by applying the CRs
# ourselves — the running operator reconciles them. Same kubectl_manifest
# pattern as the wave1 GNP above (no plan-time CRD requirement).
#
# Creating the Goldmane CR makes the operator re-render calico-node with the
# FELIX_FLOWLOGSGOLDMANESERVER env (operator auto-wires Felix — do NOT patch
# FelixConfiguration) => a supervised calico-node DaemonSet roll. Goldmane:
# Deployment + Service goldmane:7443 (gRPC/mTLS) in calico-system. Whisker:
# Deployment + Service whisker:8081 in calico-system; its backend dials
# goldmane, so Goldmane must exist first (depends_on). notifications=Disabled
# so the UI does not call the external Tigera notifications endpoint.
#
# NOTE: durable Loki persistence is NOT these CRs. The Goldmane emitter is
# Calico Cloud/Enterprise-gated (no OSS knob to aim it at Loki), so the trail
# is a separate consumer of goldmane's gRPC Flows API (ADR-0014 / issue #58).
# Whisker alone is a ~60-min in-memory live view. Reversible: delete to disable.
resource "kubectl_manifest" "goldmane" {
  depends_on = [helm_release.tigera_operator]
  yaml_body = yamlencode({
    apiVersion = "operator.tigera.io/v1"
    kind       = "Goldmane"
    metadata   = { name = "default" }
  })
}

resource "kubectl_manifest" "whisker" {
  depends_on = [kubectl_manifest.goldmane]
  yaml_body = yamlencode({
    apiVersion = "operator.tigera.io/v1"
    kind       = "Whisker"
    metadata   = { name = "default" }
    spec       = { notifications = "Disabled" }
  })
}

# ---------------------------------------------------------------------------
# Gated public ingress for the Whisker UI (infra #57 / ADR-0014).
#
# whisker.viktorbarzin.me -> whisker:8081, Authentik-gated (auth="required":
# Whisker ships NO own login — it's an admin observability UI, so Authentik
# forward-auth is the only gate between strangers and the flow view). The
# operator replicated `tls-secret` into calico-system already.
#
# TWO coupled pieces are required because the operator's own `whisker`
# NetworkPolicy (owned by the Whisker CR above) sets policyTypes:[Ingress]
# with NO ingress rules => default-deny on ingress to the whisker pod. The
# additive NP below ORs in a Traefik allow (k8s NetworkPolicies are additive
# across policies selecting the same pod), so we never edit the operator NP.
module "ingress_whisker" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = "calico-system"
  name            = "whisker"
  service_name    = "whisker"
  port            = 8081
  auth            = "required"
  tls_secret_name = "tls-secret"
  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/name"        = "Whisker"
    "gethomepage.dev/description" = "Calico flow observability (who-talks-to-whom)"
    "gethomepage.dev/icon"        = "calico.png"
    "gethomepage.dev/group"       = "Infrastructure"
  }
}

# Additive NetworkPolicy: permit Traefik -> whisker:8081. ORs with the
# operator's default-deny `whisker` NP (selecting the same pod) so Traefik
# can reach the UI without touching the operator-owned policy.
resource "kubernetes_network_policy_v1" "whisker_allow_traefik" {
  metadata {
    name      = "whisker-allow-traefik"
    namespace = "calico-system"
  }
  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "whisker"
      }
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "traefik"
          }
        }
      }
      ports {
        port     = "8081"
        protocol = "TCP"
      }
    }
  }
}

# Additive egress NetworkPolicy: permit whisker -> the kube-dns ClusterIP for DNS.
#
# ROOT CAUSE of the 2026-06-28 "Whisker UI empty" incident: the operator's own
# `whisker` NetworkPolicy is policyTypes:[Ingress,Egress] and its egress allows
# DNS only to the kube-dns *pods* (podSelector k8s-app=kube-dns). But
# whisker-backend resolves `goldmane...svc` via the kube-dns *ClusterIP*
# (10.96.0.10), and Calico drops UDP DNS to a ClusterIP under a podSelector-only
# egress rule (verified: from whisker's netns, ClusterIP DNS = 100% timeout
# while direct kube-dns pod-IP DNS = OK; a pod with no egress policy resolves
# fine). whisker-backend resolves once in the brief startup window before the
# policy programs, establishes its long-lived gRPC stream, and only re-resolves
# when that stream breaks — at which point the blocked ClusterIP DNS wedges its
# Go resolver and the UI goes empty (the durable aggregator, in its own
# unrestricted namespace, is unaffected). k8s egress policies are additive, so
# this ORs in an allow for the ClusterIP; the operator NP is left untouched.
# (Empirically: adding this ipBlock rule flips ClusterIP DNS from 100% fail to
# 100% ok.) See docs/runbooks/goldmane-flow-trail.md.
resource "kubernetes_network_policy_v1" "whisker_allow_dns_clusterip" {
  metadata {
    name      = "whisker-allow-dns-clusterip"
    namespace = "calico-system"
  }
  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "whisker"
      }
    }
    policy_types = ["Egress"]
    egress {
      # 10.96.0.10 is the kube-dns ClusterIP (cluster invariant — service CIDR
      # 10.96.0.0/12, DNS always .10; the same IP CoreDNS/Technitium configs pin).
      to {
        ip_block {
          cidr = "10.96.0.10/32"
        }
      }
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Whisker self-heal watchdog (ADR-0014; added 2026-06-28 after a live incident).
#
# BACKSTOP. The REAL fix is kubernetes_network_policy_v1.whisker_allow_dns_clusterip
# above (it unblocks the root-cause ClusterIP DNS). This watchdog stays as
# defense-in-depth: whisker-backend has NO operator liveness probe, so if its
# long-lived goldmane gRPC stream ever wedges for any OTHER reason (the Go
# resolver spams `failed to stream flows` / `code = Unavailable` and never
# reconnects -> empty UI, while the durable aggregator in its own namespace is
# unaffected), nothing else would restart it. Whisker is operator-managed
# (Whisker CR) so we can't inject a probe; this is the supported-pattern
# alternative. With the DNS fix in place it should rarely, if ever, fire.
#
# It restarts the pod ONLY when the wedged signature is present AND Goldmane is
# Ready (so a real Goldmane outage doesn't cause restart-thrash). A fresh pod
# reconnects cleanly. See docs/runbooks/goldmane-flow-trail.md.
resource "kubernetes_service_account" "whisker_watchdog" {
  metadata {
    name      = "whisker-watchdog"
    namespace = kubernetes_namespace.calico_system.metadata[0].name
  }
}

# Namespaced Role (least privilege — only calico-system): read pod logs to
# detect the wedge, delete the whisker pod to heal it.
resource "kubernetes_role" "whisker_watchdog" {
  metadata {
    name      = "whisker-watchdog"
    namespace = kubernetes_namespace.calico_system.metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "delete"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get"]
  }
}

resource "kubernetes_role_binding" "whisker_watchdog" {
  metadata {
    name      = "whisker-watchdog"
    namespace = kubernetes_namespace.calico_system.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.whisker_watchdog.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.whisker_watchdog.metadata[0].name
    namespace = kubernetes_namespace.calico_system.metadata[0].name
  }
}

resource "kubernetes_cron_job_v1" "whisker_watchdog" {
  metadata {
    name      = "whisker-watchdog"
    namespace = kubernetes_namespace.calico_system.metadata[0].name
  }
  spec {
    schedule                      = "*/10 * * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 1
    concurrency_policy            = "Forbid"
    job_template {
      metadata {
        name = "whisker-watchdog"
      }
      spec {
        template {
          metadata {
            name = "whisker-watchdog"
          }
          spec {
            service_account_name = kubernetes_service_account.whisker_watchdog.metadata[0].name
            container {
              name  = "watchdog"
              image = "bitnami/kubectl:latest"
              command = ["/bin/sh", "-c", <<-EOT
                set -eu
                NS=calico-system
                # Don't thrash if Goldmane itself is down — that's not a whisker bug.
                if ! kubectl -n "$NS" get pod -l k8s-app=goldmane \
                     -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
                  echo "goldmane not Ready — skipping (not a whisker problem)"; exit 0
                fi
                ERRS=$(kubectl -n "$NS" logs -l k8s-app=whisker -c whisker-backend --since=11m --tail=500 2>/dev/null \
                  | grep -cE 'failed to stream flows|failed to list filter hints|code = Unavailable|i/o timeout' || true)
                ERRS=$${ERRS:-0}
                if [ "$ERRS" -ge 10 ]; then
                  echo "whisker-backend WEDGED: $ERRS goldmane-connection errors in 11m — restarting whisker pod"
                  kubectl -n "$NS" delete pod -l k8s-app=whisker --ignore-not-found
                else
                  echo "whisker-backend healthy: $ERRS goldmane-connection errors in 11m"
                fi
              EOT
              ]
            }
            restart_policy = "Never"
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}
