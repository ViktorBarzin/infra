# Carry the homelab's kubelet tune in kubeadm's kube-system/kubelet-config
# ConfigMap, so a Kubernetes upgrade stops erasing it.
#
# WHY. `kubeadm upgrade node` (and `kubeadm join`) write each node's
# /var/lib/kubelet/config.yaml from this ConfigMap. The tune lived only in
# playbooks/k8s-node-tuning.yml, which writes the file directly, so every upgrade
# replaced it with kubeadm's defaults. It happened twice, with the same symptom
# both times: the v1.35.7 upgrade on 2026-07-26/27 and the v1.35.9 upgrade on
# 2026-09-27/28 both dropped `net.ipv4.ip_forward` from allowedUnsafeSysctls, and
# the UK VPN egress gateway (proxy/proxy-gw-1) could not start, the second time
# for three days, with 26 pods rejected as SysctlForbidden filling the namespace
# pod quota. docs/agents/known-issues.md named this ConfigMap as one of the two
# durable fixes; this is that fix, chosen by Viktor on 2026-10-01.
#
# WHAT IS MERGED. Exactly the keys the playbook declares (kubelet_declared plus
# kubelet_allowed_unsafe_sysctls), at the same values, so a node gets the same
# kubelet whichever of the two wrote its config last. allowedUnsafeSysctls is a
# union, as in the playbook. systemReserved, kubeReserved and evictionSoft stay
# absent on purpose (bead code-eu6l), as they are in the playbook.
#
# KEEP THE TWO IN STEP. If a value changes here it must change in the playbook
# too, and the reverse. A mismatch shows up as K8sNodeKubeletTuneDrift after the
# next upgrade, because scripts/check-node-kubelet-tune compares each kubelet's
# live config with the playbook.
#
# HAZARD. kubelet validates its config at start and exits on an invalid
# combination, with console-only recovery. Unlike the playbook, this one is
# applied by kubeadm to every node at every upgrade and join, so a bad value here
# reaches all of them. These values were checked against kubelet 1.35's
# validation by the playbook's own guards and have been live on all six nodes
# since 2026-10-01 03:09 UTC (kubelet restarted on each, /configz read back).
# Check any new key the same way before adding it.
#
# Writing the ConfigMap changes nothing on a running node. It takes effect the
# next time kubeadm writes a node's kubelet config.
locals {
  kubelet_tune = {
    serializeImagePulls             = true
    imageMaximumGCAge               = "168h"
    memorySwap                      = { swapBehavior = "LimitedSwap" }
    shutdownGracePeriod             = "0s"
    shutdownGracePeriodCriticalPods = "0s"
    shutdownGracePeriodByPodPriority = [
      { priority = 0, shutdownGracePeriodSeconds = 10 },
      { priority = 200000, shutdownGracePeriodSeconds = 10 },
      { priority = 400000, shutdownGracePeriodSeconds = 15 },
      { priority = 600000, shutdownGracePeriodSeconds = 15 },
      { priority = 800000, shutdownGracePeriodSeconds = 90 },
      { priority = 1000000, shutdownGracePeriodSeconds = 30 },
      { priority = 1200000, shutdownGracePeriodSeconds = 15 },
      { priority = 2000000000, shutdownGracePeriodSeconds = 15 },
      { priority = 2000001000, shutdownGracePeriodSeconds = 15 },
    ]
    imageGCHighThresholdPercent = 85
    imageGCLowThresholdPercent  = 80
    evictionHard = {
      "memory.available"   = "100Mi"
      "nodefs.available"   = "10%"
      "nodefs.inodesFree"  = "5%"
      "imagefs.available"  = "15%"
      "imagefs.inodesFree" = "5%"
    }
    allowedUnsafeSysctls = ["net.ipv4.ip_forward"]
  }
}

resource "null_resource" "kubelet_config_tuning" {
  connection {
    type        = "ssh"
    user        = "wizard"
    host        = var.k8s_master_host
    private_key = var.ssh_private_key
  }

  provisioner "remote-exec" {
    inline = [
      <<-SCRIPT
      set -u
      KC="sudo kubectl --kubeconfig /etc/kubernetes/admin.conf"

      for i in $(seq 1 60); do
        if curl -sk https://localhost:6443/livez 2>/dev/null | grep -q '^ok'; then break; fi
        sleep 2
      done

      echo '${base64encode(jsonencode(local.kubelet_tune))}' | base64 -d > /tmp/kubelet-tune.json
      if ! $KC -n kube-system get cm kubelet-config -o json > /tmp/kubelet-config-cm.json 2>/dev/null; then
        echo "WARN: could not read kube-system/kubelet-config; the kubelet tune will NOT survive the next upgrade. Re-apply the rbac stack."
        rm -f /tmp/kubelet-tune.json /tmp/kubelet-config-cm.json
        exit 0
      fi
      python3 -c "
import json, sys
import yaml

want = json.load(open('/tmp/kubelet-tune.json'))
cm = json.load(open('/tmp/kubelet-config-cm.json'))
cfg = yaml.safe_load(cm['data']['kubelet'])
before = json.dumps(cfg, sort_keys=True)
for key, value in want.items():
    if key == 'allowedUnsafeSysctls':
        cfg[key] = sorted(set(cfg.get(key) or []) | set(value))
    else:
        cfg[key] = value

# Exit 10 means nothing to do, so the shell below can tell it from a failure.
if json.dumps(cfg, sort_keys=True) == before:
    print('kubelet-config already carries the tune (no drift)')
    sys.exit(10)
cm['data']['kubelet'] = yaml.safe_dump(cfg, default_flow_style=False, sort_keys=False)
cm['metadata'].pop('managedFields', None)
json.dump(cm, open('/tmp/kubelet-config-cm-new.json', 'w'))
print('kubelet-config merged: ' + ', '.join(sorted(want)))
"
      RC=$?
      if [ "$RC" -eq 0 ]; then
        # replace carries resourceVersion, so a concurrent writer makes this fail
        # loudly instead of one write silently dropping the other.
        if $KC replace -f /tmp/kubelet-config-cm-new.json; then
          echo "kubelet-config updated: the kubelet tune now survives kubeadm upgrade and join"
        else
          echo "WARN: kubelet-config replace failed; re-apply the rbac stack"
        fi
      elif [ "$RC" -ne 10 ]; then
        echo "WARN: kubelet-config merge failed (exit $RC); the kubelet tune will NOT survive the next upgrade"
      fi
      rm -f /tmp/kubelet-tune.json /tmp/kubelet-config-cm.json /tmp/kubelet-config-cm-new.json
      SCRIPT
    ]
  }

  triggers = {
    tune = sha1(jsonencode(local.kubelet_tune))
  }
}
