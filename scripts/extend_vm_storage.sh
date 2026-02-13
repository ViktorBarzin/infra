#!/usr/bin/env bash

# Extend disk storage on a Kubernetes node VM.
# Drains the node, shuts down the VM, resizes the disk in Proxmox,
# boots the VM, expands the filesystem, and uncordons the node.
#
# Usage: ./scripts/extend_vm_storage.sh <node-name> <size-increment>
# Example: ./scripts/extend_vm_storage.sh k8s-node2 +64G

# --- Constants ---
PROXMOX_HOST="root@192.168.1.127"
VM_SSH_USER="wizard"
KUBECTL="kubectl --kubeconfig $(pwd)/config"
SHUTDOWN_TIMEOUT=300
SSH_WAIT_TIMEOUT=300
POLL_INTERVAL=5

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# --- Node-to-VMID mapping ---
declare -A NODE_VMID=(
    [k8s-master]=200
    [k8s-node1]=201
    [k8s-node2]=202
    [k8s-node3]=203
    [k8s-node4]=204
)

# --- Cleanup trap ---
DRAINED_NODE=""
cleanup() {
    if [[ -n "$DRAINED_NODE" ]]; then
        echo ""
        error "Script exited unexpectedly!"
        warn "The node '$DRAINED_NODE' may still be cordoned/drained."
        warn "Recovery steps:"
        warn "  1. Check VM status: ssh $PROXMOX_HOST 'qm status ${NODE_VMID[$DRAINED_NODE]}'"
        warn "  2. Start VM if stopped: ssh $PROXMOX_HOST 'qm start ${NODE_VMID[$DRAINED_NODE]}'"
        warn "  3. Uncordon node: $KUBECTL uncordon $DRAINED_NODE"
    fi
}
trap cleanup EXIT

# --- Input validation ---
usage() {
    echo "Usage: $0 <node-name> <size-increment>"
    echo ""
    echo "Arguments:"
    echo "  node-name       One of: ${!NODE_VMID[*]}"
    echo "  size-increment  Disk size increase, e.g. +64G, +128G"
    echo ""
    echo "Example:"
    echo "  $0 k8s-node2 +64G"
    exit 1
}

if [[ $# -ne 2 ]]; then
    usage
fi

NODE_NAME="$1"
SIZE_INCREMENT="$2"

if [[ -z "${NODE_VMID[$NODE_NAME]+x}" ]]; then
    error "Unknown node: '$NODE_NAME'"
    echo "Valid nodes: ${!NODE_VMID[*]}"
    exit 1
fi

if [[ ! "$SIZE_INCREMENT" =~ ^\+[0-9]+G$ ]]; then
    error "Invalid size increment: '$SIZE_INCREMENT'"
    echo "Must match pattern +<number>G, e.g. +64G"
    exit 1
fi

VMID="${NODE_VMID[$NODE_NAME]}"

# --- Resolve node IP via kubectl ---
info "Resolving IP for node '$NODE_NAME'..."
NODE_IP=$($KUBECTL get node "$NODE_NAME" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
if [[ -z "$NODE_IP" ]]; then
    error "Could not resolve IP for node '$NODE_NAME'. Is the cluster reachable?"
    exit 1
fi
ok "Node IP: $NODE_IP"

# --- Query current disk size ---
info "Querying current disk size for VM $VMID..."
SCSI0_LINE=$(ssh "$PROXMOX_HOST" "qm config $VMID" 2>/dev/null | grep '^scsi0:')
if [[ -z "$SCSI0_LINE" ]]; then
    error "Could not read scsi0 config for VM $VMID."
    exit 1
fi
# Extract size value, e.g. "size=64G" from the config line
CURRENT_SIZE=$(echo "$SCSI0_LINE" | sed -n 's/.*size=\([0-9]*G\).*/\1/p')
if [[ -z "$CURRENT_SIZE" ]]; then
    error "Could not parse current disk size from: $SCSI0_LINE"
    exit 1
fi
CURRENT_SIZE_NUM=${CURRENT_SIZE%G}
INCREMENT_NUM=${SIZE_INCREMENT//[+G]/}
NEW_SIZE_NUM=$((CURRENT_SIZE_NUM + INCREMENT_NUM))
ok "Current disk size: ${CURRENT_SIZE_NUM}G → New size: ${NEW_SIZE_NUM}G (${SIZE_INCREMENT})"

if [[ $NEW_SIZE_NUM -le $CURRENT_SIZE_NUM ]]; then
    error "New size (${NEW_SIZE_NUM}G) must be greater than current size (${CURRENT_SIZE_NUM}G)."
    exit 1
fi

# --- Confirmation ---
echo ""
echo "========================================="
echo "  Extend VM Storage"
echo "========================================="
echo "  Node:       $NODE_NAME"
echo "  VMID:       $VMID"
echo "  Node IP:    $NODE_IP"
echo "  Current:    ${CURRENT_SIZE_NUM}G"
echo "  Increment:  $SIZE_INCREMENT"
echo "  New size:   ${NEW_SIZE_NUM}G"
echo "  Proxmox:    $PROXMOX_HOST"
echo "========================================="
echo ""
echo "This will:"
echo "  1. Drain the node (evict pods)"
echo "  2. Shut down the VM"
echo "  3. Resize disk (scsi0) from ${CURRENT_SIZE_NUM}G to ${NEW_SIZE_NUM}G"
echo "  4. Start the VM"
echo "  5. Expand the filesystem inside the guest"
echo "  6. Uncordon the node"
echo ""
read -rp "Proceed? [y/N] " confirm
if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo "Aborted."
    exit 0
fi

# --- Step 1: Drain node ---
info "Step 1/7: Draining node '$NODE_NAME'..."
DRAINED_NODE="$NODE_NAME"
if ! $KUBECTL drain "$NODE_NAME" --ignore-daemonsets --delete-emptydir-data --timeout=120s; then
    error "Failed to drain node '$NODE_NAME'."
    exit 1
fi
ok "Node drained."

# --- Step 2: Shutdown VM ---
info "Step 2/7: Shutting down VM $VMID..."
if ! ssh "$PROXMOX_HOST" "qm shutdown $VMID"; then
    error "Failed to send shutdown command to VM $VMID."
    exit 1
fi

info "Waiting for VM to stop (timeout: ${SHUTDOWN_TIMEOUT}s)..."
elapsed=0
while true; do
    status=$(ssh "$PROXMOX_HOST" "qm status $VMID" 2>/dev/null)
    if [[ "$status" == *"stopped"* ]]; then
        break
    fi
    if [[ $elapsed -ge $SHUTDOWN_TIMEOUT ]]; then
        error "VM $VMID did not stop within ${SHUTDOWN_TIMEOUT}s. Current status: $status"
        exit 1
    fi
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
done
ok "VM stopped."

# --- Step 3: Resize disk ---
info "Step 3/7: Resizing disk scsi0 by $SIZE_INCREMENT..."
if ! ssh "$PROXMOX_HOST" "qm resize $VMID scsi0 $SIZE_INCREMENT"; then
    error "Failed to resize disk on VM $VMID."
    exit 1
fi
ok "Disk resized."

# --- Step 4: Start VM ---
info "Step 4/7: Starting VM $VMID..."
if ! ssh "$PROXMOX_HOST" "qm start $VMID"; then
    error "Failed to start VM $VMID."
    exit 1
fi

info "Waiting for SSH to become available at $NODE_IP (timeout: ${SSH_WAIT_TIMEOUT}s)..."
elapsed=0
while true; do
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$VM_SSH_USER@$NODE_IP" "true" 2>/dev/null; then
        break
    fi
    if [[ $elapsed -ge $SSH_WAIT_TIMEOUT ]]; then
        error "SSH not reachable on $NODE_IP within ${SSH_WAIT_TIMEOUT}s."
        exit 1
    fi
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
done
ok "VM is up and SSH is reachable."

info "Waiting 10s for system stabilization..."
sleep 10

# --- Step 5: Expand filesystem ---
info "Step 5/7: Expanding filesystem inside the guest..."
ssh -o StrictHostKeyChecking=no "$VM_SSH_USER@$NODE_IP" 'bash -s' <<'REMOTE_SCRIPT'
set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

ROOT_DEV=$(findmnt -n -o SOURCE /)
ROOT_FSTYPE=$(findmnt -n -o FSTYPE /)
info "Root device: $ROOT_DEV"
info "Root filesystem: $ROOT_FSTYPE"

# Ensure growpart is available
if ! command -v growpart &>/dev/null; then
    info "Installing growpart (cloud-guest-utils)..."
    sudo apt-get update -qq && sudo apt-get install -y -qq cloud-guest-utils
fi

resize_fs() {
    local dev="$1"
    local fstype="$2"
    if [[ "$fstype" == "ext4" || "$fstype" == "ext3" || "$fstype" == "ext2" ]]; then
        info "Running resize2fs on $dev..."
        if ! sudo resize2fs "$dev"; then
            error "resize2fs failed on $dev"
            return 1
        fi
    elif [[ "$fstype" == "xfs" ]]; then
        info "Running xfs_growfs on /..."
        if ! sudo xfs_growfs /; then
            error "xfs_growfs failed"
            return 1
        fi
    else
        error "Unsupported filesystem type: $fstype"
        return 1
    fi
    return 0
}

# Check if root is on LVM (device-mapper)
if [[ "$ROOT_DEV" == /dev/mapper/* || "$ROOT_DEV" == /dev/dm-* ]]; then
    info "LVM layout detected."

    # Find the PV device
    PV_DEV=$(sudo pvs --noheadings -o pv_name | head -1 | tr -d ' ')
    if [[ -z "$PV_DEV" ]]; then
        error "Could not determine PV device."
        exit 1
    fi
    info "PV device: $PV_DEV"

    # Parse disk and partition number (handles /dev/sdaX and /dev/nvmeXnXpX)
    if [[ "$PV_DEV" =~ ^(/dev/nvme[0-9]+n[0-9]+)p([0-9]+)$ ]]; then
        DISK="${BASH_REMATCH[1]}"
        PARTNUM="${BASH_REMATCH[2]}"
    elif [[ "$PV_DEV" =~ ^(/dev/[a-z]+)([0-9]+)$ ]]; then
        DISK="${BASH_REMATCH[1]}"
        PARTNUM="${BASH_REMATCH[2]}"
    else
        error "Could not parse disk/partition from PV: $PV_DEV"
        exit 1
    fi
    info "Disk: $DISK, Partition: $PARTNUM"

    # Grow partition
    info "Growing partition $DISK partition $PARTNUM..."
    sudo growpart "$DISK" "$PARTNUM" || echo "(growpart: partition may already be at max size)"

    # Resize PV
    info "Resizing PV $PV_DEV..."
    if ! sudo pvresize "$PV_DEV"; then
        error "pvresize failed on $PV_DEV"
        exit 1
    fi

    # Resolve LV path if using /dev/dm-*
    if [[ "$ROOT_DEV" == /dev/dm-* ]]; then
        LV_PATH=$(sudo lvs --noheadings -o lv_path | head -1 | tr -d ' ')
    else
        LV_PATH="$ROOT_DEV"
    fi
    info "LV path: $LV_PATH"

    # Extend LV
    info "Extending LV $LV_PATH to use all free space..."
    if ! sudo lvextend -l +100%FREE "$LV_PATH"; then
        warn "lvextend reported no change (LV may already use all space)."
    fi

    # Resize filesystem
    resize_fs "$LV_PATH" "$ROOT_FSTYPE"
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
else
    info "Direct partition layout detected."

    # Parse disk and partition number
    if [[ "$ROOT_DEV" =~ ^(/dev/nvme[0-9]+n[0-9]+)p([0-9]+)$ ]]; then
        DISK="${BASH_REMATCH[1]}"
        PARTNUM="${BASH_REMATCH[2]}"
    elif [[ "$ROOT_DEV" =~ ^(/dev/[a-z]+)([0-9]+)$ ]]; then
        DISK="${BASH_REMATCH[1]}"
        PARTNUM="${BASH_REMATCH[2]}"
    else
        error "Could not parse disk/partition from: $ROOT_DEV"
        exit 1
    fi
    info "Disk: $DISK, Partition: $PARTNUM"

    # Grow partition
    info "Growing partition $DISK partition $PARTNUM..."
    sudo growpart "$DISK" "$PARTNUM" || echo "(growpart: partition may already be at max size)"

    # Resize filesystem
    resize_fs "$ROOT_DEV" "$ROOT_FSTYPE"
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
fi

ok "Filesystem expansion complete."
df -h /
REMOTE_SCRIPT

if [[ $? -ne 0 ]]; then
    error "Filesystem expansion failed on the guest."
    exit 1
fi
ok "Filesystem expanded."

# --- Step 6: Uncordon node ---
info "Step 6/7: Uncordoning node '$NODE_NAME'..."
if ! $KUBECTL uncordon "$NODE_NAME"; then
    error "Failed to uncordon node '$NODE_NAME'."
    exit 1
fi
DRAINED_NODE=""
ok "Node uncordoned."

# --- Step 7: Verify ---
info "Step 7/7: Verification"
echo ""
info "Disk usage on $NODE_NAME:"
ssh -o StrictHostKeyChecking=no "$VM_SSH_USER@$NODE_IP" "df -h /"
echo ""
info "Node status:"
$KUBECTL get node "$NODE_NAME"
echo ""
ok "Storage extension complete for $NODE_NAME."
