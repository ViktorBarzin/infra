variable "nfs_server" { type = string }

# Loki + Alloy — re-enabled 2026-05-18 for wave 1 security audit logging
# (beads code-8ywc + code-146x). Original disable rationale was "operational
# overhead vs benefit after node2 incident" — re-evaluated because the wave 1
# detection layer (K8s audit, Vault audit, source-IP anomaly rules) needs Loki.
# Resource budget: SingleBinary mode, 2-4Gi memory, 50Gi proxmox-lvm PVC,
# 30-day retention, ruler enabled pointed at prometheus-alertmanager.
resource "helm_release" "loki" {
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = true
  name             = "loki"

  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"

  values  = [templatefile("${path.module}/loki.yaml", {})]
  timeout = 600

  depends_on = [kubernetes_config_map.loki_alert_rules]
}

resource "helm_release" "alloy" {
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = true
  name             = "alloy"

  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"

  values  = [file("${path.module}/alloy.yaml")]
  atomic  = true
  timeout = 900 # 5-pod DS rolling update + occasional runc-stuck-Terminating on k8s-master needs >300s default

  depends_on = [helm_release.loki]
}

# inotify limits raised for Alloy pod log tailing (one watch per container).
resource "kubernetes_daemon_set_v1" "sysctl-inotify" {
  metadata {
    name      = "sysctl-inotify"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app = "sysctl-inotify"
    }
  }
  spec {
    selector {
      match_labels = {
        app = "sysctl-inotify"
      }
    }
    template {
      metadata {
        labels = {
          app = "sysctl-inotify"
        }
      }
      spec {
        init_container {
          name  = "sysctl"
          image = "busybox:1.37"
          command = [
            "sh", "-c",
            "sysctl -w fs.inotify.max_user_watches=1048576 && sysctl -w fs.inotify.max_user_instances=8192 && sysctl -w fs.inotify.max_queued_events=1048576"
          ]
          security_context {
            privileged = true
          }
        }
        container {
          name  = "pause"
          image = "registry.k8s.io/pause:3.10"
          resources {
            requests = {
              cpu    = "1m"
              memory = "4Mi"
            }
            limits = {
              cpu    = "1m"
              memory = "4Mi"
            }
          }
        }
        host_pid = true
        toleration {
          operator = "Exists"
        }
        dns_config {
          option {
            name  = "ndots"
            value = "2"
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    # KEEL: monitoring ns is keel-enrolled — Keel owns the pause image tag and
    # injects keel.sh annotations. Ignore so TF stops reverting Keel each plan
    # (completes the cdb7d9a8 KEEL sweep that missed this daemonset and was
    # tripping drift-detection exit 2 every run). 2026-05-31.
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
      metadata[0].labels["tier"],                                         # tier stamped live by tier-labeling; TF doesn't declare it here
    ]
  }
}

# resource "helm_release" "k8s-monitoring" {
#  namespace = kubernetes_namespace.monitoring.metadata[0].name
#   create_namespace = true
#   name             = "k8s-monitoring"

#   repository = "https://grafana.github.io/helm-charts"
#   chart      = "k8s-monitoring"

#   values = [templatefile("${path.module}/k8s-monitoring-values.yaml", {})]
#   atomic = true
# }

resource "kubernetes_config_map" "loki_alert_rules" {
  metadata {
    name      = "loki-alert-rules"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "rules.yaml" = yamlencode({
      groups = [
        {
          name = "Node Health"
          rules = [
            {
              alert = "KernelOOMKiller"
              expr  = "sum by (node) (count_over_time({job=\"node-journal\"} |~ \"(?i)Out of memory.*Killed process\" [5m])) > 0"
              for   = "0m"
              labels = {
                severity = "critical"
              }
              annotations = {
                summary = "OOM killer active on {{ $labels.node }}"
              }
            },
            {
              alert = "KernelPanic"
              expr  = "sum by (node) (count_over_time({job=\"node-journal\"} |~ \"(?i)Kernel panic\" [5m])) > 0"
              for   = "0m"
              labels = {
                severity = "critical"
              }
              annotations = {
                summary = "Kernel panic on {{ $labels.node }}"
              }
            },
            {
              alert = "KernelHungTask"
              expr  = "sum by (node) (count_over_time({job=\"node-journal\"} |~ \"blocked for more than\" [5m])) > 0"
              for   = "0m"
              labels = {
                severity = "warning"
              }
              annotations = {
                summary = "Hung task detected on {{ $labels.node }}"
              }
            },
            {
              alert = "KernelSoftLockup"
              expr  = "sum by (node) (count_over_time({job=\"node-journal\"} |~ \"(?i)soft lockup\" [5m])) > 0"
              for   = "0m"
              labels = {
                severity = "critical"
              }
              annotations = {
                summary = "Soft lockup on {{ $labels.node }}"
              }
            },
            {
              alert = "ContainerdDown"
              expr  = "sum by (node) (count_over_time({job=\"node-journal\", unit=\"containerd.service\"} |~ \"(?i)(dead|failed|deactivating)\" [5m])) > 0"
              for   = "1m"
              labels = {
                severity = "critical"
              }
              annotations = {
                summary = "containerd service unhealthy on {{ $labels.node }}"
              }
            },
          ]
        },
        {
          # t3 session-auth + auto-upgrade health (devvm host scripts → journald →
          # Loki). Backstops the gated-nightly t3 tracker: the dispatch logs every
          # real-user pairing outcome (success endpoint + fallback) and the enforcer
          # logs every rollback/freeze. These catch a bad nightly that broke pairing
          # for real users between the tracker's own bump-time gate runs — the
          # 2026-06-09 failure class (mint/bootstrap broke, all users on the pair
          # prompt). Route: Loki ruler → Alertmanager → default #alerts Slack.
          # Runbook: docs/runbooks/t3-version-bump.md.
          name = "t3 Auth & Upgrades"
          rules = [
            {
              # Real users failing to pair: mint error, exchange transport error, or
              # a non-2xx from the instance pairing API. Threshold >3/10m rides out a
              # benign single-instance restart race; sustained = pairing is broken.
              alert  = "T3PairingBroken"
              expr   = "sum(count_over_time({job=\"devvm-journal\", unit=\"t3-dispatch.service\"} |~ \"mint for .* failed|pairing exchange for .* failed|pairing for .* returned [0-9]\" [10m])) > 3"
              for    = "5m"
              labels = { severity = "critical" }
              annotations = {
                summary     = "t3 dispatch pairing is failing for real users (>3/10m)"
                description = "t3-dispatch is failing to mint/exchange session cookies — users land on the t3 pair prompt instead of their workspace. Likely a bad t3 build broke the pairing API/schema (2026-06-09 class). Freeze the tracker (touch /etc/t3-autoupdate.freeze) and roll back per the runbook."
                runbook     = "docs/runbooks/t3-version-bump.md"
              }
            },
            {
              # The dispatch fell back off its first-preference pairing endpoint
              # (browser-session) to the legacy one — the running build moved/renamed
              # the pairing API. Pin-compatible today (the fallback works), but it
              # signals contract drift that a future build could break entirely.
              alert  = "T3PairFallbackHigh"
              expr   = "sum(count_over_time({job=\"devvm-journal\", unit=\"t3-dispatch.service\"} |~ \"paired .* fallback=true\" [30m])) > 0"
              for    = "0m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "t3 dispatch is using the FALLBACK pairing endpoint — t3 moved the pairing API"
                description = "A t3 build is pairing via the legacy /api/auth/bootstrap because the preferred /api/auth/browser-session 404s. Still works via fallback, but add the new endpoint to pairEndpoints in scripts/t3-dispatch/main.go before a future build drops the legacy one."
                runbook     = "docs/runbooks/t3-version-bump.md"
              }
            },
            {
              # The enforcer's health-check failed a build and auto-rolled-back the
              # binary. The gate worked — but a bad nightly shipped, so you should know.
              alert  = "T3AutoUpdateRolledBack"
              expr   = "sum(count_over_time({job=\"devvm-journal\", identifier=\"t3-autoupdate\"} |~ \"rolling back|rolled back\" [15m])) > 0"
              for    = "0m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "t3 auto-update rolled back a bad build (gate worked)"
                description = "The t3 enforcer installed a new build, its pairing health-check failed, and it auto-rolled-back. Investigate the bad build before the next cycle retries it; pin T3_PIN to a known-good if it recurs."
                runbook     = "docs/runbooks/t3-version-bump.md"
              }
            },
            {
              # Rollback itself failed (npm couldn't reinstall the previous build):
              # the box may be left on a broken t3. Manual fix needed.
              alert  = "T3AutoUpdateRollbackFailed"
              expr   = "sum(count_over_time({job=\"devvm-journal\", identifier=\"t3-autoupdate\"} |~ \"ROLLBACK FAILED\" [15m])) > 0"
              for    = "0m"
              labels = { severity = "critical" }
              annotations = {
                summary     = "t3 auto-update rollback FAILED — t3 may be broken on the devvm"
                description = "The enforcer detected a bad build but could not reinstall the previous version. t3 may be broken for all users. Fix manually per the runbook (set T3_PIN to last-good, npm i -g, restore state if migrated)."
                runbook     = "docs/runbooks/t3-version-bump.md"
              }
            },
            {
              # The tracker refused to advance (pre-run auth gate tripped, or the
              # /etc/t3-autoupdate.freeze switch is set). Surfaces a stuck-on-purpose
              # tracker so it isn't silently frozen forever.
              alert  = "T3AutoUpdateFrozen"
              expr   = "sum(count_over_time({job=\"devvm-journal\", identifier=\"t3-autoupdate\"} |~ \"FROZEN\" [25h])) > 0"
              for    = "0m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "t3 auto-update is FROZEN (not tracking nightly)"
                description = "The t3 tracker froze — either the pre-run pairing gate tripped or /etc/t3-autoupdate.freeze is set. t3 is held at the last-good pin and is NOT picking up new builds until cleared. Confirm pairing is healthy, then remove the freeze."
                runbook     = "docs/runbooks/t3-version-bump.md"
              }
            },
            {
              # Per-user Claude refresh/backup/restore exhausted its automatic
              # recovery path. This is actionable: that user needs interactive SSO,
              # or the scoped Vault token/bootstrap needs repair.
              alert  = "WorkstationClaudeAuthInvalid"
              expr   = "sum by (unit) (count_over_time({job=\"devvm-journal\", identifier=\"claude-auth-sync\"} |~ \"FAIL\" [15m])) > 0"
              for    = "0m"
              labels = { severity = "warning" }
              annotations = {
                summary     = "Per-user Claude authentication recovery failed on {{ $labels.unit }}"
                description = "The Workstation renewal agent could not validate Claude auth, renew its scoped Vault token, or recover from the Vault backup. Follow the per-user SSO recovery runbook."
                runbook     = "docs/runbooks/claude-auth-renew-workstation.md"
              }
            },
          ]
        },
        {
          # Wave 1 security alerts (beads code-8ywc). Routed via Loki ruler →
          # prometheus-alertmanager → #security Slack receiver. Allowlist CIDRs:
          # 10.0.20.0/22, 192.168.1.0/24, K8s pod CIDR 10.10.0.0/16, K8s service
          # CIDR 10.96.0.0/12. Identity allowlist: me@viktorbarzin.me only.
          # NOTE: K1 (cluster-admin grant) intentionally skipped.
          name = "Security Wave 1"
          rules = [
            # V1: Root token created (Vault audit, vault-tail sidecar stream)
            {
              alert  = "VaultRootTokenCreated"
              expr   = "sum(count_over_time({namespace=\"vault\",container=\"audit-tail\"} | json | request_path=\"auth/token/create\" |~ \"\\\"policies\\\":\\\\[\\\"root\\\"\\\\]\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary     = "Vault root token created"
                description = "A token with policies=[root] was issued via auth/token/create. Verify this is a planned bootstrap or break-glass; otherwise treat as critical compromise."
                runbook     = "docs/runbooks/security-incident.md#v1-root-token-created"
              }
            },
            # V2: Audit device disabled/modified
            {
              alert  = "VaultAuditDeviceModified"
              expr   = "sum(count_over_time({namespace=\"vault\",container=\"audit-tail\"} | json | request_path=~\"sys/audit/.+\" | operation=~\"(create|delete|update)\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "Vault audit device modified — attacker may be silencing visibility"
                runbook = "docs/runbooks/security-incident.md#v2-audit-device-disabledmodified"
              }
            },
            # V3: Seal status changed
            {
              alert  = "VaultSealChanged"
              expr   = "sum(count_over_time({namespace=\"vault\",container=\"audit-tail\"} | json | request_path=\"sys/seal\" | operation=\"update\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "Vault seal status changed via API — confirm planned operation"
                runbook = "docs/runbooks/security-incident.md#v3-seal-status-changed"
              }
            },
            # V4: Policy modified
            {
              alert  = "VaultPolicyModified"
              expr   = "sum(count_over_time({namespace=\"vault\",container=\"audit-tail\"} | json | request_path=~\"sys/policies/acl/.+\" | operation=~\"(create|update|delete)\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "warning", lane = "security" }
              annotations = {
                summary = "Vault policy modified — verify Terraform-driven change"
                runbook = "docs/runbooks/security-incident.md#v4-policy-modified"
              }
            },
            # V5: Auth failure spike
            {
              alert  = "VaultAuthFailureSpike"
              expr   = "sum(count_over_time({namespace=\"vault\",container=\"audit-tail\"} | json | type=\"response\" |~ \"\\\"error\\\":\\\"permission denied\\\"\" [1m])) > 10"
              for    = "1m"
              labels = { severity = "warning", lane = "security" }
              annotations = {
                summary = "Vault permission-denied spike >10/min — possible brute force or CI rotation glitch"
                runbook = "docs/runbooks/security-incident.md#v5-auth-failure-spike"
              }
            },
            # V7: Viktor identity from non-allowlist source IP
            # XFF trust enabled, so request.remote_address is the real client IP.
            # Allowlist regex covers: 10.0.20.x, 192.168.1.x, pod CIDR 10.10.x.x,
            # service CIDR 10.96-111.x.x, Headscale tailnet 100.64-127.x.x.
            {
              alert  = "VaultViktorFromUnexpectedIP"
              expr   = "sum(count_over_time({namespace=\"vault\",container=\"audit-tail\"} | json | auth_metadata_username=\"me@viktorbarzin.me\" | request_remote_address!~\"^(10\\\\.0\\\\.2[0-3]\\\\.|192\\\\.168\\\\.1\\\\.|10\\\\.10\\\\.|10\\\\.(9[6-9]|1[01][0-9]|111)\\\\.|100\\\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\\\.).*\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "Vault auth as me@viktorbarzin.me from non-allowlist source IP — possible stolen OIDC token"
                runbook = "docs/runbooks/security-incident.md#v7-viktors-vault-identity-from-unexpected-source-ip"
              }
            },
            # K2: ServiceAccount token used from outside cluster.
            # Allowlist = pod CIDR + LAN + Headscale tailnet. Anything else =
            # likely stolen SA token used externally.
            {
              alert  = "K8sSATokenFromUnexpectedIP"
              expr   = "sum(count_over_time({job=\"kubernetes-audit\"} | json | user_username=~\"system:serviceaccount:.+\" | sourceIPs_0!~\"^(10\\\\.0\\\\.2[0-3]\\\\.|192\\\\.168\\\\.1\\\\.|10\\\\.10\\\\.|10\\\\.(9[6-9]|1[01][0-9]|111)\\\\.|100\\\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\\\.).*\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "K8s ServiceAccount token used from non-allowlist source IP — possible stolen SA token"
                runbook = "docs/runbooks/security-incident.md#k2-serviceaccount-token-used-from-outside-cluster"
              }
            },
            # K3: Secret read in sensitive namespace by unexpected actor.
            # Allowlisted readers: ESO controller, sealed-secrets controller,
            # Vault SA, me@viktorbarzin.me. Anyone else = alert.
            {
              alert  = "K8sSensitiveSecretReadByUnexpectedActor"
              expr   = "sum(count_over_time({job=\"kubernetes-audit\"} | json | verb=~\"get|list\" | objectRef_resource=\"secrets\" | objectRef_namespace=~\"vault|sealed-secrets|external-secrets\" | user_username!~\"^(me@viktorbarzin\\\\.me|system:serviceaccount:external-secrets:.+|system:serviceaccount:sealed-secrets:.+|system:serviceaccount:vault:.+)$\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "Sensitive Secret read in vault/sealed-secrets/external-secrets by non-allowlisted actor"
                runbook = "docs/runbooks/security-incident.md#k3-secret-read-in-sensitive-namespace-by-unexpected-actor"
              }
            },
            # K4: Exec into pod in sensitive namespace.
            {
              alert  = "K8sExecIntoSensitiveNamespace"
              expr   = "sum(count_over_time({job=\"kubernetes-audit\"} | json | verb=\"create\" | objectRef_resource=\"pods\" | objectRef_subresource=\"exec\" | objectRef_namespace=~\"vault|kube-system|dbaas|cnpg-system\" | user_username!=\"me@viktorbarzin.me\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "warning", lane = "security" }
              annotations = {
                summary = "kubectl exec into sensitive namespace (vault/kube-system/dbaas/cnpg-system) by non-Viktor actor"
                runbook = "docs/runbooks/security-incident.md#k4-exec-into-sensitive-pod"
              }
            },
            # K5: Mass delete of pods/secrets/configmaps in 60s by single actor.
            {
              alert  = "K8sMassDelete"
              expr   = "sum by (user_username) (count_over_time({job=\"kubernetes-audit\"} | json | verb=\"delete\" | objectRef_resource=~\"pods|secrets|configmaps\" [1m])) > 5"
              for    = "1m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "Mass delete (>5 Pod/Secret/ConfigMap in 60s) by {{ $labels.user_username }}"
                runbook = "docs/runbooks/security-incident.md#k5-mass-delete"
              }
            },
            # K6: Audit policy or audit-log path modified — attacker silencing
            # visibility. The audit policy file is /etc/kubernetes/policies/audit-policy.yaml
            # on master; changes go via kubeadm reconfig. Detect via API access
            # to apiserver kubeadm-config ConfigMap.
            {
              alert  = "K8sAuditPolicyModified"
              expr   = "sum(count_over_time({job=\"kubernetes-audit\"} | json | verb=~\"update|patch\" | objectRef_resource=\"configmaps\" | objectRef_name=\"kubeadm-config\" | objectRef_namespace=\"kube-system\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "kubeadm-config ConfigMap modified — could be audit policy change"
                runbook = "docs/runbooks/security-incident.md#k6-audit-policy-modified"
              }
            },
            # K7: New ClusterRole created with verbs=* and resources=*.
            # Allowlist excludes calico-system, kyverno, nvidia, etc. which legitimately
            # create such ClusterRoles via Helm.
            {
              alert  = "K8sClusterRoleWildcardCreated"
              expr   = "sum(count_over_time({job=\"kubernetes-audit\"} | json | verb=\"create\" | objectRef_resource=\"clusterroles\" |~ \"\\\"verbs\\\":\\\\[\\\"\\\\*\\\"\\\\]\" |~ \"\\\"resources\\\":\\\\[\\\"\\\\*\\\"\\\\]\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "warning", lane = "security" }
              annotations = {
                summary = "New ClusterRole with verbs=[*]+resources=[*] created — privilege escalation primitive"
                runbook = "docs/runbooks/security-incident.md#k7-new-clusterrole-with-full-wildcards"
              }
            },
            # K8: Anonymous binding granted — catastrophic.
            {
              alert  = "K8sAnonymousBindingGranted"
              expr   = "sum(count_over_time({job=\"kubernetes-audit\"} | json | verb=\"create\" | objectRef_resource=~\"rolebindings|clusterrolebindings\" |~ \"system:(anonymous|unauthenticated)\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "Binding granted to system:anonymous or system:unauthenticated — full cluster compromise risk"
                runbook = "docs/runbooks/security-incident.md#k8-anonymous-binding"
              }
            },
            # K9: Viktor's identity from non-allowlist source IP. Same regex as V7.
            {
              alert  = "K8sViktorFromUnexpectedIP"
              expr   = "sum(count_over_time({job=\"kubernetes-audit\"} | json | user_username=\"me@viktorbarzin.me\" | sourceIPs_0!~\"^(10\\\\.0\\\\.2[0-3]\\\\.|192\\\\.168\\\\.1\\\\.|10\\\\.10\\\\.|10\\\\.(9[6-9]|1[01][0-9]|111)\\\\.|100\\\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\\\.).*\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "K8s API request as me@viktorbarzin.me from non-allowlist source IP — possible stolen kubeconfig/OIDC token"
                runbook = "docs/runbooks/security-incident.md#k9-viktors-identity-from-unexpected-source-ip"
              }
            },
            # S1: PVE sshd auth success from non-allowlist IP.
            # Conditional on the pve-sshd promtail unit being live on PVE host
            # (deployed via stacks/infra/scripts — out of scope until W1.3 host
            # piece lands). Rule is defined so it fires automatically once logs
            # flow with job=sshd-pve.
            {
              alert  = "PVEsshLoginFromUnexpectedIP"
              expr   = "sum(count_over_time({job=\"sshd-pve\"} |~ \"Accepted (publickey|password|keyboard-interactive)\" | regexp \"Accepted (?P<method>\\\\S+) for (?P<user>\\\\S+) from (?P<ip>\\\\S+) port\" | ip!~\"^(10\\\\.0\\\\.2[0-3]\\\\.|192\\\\.168\\\\.1\\\\.|100\\\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\\\.).*\" [5m])) > 0"
              for    = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "PVE sshd login from non-allowlist source IP — possible stolen SSH key"
                runbook = "docs/runbooks/security-incident.md#s1-pve-sshd-auth-success-from-unexpected-ip"
              }
            },
          ]
        },
        {
          # Matrix (tuwunel) — open registration is ON, so notify on every new
          # signup. tuwunel logs `... New user "@x:..." registered on this server`
          # only on SUCCESS (the disabled-path logs "Rejecting ... registration is
          # disabled"), so this matcher never false-fires on rejected attempts.
          # lane=security routes it to the existing #security Slack receiver.
          name = "Matrix"
          rules = [
            {
              alert  = "MatrixNewUserRegistered"
              expr   = "sum(count_over_time({namespace=\"matrix\",container=\"matrix\"} |= \"registered on this server\" [10m])) > 0"
              for    = "0m"
              labels = { severity = "info", lane = "security" }
              annotations = {
                summary     = "New user registered on Matrix (tuwunel) — open registration is ON"
                description = "A new account was created on matrix.viktorbarzin.me. See who with: kubectl -n matrix logs deploy/matrix | grep 'New user'. If unexpected/abuse, revert to token-gated registration in stacks/matrix."
              }
            },
          ]
        },
        {
          # Vaultwarden vault CLI (`homelab vault`) traceability. The audit SPINE
          # is the Vault audit device (reads of secret/data/workstation/claude-users/*
          # are already captured in the vault-tail stream above). These add
          # visibility/anomaly alerts off the per-user CLI op-log
          # (`logger -t homelab-vault[-totp]` → devvm-journal). A true "Vault
          # creds-read with NO matching CLI op-log = direct bypass" alert needs
          # cross-stream correlation the Loki ruler can't express — tracked as a
          # follow-up (small correlation CronJob). lane=security → #security.
          name = "Vaultwarden vault CLI"
          rules = [
            {
              alert  = "VaultwardenTOTPFetched"
              expr   = "sum by (user) (count_over_time({job=\"devvm-journal\", identifier=\"homelab-vault-totp\"} | logfmt [5m])) > 0"
              for    = "0m"
              labels = { severity = "info", lane = "security" }
              annotations = {
                summary     = "Vaultwarden TOTP (2nd factor) fetched via homelab vault by {{ $labels.user }}"
                description = "A TOTP code was retrieved with `homelab vault code`. A stored TOTP co-located with its password collapses that downstream account's 2FA to 1FA under a same-UID compromise — confirm this fetch was expected."
              }
            },
            {
              alert  = "VaultwardenFetchVolumeHigh"
              expr   = "sum by (user) (count_over_time({job=\"devvm-journal\", identifier=\"homelab-vault\"} | logfmt | verb=~\"get|code\" [10m])) > 100"
              for    = "0m"
              labels = { severity = "warning", lane = "security" }
              annotations = {
                summary     = "Unusually high homelab vault fetch volume (>100/10m) for {{ $labels.user }}"
                description = "A burst of credential fetches for one user — possible runaway loop or exfiltration. Cross-check the op-log parent process and the Vault audit stream (namespace=vault,container=audit-tail) for reads of secret/data/workstation/claude-users/{{ $labels.user }}."
              }
            },
          ]
        }
      ]
    })
  }
}

resource "kubernetes_config_map" "grafana_loki_datasource" {
  metadata {
    name      = "grafana-loki-datasource"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      grafana_datasource = "1"
    }
  }
  data = {
    "loki-datasource.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name      = "Loki"
        type      = "loki"
        access    = "proxy"
        url       = "http://loki.monitoring.svc.cluster.local:3100"
        isDefault = false
      }]
    })
  }
}
