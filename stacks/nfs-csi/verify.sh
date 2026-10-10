# shellcheck shell=bash
# Verify checks for stacks/nfs-csi (docs/runbooks/verify-jobs.md).
# Full runs provision, use and delete a 1Gi volume on the verify-nfs class
# (same server and share as nfs-pve, reclaim Delete).
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="nfs-csi"
VERIFY_ALERTNAMES="^(CSIDriverCrashLoop|NFSMountFailures)$"

_csinode_all() {
  local nodes with
  nodes=$(kubectl get nodes --no-headers | wc -l)
  with=$(kubectl get csinode -o json | jq '[.items[] | select([.spec.drivers[].name] | index("nfs.csi.k8s.io"))] | length')
  echo "nodes=$nodes registered nfs.csi.k8s.io=$with"
  [ "$with" -eq "$nodes" ]
}

_smoke() {
  local pvc="verify-nfs-smoke-${VERIFY_JOB_NAME##*-}" pv
  kubectl delete pvc -n verify "$pvc" --ignore-not-found --wait=true >/dev/null 2>&1
  jq -n --arg n "$pvc" --argjson owner "$(_owner_json)" '{apiVersion:"v1",kind:"PersistentVolumeClaim",
    metadata:{name:$n,namespace:"verify",ownerReferences:$owner,labels:{"app.kubernetes.io/managed-by":"verify"}},
    spec:{accessModes:["ReadWriteMany"],storageClassName:"verify-nfs",resources:{requests:{storage:"1Gi"}}}}' | kubectl create -f - >/dev/null || return 1
  run_pod nfs-write docker.io/library/busybox:1.36 'echo verify-$(date +%s) > /data/probe && sync && cat /data/probe' pvc="$pvc" rm=1 timeout=600 || { echo "write pod failed"; return 1; }
  run_pod nfs-read docker.io/library/busybox:1.36 'grep -q verify- /data/probe && echo read back: $(cat /data/probe)' pvc="$pvc" rm=1 timeout=600 || { echo "read pod failed"; return 1; }
  pv=$(kubectl get pvc -n verify "$pvc" -o jsonpath='{.spec.volumeName}')
  kubectl delete pvc -n verify "$pvc" --wait=true --timeout=120s >/dev/null
  retry 120 5 bash -c "! kubectl get pv $pv >/dev/null 2>&1" >/dev/null || { echo "PV $pv was not deleted"; return 1; }
  echo "PVC $pvc provisioned ($pv), written, read on a second pod, deleted, PV removed"
}

verify_component() {
  check "controller converged" retry 300 10 workload_ready nfs-csi deployment/csi-nfs-controller
  check "node plugin converged on every node" retry 300 10 workload_ready nfs-csi daemonset/csi-nfs-node
  check "every node registers nfs.csi.k8s.io" _csinode_all
  check "kubelet volume stats still flow (NodeGetVolumeStats)" expect_prom 'count(kubelet_volume_stats_used_bytes)' -gt 80
  check "no flag or port-conflict errors in the last 15m" expect_no_log_errors nfs-csi app.kubernetes.io/name=csi-driver-nfs 'address already in use|unknown flag|flag provided but not defined'
  if [ "${VERIFY_QUICK:-0}" != 1 ]; then
    check "provision, write, read and delete a volume" _smoke
  fi
}
