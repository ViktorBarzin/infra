locals {
  # Init command for wait-for-lapi-and-register (see the header comment).
  crowdsec_register_command = [
    "sh",
    "-c",
    join("; ", [
      "until nc \"$LAPI_HOST\" \"$LAPI_PORT\" -z; do echo waiting for lapi to start; sleep 5; done",
      "ln -sfn /staging/etc/crowdsec /etc/crowdsec",
      "if [ -s /tmp_config/local_api_credentials.yaml ]; then echo \"LAPI credentials already present (pod restart, e.g. after node reboot) - skipping cscli lapi register\"; else cscli lapi register --machine \"$USERNAME\" -u \"$LAPI_URL\" --token \"$REGISTRATION_TOKEN\" && cp /etc/crowdsec/local_api_credentials.yaml /tmp_config/local_api_credentials.yaml; fi",
    ]),
  ]
}


# =============================================================================
# CrowdSec agent — idempotent LAPI registration (survives node reboots)
# =============================================================================
# The upstream crowdsec chart (verified identical through 0.24.0) hardcodes an
# agent init container that ALWAYS runs `cscli lapi register`. When a node
# reboots, kubelet restarts the SAME DaemonSet pod, the init re-runs, and LAPI
# returns 403 "user '<pod-name>' already exist" — the agent then never starts
# (seen 2026-07-12 after kured rebooted k8s-node4: DS 4/5, pod wedged in
# Init:Error until manual `cscli machines delete` + pod recreate).
#
# The credentials the original registration produced are still in the pod's
# /tmp_config emptyDir (emptyDir contents live on node disk and survive node
# reboots for as long as the pod object exists), so the fix is simply: skip
# registration when credentials are already present.
#
# The chart offers no values knob for this script, so we patch it at admission
# — same approach as the ndots dns_config and dependency-init mutations.
# CHART-VERSION-COUPLED: on a crowdsec chart bump, re-diff the upstream init
# command in templates/agent-daemonSet.yaml against the script below
# (chart pin: stacks/crowdsec/modules/crowdsec/main.tf).
resource "kubectl_manifest" "crowdsec_agent_idempotent_register" {
  yaml_body = templatefile("${path.module}/policies/crowdsec-agent-idempotent-register.yaml", { command = jsonencode(local.crowdsec_register_command) })

  # Kind changed from the kyverno.io ClusterPolicy types: create the CEL
  # policy before deleting the old one, so admission is never uncovered.
  lifecycle {
    create_before_destroy = true
  }
}

# =============================================================================
# CrowdSec register init container — memory limit
# =============================================================================
# The chart hardcodes `limits.memory: 50Mi` on wait-for-lapi-and-register (agent
# DaemonSet and appsec Deployment, chart 0.24.2) with no values knob. The
# container runs `cscli lapi register`, and cscli is a 110 MB binary, so at 50Mi
# the cgroup keeps evicting the binary's own pages and reading them back. On
# 2026-10-13 a new agent and a new appsec pod sat in Init:0/1 for over 45
# minutes, process in D state on folio_wait_bit_common, memory.events max
# 2.78M, ~100 GB of file refaults. Nothing errors, so the rollout just hangs
# until the Helm wait times out and leaves the release in pending-upgrade.
# CHART-VERSION-COUPLED like the policy above: re-check the init container's
# resources on a chart bump.
resource "kubectl_manifest" "crowdsec_register_init_memory" {
  yaml_body = templatefile("${path.module}/policies/crowdsec-register-init-memory.yaml", { memory_limit = "256Mi" })
}
