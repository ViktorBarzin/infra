
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
  yaml_body = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = "crowdsec-agent-idempotent-register"
      annotations = {
        "policies.kyverno.io/title"       = "CrowdSec Agent Idempotent LAPI Registration"
        "policies.kyverno.io/description" = "Replaces the crowdsec-agent wait-for-lapi-and-register init command with a variant that skips `cscli lapi register` when /tmp_config/local_api_credentials.yaml already exists (pod restart after a node reboot). The upstream chart re-registers unconditionally and LAPI 403s 'user already exist', wedging the agent."
      }
    }
    spec = {
      rules = [
        {
          name = "idempotent-lapi-register"
          match = {
            any = [
              {
                resources = {
                  kinds      = ["Pod"]
                  namespaces = ["crowdsec"]
                  operations = ["CREATE"]
                  selector = {
                    matchLabels = {
                      "k8s-app" = "crowdsec"
                      type      = "agent"
                    }
                  }
                }
              }
            ]
          }
          mutate = {
            patchStrategicMerge = {
              spec = {
                initContainers = [
                  {
                    "(name)" = "wait-for-lapi-and-register"
                    command = [
                      "sh",
                      "-c",
                      join("; ", [
                        "until nc \"$LAPI_HOST\" \"$LAPI_PORT\" -z; do echo waiting for lapi to start; sleep 5; done",
                        "ln -sfn /staging/etc/crowdsec /etc/crowdsec",
                        "if [ -s /tmp_config/local_api_credentials.yaml ]; then echo \"LAPI credentials already present (pod restart, e.g. after node reboot) - skipping cscli lapi register\"; else cscli lapi register --machine \"$USERNAME\" -u \"$LAPI_URL\" --token \"$REGISTRATION_TOKEN\" && cp /etc/crowdsec/local_api_credentials.yaml /tmp_config/local_api_credentials.yaml; fi",
                      ])
                    ]
                  }
                ]
              }
            }
          }
        }
      ]
    }
  })
}
