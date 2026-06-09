#!/usr/bin/env bash
# lvm-pvc-snapshot — LVM thin snapshot management for Proxmox CSI PVCs
# Deploy to PVE host at /usr/local/bin/lvm-pvc-snapshot
set -euo pipefail

# --- Configuration ---
VG="pve"
THINPOOL="data"
SNAP_SUFFIX_FORMAT="%Y%m%d_%H%M"
RETENTION_DAYS=7
MIN_FREE_PCT=10
PUSHGATEWAY="${LVM_SNAP_PUSHGATEWAY:-http://10.0.20.100:30091}"
PUSHGATEWAY_JOB="lvm-pvc-snapshot"
LOCKFILE="/run/lvm-pvc-snapshot.lock"
KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
export KUBECONFIG

# Namespaces to exclude from snapshots (high-churn, have app-level dumps)
# These PVCs cause significant CoW write amplification (~36% overhead)
EXCLUDE_NAMESPACES="${LVM_SNAP_EXCLUDE_NS:-dbaas,monitoring}"

# --- Logging ---
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn() { log "WARN: $*" >&2; }
die()  { log "FATAL: $*" >&2; exit 1; }

# --- Helpers ---

get_thinpool_free_pct() {
    local data_pct
    data_pct=$(lvs --noheadings --nosuffix -o data_percent "${VG}/${THINPOOL}" 2>/dev/null | tr -d ' ')
    echo "scale=2; 100 - ${data_pct}" | bc
}

build_exclude_lv_list() {
    # Query K8s for PVs in excluded namespaces, extract their LV names
    if [[ -z "${EXCLUDE_NAMESPACES}" ]] || ! command -v kubectl &>/dev/null; then
        return
    fi
    kubectl get pv -o json 2>/dev/null | jq -r --arg ns "${EXCLUDE_NAMESPACES}" '
        ($ns | split(",")) as $excl |
        .items[] |
        select(.spec.csi.driver == "csi.proxmox.sinextra.dev") |
        select(.spec.claimRef.namespace as $n | $excl | index($n)) |
        .spec.csi.volumeHandle | split("/") | last
    ' 2>/dev/null || true
}

discover_pvc_lvs() {
    # List thin LVs matching PVC pattern, excluding snapshots, pre-restore backups,
    # and LVs belonging to excluded namespaces (high-churn databases/metrics)
    local all_lvs exclude_lvs
    all_lvs=$(lvs --noheadings -o lv_name,pool_lv "${VG}" 2>/dev/null \
        | awk -v pool="${THINPOOL}" '$2 == pool { print $1 }' \
        | grep -E '^vm-[0-9]+-pvc-' \
        | grep -v '_snap_' \
        | grep -v '_pre_restore_')

    exclude_lvs=$(build_exclude_lv_list)

    if [[ -n "${exclude_lvs}" ]]; then
        # Filter out excluded LVs
        local exclude_pattern
        exclude_pattern=$(echo "${exclude_lvs}" | paste -sd'|' -)
        echo "${all_lvs}" | grep -vE "(${exclude_pattern})" || true
    else
        echo "${all_lvs}"
    fi
}

list_snapshots() {
    lvs --noheadings -o lv_name,pool_lv "${VG}" 2>/dev/null \
        | awk -v pool="${THINPOOL}" '$2 == pool { print $1 }' \
        | grep '_snap_' || true
}

parse_snap_timestamp() {
    # Extract YYYYMMDD_HHMM from snapshot name, convert to epoch
    local snap_name="$1"
    local ts_str
    ts_str=$(echo "${snap_name}" | grep -oE '[0-9]{8}_[0-9]{4}$')
    if [[ -z "${ts_str}" ]]; then
        echo "0"
        return
    fi
    local ymd="${ts_str:0:8}"
    local hm="${ts_str:9:4}"
    date -d "${ymd:0:4}-${ymd:4:2}-${ymd:6:2} ${hm:0:2}:${hm:2:2}" +%s 2>/dev/null || echo "0"
}

get_original_lv_from_snap() {
    # vm-200-pvc-abc_snap_20260403_1200 -> vm-200-pvc-abc
    echo "$1" | sed 's/_snap_[0-9]\{8\}_[0-9]\{4\}$//'
}

push_metrics() {
    local status="$1" created="$2" failed="$3" pruned="$4"
    local free_pct
    free_pct=$(get_thinpool_free_pct)

    cat <<METRICS | curl -sf --connect-timeout 5 --max-time 10 --data-binary @- \
        "${PUSHGATEWAY}/metrics/job/${PUSHGATEWAY_JOB}" 2>/dev/null || warn "Failed to push metrics to Pushgateway"
# HELP lvm_snapshot_last_run_timestamp Unix timestamp of last snapshot run
# TYPE lvm_snapshot_last_run_timestamp gauge
lvm_snapshot_last_run_timestamp $(date +%s)
# HELP lvm_snapshot_last_status Exit status (0=success, 1=partial failure, 2=aborted)
# TYPE lvm_snapshot_last_status gauge
lvm_snapshot_last_status ${status}
# HELP lvm_snapshot_created_total Number of snapshots created in last run
# TYPE lvm_snapshot_created_total gauge
lvm_snapshot_created_total ${created}
# HELP lvm_snapshot_failed_total Number of snapshot failures in last run
# TYPE lvm_snapshot_failed_total gauge
lvm_snapshot_failed_total ${failed}
# HELP lvm_snapshot_pruned_total Number of snapshots pruned in last run
# TYPE lvm_snapshot_pruned_total gauge
lvm_snapshot_pruned_total ${pruned}
# HELP lvm_snapshot_thinpool_free_pct Thin pool free percentage
# TYPE lvm_snapshot_thinpool_free_pct gauge
lvm_snapshot_thinpool_free_pct ${free_pct}
METRICS
}

# --- Subcommands ---

cmd_snapshot() {
    log "Starting PVC LVM thin snapshot run"

    # Check thin pool free space
    local free_pct
    free_pct=$(get_thinpool_free_pct)
    log "Thin pool free space: ${free_pct}%"
    if (( $(echo "${free_pct} < ${MIN_FREE_PCT}" | bc -l) )); then
        warn "Thin pool has only ${free_pct}% free (minimum: ${MIN_FREE_PCT}%). Aborting."
        push_metrics 2 0 0 0
        exit 1
    fi

    # Discover PVC LVs
    local lvs_list
    lvs_list=$(discover_pvc_lvs)
    if [[ -z "${lvs_list}" ]]; then
        warn "No PVC LVs found matching pattern"
        push_metrics 2 0 0 0
        exit 1
    fi

    local count=0 failed=0 total
    total=$(echo "${lvs_list}" | wc -l | tr -d ' ')
    local snap_ts
    snap_ts=$(date +"${SNAP_SUFFIX_FORMAT}")

    log "Found ${total} PVC LVs to snapshot"

    while IFS= read -r lv; do
        local snap_name="${lv}_snap_${snap_ts}"
        if lvcreate -s -kn -n "${snap_name}" "${VG}/${lv}" >/dev/null 2>&1; then
            log "  Created: ${snap_name}"
            count=$((count + 1))
        else
            warn "  Failed to create snapshot for ${lv}"
            failed=$((failed + 1))
        fi
    done <<< "${lvs_list}"

    log "Snapshot run complete: ${count} created, ${failed} failed out of ${total}"

    # Auto-prune
    log "Running auto-prune..."
    local pruned
    pruned=$(cmd_prune_count)

    # Determine status
    local status=0
    if (( failed > 0 && count > 0 )); then
        status=1  # partial
    elif (( failed > 0 && count == 0 )); then
        status=2  # all failed
    fi

    push_metrics "${status}" "${count}" "${failed}" "${pruned}"
    log "Done"
}

cmd_list() {
    printf "%-45s %-50s %8s %8s\n" "ORIGINAL LV" "SNAPSHOT" "AGE" "DATA%"
    printf "%-45s %-50s %8s %8s\n" "-----------" "--------" "---" "-----"

    local now
    now=$(date +%s)

    local snap_lines
    snap_lines=$(lvs --noheadings --nosuffix -o lv_name,lv_size,data_percent "${VG}" 2>/dev/null \
        | grep -E '_snap_|_pre_restore_' || true)

    if [[ -z "${snap_lines}" ]]; then
        echo "(no snapshots found)"
        return
    fi

    echo "${snap_lines}" | while read -r name size data_pct; do
            local original age_str ts epoch
            if [[ "${name}" == *"_pre_restore_"* ]]; then
                original=$(echo "${name}" | sed 's/_pre_restore_[0-9]\{8\}_[0-9]\{4\}$//')
                ts=$(echo "${name}" | grep -oE '[0-9]{8}_[0-9]{4}$')
            else
                original=$(get_original_lv_from_snap "${name}")
                ts=$(echo "${name}" | grep -oE '[0-9]{8}_[0-9]{4}$')
            fi
            epoch=$(parse_snap_timestamp "${name}")
            if (( epoch > 0 )); then
                local age_s=$(( now - epoch ))
                local days=$(( age_s / 86400 ))
                local hours=$(( (age_s % 86400) / 3600 ))
                age_str="${days}d${hours}h"
            else
                age_str="unknown"
            fi
            printf "%-45s %-50s %8s %7s%%\n" "${original}" "${name}" "${age_str}" "${data_pct}"
        done
}

cmd_prune() {
    local pruned
    pruned=$(cmd_prune_count)
    log "Pruned ${pruned} expired snapshots"
}

cmd_prune_count() {
    # NOTE: stdout of this function is captured by callers (`pruned=$(cmd_prune_count)`),
    # so all log/warn output must go to stderr — the only thing on stdout is the count.
    local now cutoff pruned=0
    now=$(date +%s)
    cutoff=$(( now - RETENTION_DAYS * 86400 ))

    local snaps
    snaps=$(lvs --noheadings -o lv_name,pool_lv "${VG}" 2>/dev/null \
        | awk -v pool="${THINPOOL}" '$2 == pool { print $1 }' \
        | grep -E '_snap_|_pre_restore_' || true)

    if [[ -z "${snaps}" ]]; then
        echo "0"
        return
    fi

    while IFS= read -r snap; do
        local epoch
        epoch=$(parse_snap_timestamp "${snap}")
        if (( epoch > 0 && epoch < cutoff )); then
            if lvremove -f "${VG}/${snap}" >/dev/null 2>&1; then
                log "  Pruned: ${snap}" >&2
                pruned=$((pruned + 1))
            else
                warn "  Failed to prune: ${snap}"
            fi
        fi
    done <<< "${snaps}"

    echo "${pruned}"
}

cmd_restore() {
    local pvc_lv="${1:-}" snapshot_lv="${2:-}"

    if [[ -z "${pvc_lv}" || -z "${snapshot_lv}" ]]; then
        die "Usage: $0 restore <pvc-lv-name> <snapshot-lv-name>"
    fi

    # Validate LVs exist
    if ! lvs "${VG}/${pvc_lv}" >/dev/null 2>&1; then
        die "PVC LV '${pvc_lv}' not found in VG '${VG}'"
    fi
    if ! lvs "${VG}/${snapshot_lv}" >/dev/null 2>&1; then
        die "Snapshot LV '${snapshot_lv}' not found in VG '${VG}'"
    fi

    # Discover K8s context
    log "Discovering Kubernetes context for LV '${pvc_lv}'..."

    local volume_handle="local-lvm:${pvc_lv}"
    local pv_info
    pv_info=$(kubectl get pv -o json 2>/dev/null | jq -r \
        --arg vh "${volume_handle}" \
        '.items[] | select(.spec.csi.volumeHandle == $vh) | "\(.metadata.name) \(.spec.claimRef.namespace) \(.spec.claimRef.name)"' \
    ) || die "Failed to query PVs (is kubectl configured?)"

    if [[ -z "${pv_info}" ]]; then
        die "No PV found with volumeHandle '${volume_handle}'"
    fi

    local pv_name pvc_ns pvc_name
    read -r pv_name pvc_ns pvc_name <<< "${pv_info}"
    log "Found: PV=${pv_name}, PVC=${pvc_ns}/${pvc_name}"

    # Find the workload (Deployment or StatefulSet) that uses this PVC
    local workload_type="" workload_name="" original_replicas=""

    # Check StatefulSets first (databases use these)
    local sts_info
    sts_info=$(kubectl get statefulset -n "${pvc_ns}" -o json 2>/dev/null | jq -r \
        --arg pvc "${pvc_name}" \
        '.items[] | select(
            (.spec.template.spec.volumes // [] | .[].persistentVolumeClaim.claimName == $pvc) or
            (.spec.volumeClaimTemplates // [] | .[].metadata.name as $vct |
                .spec.replicas as $r | range($r) | "\($vct)-\(.metadata.name)-\(.)" ) == $pvc
        ) | "\(.metadata.name) \(.spec.replicas)"' 2>/dev/null \
    ) || true

    # If not found via simple volume check, try matching VCT naming pattern
    if [[ -z "${sts_info}" ]]; then
        sts_info=$(kubectl get statefulset -n "${pvc_ns}" -o json 2>/dev/null | jq -r \
            --arg pvc "${pvc_name}" \
            '.items[] | .metadata.name as $sts | .spec.replicas as $r |
            select(.spec.volumeClaimTemplates != null) |
            .spec.volumeClaimTemplates[].metadata.name as $vct |
            [range($r)] | map("\($vct)-\($sts)-\(.)") |
            if any(. == $pvc) then "\($sts) \($r)" else empty end' 2>/dev/null \
        ) || true
    fi

    if [[ -n "${sts_info}" ]]; then
        read -r workload_name original_replicas <<< "${sts_info}"
        workload_type="statefulset"
    else
        # Check Deployments
        local deploy_info
        deploy_info=$(kubectl get deployment -n "${pvc_ns}" -o json 2>/dev/null | jq -r \
            --arg pvc "${pvc_name}" \
            '.items[] | select(
                .spec.template.spec.volumes // [] | .[].persistentVolumeClaim.claimName == $pvc
            ) | "\(.metadata.name) \(.spec.replicas)"' 2>/dev/null \
        ) || true

        if [[ -n "${deploy_info}" ]]; then
            read -r workload_name original_replicas <<< "${deploy_info}"
            workload_type="deployment"
        fi
    fi

    if [[ -z "${workload_type}" ]]; then
        warn "Could not auto-discover workload for PVC '${pvc_name}' in namespace '${pvc_ns}'."
        warn "You may need to scale down the pod manually."
        echo ""
        read -rp "Continue with LV swap anyway? (yes/no): " confirm
        [[ "${confirm}" == "yes" ]] || die "Aborted by user"
        workload_type="manual"
    fi

    # Dry-run output
    local backup_name="${pvc_lv}_pre_restore_$(date +"${SNAP_SUFFIX_FORMAT}")"
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    RESTORE DRY-RUN                         ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║ PVC:       ${pvc_ns}/${pvc_name}"
    echo "║ PV:        ${pv_name}"
    if [[ "${workload_type}" != "manual" ]]; then
        echo "║ Workload:  ${workload_type}/${workload_name} (replicas: ${original_replicas}→0→${original_replicas})"
    fi
    echo "║"
    echo "║ Actions:"
    if [[ "${workload_type}" != "manual" ]]; then
        echo "║   1. Scale ${workload_type}/${workload_name} to 0 replicas"
        echo "║   2. Wait for pod termination"
    fi
    echo "║   3. Rename ${pvc_lv} → ${backup_name}"
    echo "║   4. Rename ${snapshot_lv} → ${pvc_lv}"
    if [[ "${workload_type}" != "manual" ]]; then
        echo "║   5. Scale ${workload_type}/${workload_name} back to ${original_replicas} replicas"
    fi
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    # Interactive confirmation
    read -rp "Type 'yes' to proceed with restore: " confirm
    if [[ "${confirm}" != "yes" ]]; then
        die "Aborted by user"
    fi

    # Scale down
    if [[ "${workload_type}" != "manual" ]]; then
        log "Scaling ${workload_type}/${workload_name} to 0 replicas..."
        kubectl scale "${workload_type}/${workload_name}" -n "${pvc_ns}" --replicas=0

        log "Waiting for pod termination (timeout: 120s)..."
        kubectl wait --for=delete pod -l "app.kubernetes.io/name=${workload_name}" -n "${pvc_ns}" --timeout=120s 2>/dev/null || \
        kubectl wait --for=delete pod -l "app=${workload_name}" -n "${pvc_ns}" --timeout=120s 2>/dev/null || \
            warn "Timeout waiting for pods — continuing anyway (LV may still be in use)"
        sleep 5  # extra grace period for device detach
    fi

    # Verify LV is not active
    local lv_active
    lv_active=$(lvs --noheadings -o lv_active "${VG}/${pvc_lv}" 2>/dev/null | tr -d ' ')
    if [[ "${lv_active}" == "active" ]]; then
        warn "LV ${pvc_lv} is still active. Attempting to deactivate..."
        # Close any LUKS mapper on the LV before deactivation
        if dmsetup ls 2>/dev/null | grep -q "${pvc_lv}"; then
            log "Closing LUKS mapper for ${pvc_lv}..."
            cryptsetup luksClose "${pvc_lv}" 2>/dev/null || true
        fi
        lvchange -an "${VG}/${pvc_lv}" 2>/dev/null || warn "Could not deactivate — proceeding with caution"
    fi

    # LV swap
    log "Renaming ${pvc_lv} → ${backup_name}"
    lvrename "${VG}" "${pvc_lv}" "${backup_name}" || die "Failed to rename original LV"

    log "Renaming ${snapshot_lv} → ${pvc_lv}"
    lvrename "${VG}" "${snapshot_lv}" "${pvc_lv}" || die "Failed to rename snapshot LV"

    # Scale back up
    if [[ "${workload_type}" != "manual" ]]; then
        log "Scaling ${workload_type}/${workload_name} back to ${original_replicas} replicas..."
        kubectl scale "${workload_type}/${workload_name}" -n "${pvc_ns}" --replicas="${original_replicas}"

        log "Waiting for pod to become Ready (timeout: 300s)..."
        kubectl wait --for=condition=Ready pod -l "app.kubernetes.io/name=${workload_name}" -n "${pvc_ns}" --timeout=300s 2>/dev/null || \
        kubectl wait --for=condition=Ready pod -l "app=${workload_name}" -n "${pvc_ns}" --timeout=300s 2>/dev/null || \
            warn "Timeout waiting for pod Ready — check manually"
    fi

    echo ""
    log "Restore complete!"
    log "Old data preserved as: ${backup_name}"
    log "To delete old data after verification: lvremove -f ${VG}/${backup_name}"
}

# --- Main ---

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  snapshot              Create thin snapshots of all PVC LVs
  list                  List existing snapshots with age and data%
  prune                 Remove snapshots older than ${RETENTION_DAYS} days
  restore <lv> <snap>   Restore a PVC from a snapshot (interactive)

Environment:
  LVM_SNAP_PUSHGATEWAY  Pushgateway URL (default: ${PUSHGATEWAY})
  KUBECONFIG            Kubeconfig path (default: /root/.kube/config)
EOF
}

main() {
    local cmd="${1:-}"
    shift || true

    # Acquire lock (except for list which is read-only)
    if [[ "${cmd}" != "list" && "${cmd}" != "" && "${cmd}" != "help" && "${cmd}" != "--help" && "${cmd}" != "-h" ]]; then
        exec 200>"${LOCKFILE}"
        if ! flock -n 200; then
            die "Another instance is already running (lockfile: ${LOCKFILE})"
        fi
    fi

    case "${cmd}" in
        snapshot) cmd_snapshot ;;
        list)     cmd_list ;;
        prune)    cmd_prune ;;
        restore)  cmd_restore "$@" ;;
        help|--help|-h|"") usage ;;
        *) die "Unknown command: ${cmd}. Run '$0 help' for usage." ;;
    esac
}

main "$@"
