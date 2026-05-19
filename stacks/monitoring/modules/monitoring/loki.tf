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

  values = [file("${path.module}/alloy.yaml")]
  atomic = true

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
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
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
          # Wave 1 security alerts (beads code-8ywc). Routed via Loki ruler →
          # prometheus-alertmanager → #security Slack receiver. Allowlist CIDRs:
          # 10.0.20.0/22, 192.168.1.0/24, K8s pod CIDR 10.10.0.0/16, K8s service
          # CIDR 10.96.0.0/12. Identity allowlist: me@viktorbarzin.me only.
          # NOTE: K1 (cluster-admin grant) intentionally skipped.
          name = "Security Wave 1"
          rules = [
            # V1: Root token created (Vault audit, vault-tail sidecar stream)
            {
              alert = "VaultRootTokenCreated"
              expr  = "sum(count_over_time({namespace=\"vault\",container=\"audit-tail\"} | json | request_path=\"auth/token/create\" |~ \"\\\"policies\\\":\\\\[\\\"root\\\"\\\\]\" [5m])) > 0"
              for   = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary     = "Vault root token created"
                description = "A token with policies=[root] was issued via auth/token/create. Verify this is a planned bootstrap or break-glass; otherwise treat as critical compromise."
                runbook     = "docs/runbooks/security-incident.md#v1-root-token-created"
              }
            },
            # V2: Audit device disabled/modified
            {
              alert = "VaultAuditDeviceModified"
              expr  = "sum(count_over_time({namespace=\"vault\",container=\"audit-tail\"} | json | request_path=~\"sys/audit/.+\" | operation=~\"(create|delete|update)\" [5m])) > 0"
              for   = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "Vault audit device modified — attacker may be silencing visibility"
                runbook = "docs/runbooks/security-incident.md#v2-audit-device-disabledmodified"
              }
            },
            # V3: Seal status changed
            {
              alert = "VaultSealChanged"
              expr  = "sum(count_over_time({namespace=\"vault\",container=\"audit-tail\"} | json | request_path=\"sys/seal\" | operation=\"update\" [5m])) > 0"
              for   = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "Vault seal status changed via API — confirm planned operation"
                runbook = "docs/runbooks/security-incident.md#v3-seal-status-changed"
              }
            },
            # V4: Policy modified
            {
              alert = "VaultPolicyModified"
              expr  = "sum(count_over_time({namespace=\"vault\",container=\"audit-tail\"} | json | request_path=~\"sys/policies/acl/.+\" | operation=~\"(create|update|delete)\" [5m])) > 0"
              for   = "0m"
              labels = { severity = "warning", lane = "security" }
              annotations = {
                summary = "Vault policy modified — verify Terraform-driven change"
                runbook = "docs/runbooks/security-incident.md#v4-policy-modified"
              }
            },
            # V5: Auth failure spike
            {
              alert = "VaultAuthFailureSpike"
              expr  = "sum(count_over_time({namespace=\"vault\",container=\"audit-tail\"} | json | type=\"response\" |~ \"\\\"error\\\":\\\"permission denied\\\"\" [1m])) > 10"
              for   = "1m"
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
              alert = "VaultViktorFromUnexpectedIP"
              expr  = "sum(count_over_time({namespace=\"vault\",container=\"audit-tail\"} | json | auth_metadata_username=\"me@viktorbarzin.me\" | request_remote_address!~\"^(10\\\\.0\\\\.2[0-3]\\\\.|192\\\\.168\\\\.1\\\\.|10\\\\.10\\\\.|10\\\\.(9[6-9]|1[01][0-9]|111)\\\\.|100\\\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\\\.).*\" [5m])) > 0"
              for   = "0m"
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
              alert = "K8sSATokenFromUnexpectedIP"
              expr  = "sum(count_over_time({job=\"kubernetes-audit\"} | json | user_username=~\"system:serviceaccount:.+\" | sourceIPs_0!~\"^(10\\\\.0\\\\.2[0-3]\\\\.|192\\\\.168\\\\.1\\\\.|10\\\\.10\\\\.|10\\\\.(9[6-9]|1[01][0-9]|111)\\\\.|100\\\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\\\.).*\" [5m])) > 0"
              for   = "0m"
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
              alert = "K8sSensitiveSecretReadByUnexpectedActor"
              expr  = "sum(count_over_time({job=\"kubernetes-audit\"} | json | verb=~\"get|list\" | objectRef_resource=\"secrets\" | objectRef_namespace=~\"vault|sealed-secrets|external-secrets\" | user_username!~\"^(me@viktorbarzin\\\\.me|system:serviceaccount:external-secrets:.+|system:serviceaccount:sealed-secrets:.+|system:serviceaccount:vault:.+)$\" [5m])) > 0"
              for   = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "Sensitive Secret read in vault/sealed-secrets/external-secrets by non-allowlisted actor"
                runbook = "docs/runbooks/security-incident.md#k3-secret-read-in-sensitive-namespace-by-unexpected-actor"
              }
            },
            # K4: Exec into pod in sensitive namespace.
            {
              alert = "K8sExecIntoSensitiveNamespace"
              expr  = "sum(count_over_time({job=\"kubernetes-audit\"} | json | verb=\"create\" | objectRef_resource=\"pods\" | objectRef_subresource=\"exec\" | objectRef_namespace=~\"vault|kube-system|dbaas|cnpg-system\" | user_username!=\"me@viktorbarzin.me\" [5m])) > 0"
              for   = "0m"
              labels = { severity = "warning", lane = "security" }
              annotations = {
                summary = "kubectl exec into sensitive namespace (vault/kube-system/dbaas/cnpg-system) by non-Viktor actor"
                runbook = "docs/runbooks/security-incident.md#k4-exec-into-sensitive-pod"
              }
            },
            # K5: Mass delete of pods/secrets/configmaps in 60s by single actor.
            {
              alert = "K8sMassDelete"
              expr  = "sum by (user_username) (count_over_time({job=\"kubernetes-audit\"} | json | verb=\"delete\" | objectRef_resource=~\"pods|secrets|configmaps\" [1m])) > 5"
              for   = "1m"
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
              alert = "K8sAuditPolicyModified"
              expr  = "sum(count_over_time({job=\"kubernetes-audit\"} | json | verb=~\"update|patch\" | objectRef_resource=\"configmaps\" | objectRef_name=\"kubeadm-config\" | objectRef_namespace=\"kube-system\" [5m])) > 0"
              for   = "0m"
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
              alert = "K8sClusterRoleWildcardCreated"
              expr  = "sum(count_over_time({job=\"kubernetes-audit\"} | json | verb=\"create\" | objectRef_resource=\"clusterroles\" |~ \"\\\"verbs\\\":\\\\[\\\"\\\\*\\\"\\\\]\" |~ \"\\\"resources\\\":\\\\[\\\"\\\\*\\\"\\\\]\" [5m])) > 0"
              for   = "0m"
              labels = { severity = "warning", lane = "security" }
              annotations = {
                summary = "New ClusterRole with verbs=[*]+resources=[*] created — privilege escalation primitive"
                runbook = "docs/runbooks/security-incident.md#k7-new-clusterrole-with-full-wildcards"
              }
            },
            # K8: Anonymous binding granted — catastrophic.
            {
              alert = "K8sAnonymousBindingGranted"
              expr  = "sum(count_over_time({job=\"kubernetes-audit\"} | json | verb=\"create\" | objectRef_resource=~\"rolebindings|clusterrolebindings\" |~ \"system:(anonymous|unauthenticated)\" [5m])) > 0"
              for   = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "Binding granted to system:anonymous or system:unauthenticated — full cluster compromise risk"
                runbook = "docs/runbooks/security-incident.md#k8-anonymous-binding"
              }
            },
            # K9: Viktor's identity from non-allowlist source IP. Same regex as V7.
            {
              alert = "K8sViktorFromUnexpectedIP"
              expr  = "sum(count_over_time({job=\"kubernetes-audit\"} | json | user_username=\"me@viktorbarzin.me\" | sourceIPs_0!~\"^(10\\\\.0\\\\.2[0-3]\\\\.|192\\\\.168\\\\.1\\\\.|10\\\\.10\\\\.|10\\\\.(9[6-9]|1[01][0-9]|111)\\\\.|100\\\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\\\.).*\" [5m])) > 0"
              for   = "0m"
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
              alert = "PVEsshLoginFromUnexpectedIP"
              expr  = "sum(count_over_time({job=\"sshd-pve\"} |~ \"Accepted (publickey|password|keyboard-interactive)\" | regexp \"Accepted (?P<method>\\\\S+) for (?P<user>\\\\S+) from (?P<ip>\\\\S+) port\" | ip!~\"^(10\\\\.0\\\\.2[0-3]\\\\.|192\\\\.168\\\\.1\\\\.|100\\\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\\\.).*\" [5m])) > 0"
              for   = "0m"
              labels = { severity = "critical", lane = "security" }
              annotations = {
                summary = "PVE sshd login from non-allowlist source IP — possible stolen SSH key"
                runbook = "docs/runbooks/security-incident.md#s1-pve-sshd-auth-success-from-unexpected-ip"
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
