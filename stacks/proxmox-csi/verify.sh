# shellcheck shell=bash
# Verify checks for stacks/proxmox-csi (docs/runbooks/verify-jobs.md).
# Full runs provision a 1Gi LV on the verify-proxmox-lvm class (same as
# proxmox-lvm, reclaim Delete), write it, expand it to 2Gi, read it back on a
# second pod, and delete it.
VERIFY_GROUP="chart"
VERIFY_NAMESPACES="proxmox-csi"
VERIFY_ALERTNAMES="^(CSIDriverCrashLoop|ProxmoxCSI.*|CSIGhost.*)$"

_csinode_counts() {
  local out
  out=$(kubectl get csinode -o json | jq -r '[.items[] | {n:.metadata.name, c:([.spec.drivers[] | select(.name=="csi.proxmox.sinextra.dev") | .allocatable.count][0])} | select(.c != null)]
    | "nodes with the driver: \(map("\(.n)=\(.c)") | join(" "))", (if length >= 5 and all(.c > 0) then 0 else 1 end)')
  head -1 <<<"$out"
  [ "$(tail -1 <<<"$out")" = 0 ]
}

_attachments_ok() {
  local out
  out=$(kubectl get volumeattachments -o json | jq -r '
    [.items[] | select(.spec.attacher=="csi.proxmox.sinextra.dev")] as $a
    | [$a[] | select(.status.attached != true and .metadata.deletionTimestamp == null) | .metadata.name] as $bad
    | "attachments=\($a|length) not attached=\($bad)", (if ($bad|length)==0 then 0 else 1 end)')
  head -1 <<<"$out"
  [ "$(tail -1 <<<"$out")" = 0 ]
}

_smoke() {
  local pvc="verify-pve-smoke-${VERIFY_JOB_NAME##*-}" pv
  kubectl delete pvc -n verify "$pvc" --ignore-not-found --wait=true >/dev/null 2>&1
  jq -n --arg n "$pvc" --argjson owner "$(_owner_json)" '{apiVersion:"v1",kind:"PersistentVolumeClaim",
    metadata:{name:$n,namespace:"verify",ownerReferences:$owner,labels:{"app.kubernetes.io/managed-by":"verify"}},
    spec:{accessModes:["ReadWriteOnce"],storageClassName:"verify-proxmox-lvm",resources:{requests:{storage:"1Gi"}}}}' | kubectl create -f - >/dev/null || return 1
  run_pod pve-write docker.io/library/busybox:1.36 'echo verify-$(date +%s) > /data/probe && sync && df -k /data | tail -1' pvc="$pvc" rm=1 timeout=600 || { echo "write pod failed"; return 1; }
  kubectl patch pvc -n verify "$pvc" --type merge -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}' >/dev/null || return 1
  retry 180 5 bash -c "[ \"\$(kubectl get pv \$(kubectl get pvc -n verify $pvc -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.capacity.storage}')\" = 2Gi ]" >/dev/null ||
    { echo "PV did not grow to 2Gi"; return 1; }
  # The filesystem grows on the next mount (offline node expansion).
  run_pod pve-read docker.io/library/busybox:1.36 'grep -q verify- /data/probe && kb=$(df -k /data | tail -1 | awk "{print \$2}") && echo "read back $(cat /data/probe), fs ${kb}k" && [ "$kb" -gt 1800000 ]' pvc="$pvc" rm=1 timeout=600 ||
    { echo "read/expand pod failed"; return 1; }
  pv=$(kubectl get pvc -n verify "$pvc" -o jsonpath='{.spec.volumeName}')
  kubectl delete pvc -n verify "$pvc" --wait=true --timeout=300s >/dev/null
  retry 600 5 bash -c "! kubectl get pv $pv >/dev/null 2>&1" >/dev/null || { echo "PV $pv was not deleted"; return 1; }
  echo "PVC $pvc provisioned ($pv), written, expanded to 2Gi, read on a second pod, deleted, LV removed"
}

verify_component() {
  check "controller converged" retry 300 10 workload_ready proxmox-csi deployment/proxmox-csi-plugin-controller
  check "node plugin converged" retry 300 10 workload_ready proxmox-csi daemonset/proxmox-csi-plugin-node
  check "worker nodes report attach capacity" _csinode_counts
  check "every Proxmox volume attachment is attached" _attachments_ok
  check "ghost-disk reconcile finds no ghosts" expect_prom 'max(csi_ghosts_detected)' -eq 0
  check "no RBAC or listing errors in controller logs (15m)" expect_no_log_errors proxmox-csi app.kubernetes.io/component=controller 'forbidden|failed to list|panic'
  if [ "${VERIFY_QUICK:-0}" != 1 ]; then
    check "provision, write, expand, read and delete a volume" _smoke
  fi
}
