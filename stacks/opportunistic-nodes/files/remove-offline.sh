#!/bin/bash
# Removes the Node object of an Opportunistic worker that is switched off
# (ADR-0045). Offline then means absent: no NotReady node, no Pending DaemonSet
# pods, nothing for alerts or agents to exclude by hand. When the machine boots,
# kubelet registers the node again with its label and taint, which kubeadm
# wrote into the kubelet flags (--node-labels, --register-with-taints).
#
# A node is removed only when kubelet has stopped renewing its Lease for
# SILENT_SECONDS and the node is not Ready. A NotReady node whose kubelet still
# heartbeats (CNI not up, for example) stays: a running kubelet does not
# register again, so it would be left without a Node object. The Tether stops
# kubelet after 10 minutes without Tang, before this removes the node, and
# starts it again when the tunnel returns.
set -euo pipefail

SILENT_SECONDS="${SILENT_SECONDS:-900}"
now=$(date +%s)

for ref in $(kubectl get nodes -l node-role.viktorbarzin.me/opportunistic=true -o name); do
  node="${ref#node/}"
  ready=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  if [ "$ready" = "True" ]; then
    echo "$node: Ready, kept"
    continue
  fi
  if ! renew=$(kubectl -n kube-node-lease get lease "$node" -o jsonpath='{.spec.renewTime}' 2>/dev/null) || [ -z "$renew" ]; then
    echo "$node: no Lease renewTime, kept"
    continue
  fi
  silent=$(( now - $(date -d "$renew" +%s) ))
  if [ "$silent" -lt "$SILENT_SECONDS" ]; then
    echo "$node: Ready=$ready, kubelet silent ${silent}s (< ${SILENT_SECONDS}s), kept"
    continue
  fi
  echo "$node: Ready=$ready, kubelet silent ${silent}s, removing"
  kubectl delete node "$node" --wait=false
done
