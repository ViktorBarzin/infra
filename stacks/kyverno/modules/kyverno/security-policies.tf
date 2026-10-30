# =============================================================================
# Pod Security Policies
# =============================================================================
# Kyverno validate policies for pod security standards.
# Wave 1 (locked 2026-05-18, beads code-8ywc): deny-privileged-containers,
# deny-host-namespaces, restrict-sys-admin flipped from Audit → Enforce with
# a shared 32-namespace exclude list. require-trusted-registries followed on
# 2026-05-19 — also Enforce now, with an explicit registry allowlist (the
# `*/*` catch-all was removed so unknown registries fail closed at admission).
# To allow a new image source, add it to policy_require_trusted_registries below.
# failurePolicy stays Ignore (chart-level) to prevent admission webhook
# failures from cascading.

# Shared namespace exclude list: 30 critical namespaces first listed for the
# Keel rollout (memory id=1970) + `frigate` (legitimately needs host access for
# camera RTSP). `keel` left the list when Keel was retired (2026-10-11).
locals {
  security_policy_exclude_namespaces = [
    "calico-system", "authentik", "vault", "cnpg-system", "dbaas",
    "monitoring", "traefik", "technitium", "mailserver", "kyverno",
    "metallb-system", "external-secrets", "proxmox-csi", "nfs-csi", "nvidia",
    "kube-system", "cloudflared", "crowdsec", "reverse-proxy", "reloader",
    "descheduler", "vpa", "redis", "sealed-secrets", "headscale", "wireguard",
    "xray", "infra-maintenance", "metrics-server", "tigera-operator", "frigate",
    # Additions discovered during wave 1 enforce flip — these contain workloads
    # that legitimately need privileged / hostNetwork / SYS_ADMIN:
    "kured",            # kured DaemonSet is privileged (manages node reboots)
    "default",          # etcd backup + defrag CronJobs use hostNetwork
    "changedetection",  # uses SYS_ADMIN for chromium sandbox
    "woodpecker",       # CI pipeline pods (wp-*) run privileged docker builds
    "android-emulator", # emulator pod is privileged for /dev/kvm (ADR-0001)
  ]

  # Image allowlist for require-trusted-registries. Every entry is a prefix
  # followed by one trailing "*", which the ValidatingPolicy checks with
  # startsWith (the ClusterPolicy matched the same strings as wildcards).
  trusted_registry_patterns = [
    # Explicit registries
    "docker.io/*", "ghcr.io/*", "quay.io/*", "registry.k8s.io/*",
    "gcr.io/*", "us-docker.pkg.dev/*", "lscr.io/*",
    "codeberg.org/*", "mcr.microsoft.com/*", "nvcr.io/*",
    "oci.external-secrets.io/*", "reg.kyverno.io/*",
    "docker.n8n.io/*", "registry.gitlab.com/*",
    # Trivy Operator (2026-10-10): the trivy-operator chart
    # 0.37.0 pulls the operator, the Trivy server and every scan
    # job from mirror.gcr.io/aquasec/{trivy-operator,trivy}.
    # Scoped to the aquasec path rather than all of mirror.gcr.io.
    # The node-collector comes from ghcr.io, already allowed.
    "mirror.gcr.io/aquasec/*",
    # Private
    "forgejo.viktorbarzin.me/*", "10.0.20.10*",
    # Legacy private registry (decommissioned 2026-05-07 per CLAUDE.md).
    # No live workload pulls from it; only stale completed Job records
    # (e.g. old wealthfolio-sync jobs) still carry the image ref.
    "registry.viktorbarzin.me/*",
    # DockerHub library (bare image names without slash)
    "alpine*", "busybox*", "kong*", "mysql*", "nginx*", "postgres*", "python*",
    # DockerHub user repos (no registry prefix, has slash) —
    # enumerated from current cluster state. New entries added
    # 2026-05-22 after Enforce caught these as unallowlisted:
    # amruthpillai (resume), athomasson2 (ebook2audiobook),
    # netboxcommunity (netbox), nousresearch (hermes-agent),
    # opentripplanner (osm-routing), rhasspy (whisper/piper).
    # 2026-06-05: mauriceboe (TREK group-trip planner trial).
    "actualbudget/*", "afadil/*", "amruthpillai/*", "athomasson2/*",
    "binwiederhier/*", "bitnami/*",
    "apache/*", "clickhouse/*", "cloudflare/*", "coturn/*", "crowdsecurity/*",
    "curlimages/*", "deluan/*", "dgtlmoon/*", "dolthub/*",
    "dpage/*", "dperson/*", "edoburu/*", "esanchezm/*",
    "freikin/*", "freshrss/*", "gotenberg/*", "hackmdio/*", "hashicorp/*",
    "headscale/*", "jhonderson/*", "kebe/*", "library/*",
    "lissy93/*", "louislam/*", "matrixdotorg/*", "mauriceboe/*",
    "mendhak/*",
    "mghee/*", "mindflavor/*", "mpepping/*", "netboxcommunity/*",
    "netsampler/*", "nousresearch/*", "nvidia/*",
    # 2026-10-30: osminogin (tor-simple, replaced dperson/torproxy).
    "osminogin/*",
    "openresty/*", "opentripplanner/*", "owntracks/*",
    "phpipam/*", "phpmyadmin/*", "privatebin/*", "prom/*",
    # 2026-07-12: sablierapp (scale-to-zero wake layer, ADR-0022).
    "prompve/*", "rancher/*", "rhasspy/*", "roundcube/*",
    "sablierapp/*", "sclevine/*",
    "shadowsocks/*", "shlinkio/*", "stirlingtools/*",
    "technitium/*", "teddysun/*", "temporalio/*",
    "typhonragewind/*", "tzahi12345/*", "vabene1111/*",
    "vaultwarden/*", "viktorbarzin/*", "viren070/*",
    "woodpeckerci/*", "zelest/*",
  ]
  trusted_registry_prefixes = [for p in local.trusted_registry_patterns : trimsuffix(p, "*")]
}

resource "kubectl_manifest" "policy_deny_privileged" {
  yaml_body = templatefile("${path.module}/policies/deny-privileged-containers.yaml", { exclude = jsonencode(local.security_policy_exclude_namespaces) })

  # Kind changed from the kyverno.io ClusterPolicy types: create the CEL
  # policy before deleting the old one, so admission is never uncovered.
  lifecycle {
    create_before_destroy = true
  }

  depends_on = [helm_release.kyverno]
}

resource "kubectl_manifest" "policy_deny_host_namespaces" {
  yaml_body = templatefile("${path.module}/policies/deny-host-namespaces.yaml", { exclude = jsonencode(local.security_policy_exclude_namespaces) })

  # Kind changed from the kyverno.io ClusterPolicy types: create the CEL
  # policy before deleting the old one, so admission is never uncovered.
  lifecycle {
    create_before_destroy = true
  }

  depends_on = [helm_release.kyverno]
}

resource "kubectl_manifest" "policy_restrict_capabilities" {
  yaml_body = templatefile("${path.module}/policies/restrict-sys-admin.yaml", { exclude = jsonencode(local.security_policy_exclude_namespaces) })

  # Kind changed from the kyverno.io ClusterPolicy types: create the CEL
  # policy before deleting the old one, so admission is never uncovered.
  lifecycle {
    create_before_destroy = true
  }

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
  yaml_body = file("${path.module}/policies/set-image-pull-policy.yaml")

  # Kind changed from the kyverno.io ClusterPolicy types: create the CEL
  # policy before deleting the old one, so admission is never uncovered.
  lifecycle {
    create_before_destroy = true
  }

  depends_on = [helm_release.kyverno]
}

resource "kubectl_manifest" "policy_require_trusted_registries" {
  yaml_body = templatefile("${path.module}/policies/require-trusted-registries.yaml", { exclude = jsonencode(local.security_policy_exclude_namespaces), prefixes = jsonencode(local.trusted_registry_prefixes) })

  # Kind changed from the kyverno.io ClusterPolicy types: create the CEL
  # policy before deleting the old one, so admission is never uncovered.
  lifecycle {
    create_before_destroy = true
    precondition {
      condition     = alltrue([for p in local.trusted_registry_patterns : endswith(p, "*") && length(split("*", p)) == 2])
      error_message = "Each trusted_registry_patterns entry must be a prefix with exactly one trailing \"*\"."
    }
  }

  depends_on = [helm_release.kyverno]
}

# =============================================================================
# PolicyException: Trivy Operator node-collector
# =============================================================================
# The Trivy Operator (stacks/trivy-operator) runs one node-collector Job per
# node to read kubelet, etcd and CNI config for the infra assessment and CIS
# checks. Its pod template comes from trivy-kubernetes v0.9.1
# (pkg/jobs/template/node-collector.yaml), pinned by trivy-operator v0.35.0:
#   - hostPID: true                       -> blocked by deny-host-namespaces
#   - read-only hostPath mounts of /var/lib/{etcd,kubelet,kube-scheduler,
#     kube-controller-manager}, /etc/systemd, /lib/systemd, /etc/kubernetes,
#     /etc/cni/net.d                      -> no policy here covers hostPath
#   - runAsUser 0, privileged: false, allowPrivilegeEscalation: false,
#     capabilities drop ALL, readOnlyRootFilesystem
# So it needs exactly one exemption: hostPID. deny-privileged-containers and
# restrict-sys-admin already pass, and the image (ghcr.io/aquasecurity/
# node-collector) is on the trusted list.
#
# The Job is admitted first, so the autogen rule for Jobs needs the same
# exemption as the Pod rule. Scope is the trivy-system namespace and the
# node-collector-<hash> name the operator gives each Job and its Pod. Scan
# jobs (scan-vulnerabilityreport-*) do not match and stay fully enforced.
resource "kubectl_manifest" "policy_exception_trivy_node_collector" {
  yaml_body = file("${path.module}/policies/trivy-node-collector-hostpid.yaml")

  # Kind changed from the kyverno.io ClusterPolicy types: create the CEL
  # policy before deleting the old one, so admission is never uncovered.
  lifecycle {
    create_before_destroy = true
  }

  depends_on = [helm_release.kyverno, kubectl_manifest.policy_deny_host_namespaces]
}
