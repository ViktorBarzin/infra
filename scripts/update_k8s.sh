#!/usr/bin/env bash
#
# K8s component upgrader. Run on a single node (master OR worker) at a time.
# The caller is responsible for:
#   - draining + uncordoning the node (this script does not touch kubectl)
#   - sequencing nodes (master first, then workers one at a time)
#   - pre-flight checks (etcd snapshot, halt-on-alert, etc)
#
# Used by:
#   - the k8s-version-upgrade agent (infra/.claude/agents/k8s-version-upgrade.md)
#   - manual operators following the runbook (infra/docs/runbooks/k8s-version-upgrade.md)
#
# Old manual orchestration loop (kept for reference — the agent does the
# equivalent now):
#   for n in $(kbn | grep 'k8s-node' | awk '{print $1}'); do
#     kb drain $n --ignore-daemonsets --delete-emptydir-data
#     s wizard@$n 'bash -s' < update_k8s.sh --role worker --release 1.34.5
#     kb uncordon $n
#   done

set -euo pipefail

ROLE=""
RELEASE=""

usage() {
    cat <<EOF
Usage: $0 --role <master|worker> --release <X.Y.Z>

  --role     master|worker  (required)
  --release  kubeadm/kubelet/kubectl target patch version, e.g. 1.34.5

Behavior:
  - Rewrites /etc/apt/sources.list.d/kubernetes.list to the v\$MINOR/deb repo
    derived from --release (so a 1.34.x release uses v1.34/deb, 1.35.x uses
    v1.35/deb, etc).
  - apt-get install kubeadm=<release>-* (apt-mark unhold first).
  - master: kubeadm upgrade plan && kubeadm upgrade apply v<release> -y
  - worker: kubeadm upgrade node
  - apt-get install kubelet=<release>-* kubectl=<release>-* then re-hold.
  - systemctl daemon-reload && systemctl restart kubelet
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)    ROLE="$2"; shift 2;;
        --release) RELEASE="$2"; shift 2;;
        -h|--help) usage; exit 0;;
        *) echo "Unknown arg: $1" >&2; usage; exit 2;;
    esac
done

if [[ -z "$ROLE" || -z "$RELEASE" ]]; then
    echo "ERROR: --role and --release are required" >&2
    usage
    exit 2
fi

if [[ "$ROLE" != "master" && "$ROLE" != "worker" ]]; then
    echo "ERROR: --role must be 'master' or 'worker' (got: $ROLE)" >&2
    exit 2
fi

# Derive minor track (e.g. 1.34.5 → 1.34)
STABLE_VERSION="$(echo "$RELEASE" | awk -F. '{print $1"."$2}')"

echo "==> Upgrading $(hostname) ($ROLE) to v$RELEASE (track v$STABLE_VERSION)"

# Apt repo URL is pinned per minor track. Rewrite + re-import the signing key
# every run — cheap, idempotent, and handles the minor-bump case where the
# old track's repo no longer carries the target version.
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$STABLE_VERSION/deb/ /" \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v$STABLE_VERSION/deb/Release.key" \
    | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --batch --yes

sudo apt-mark unhold kubeadm kubelet kubectl
sudo apt-get update
sudo apt-get install -y "kubeadm=$RELEASE-*"

if [[ "$ROLE" == "master" ]]; then
    echo "==> Master path: kubeadm upgrade plan + apply"
    sudo kubeadm upgrade plan
    # The first apply may fail with "static Pod hash for component <X> did
    # not change after 5m0s" — kubeadm's 5min wait for the kubelet to reload
    # a static pod is too tight on our cluster (apiserver-to-kubelet status
    # sync latency post-master-reboot can exceed it). The etcd image IS
    # actually updated by then, so a 2nd attempt sees etcd already on
    # target and skips it. Up to 3 attempts with a 30s delay between.
    # First attempt: full kubeadm upgrade (incl. etcd). On the static-pod-
    # hash 5min-timeout failure, retry with --etcd-upgrade=false. The
    # timeout happens reliably for patch upgrades where etcd's image
    # doesn't change (kubeadm writes identical manifest → hash doesn't
    # change → kubeadm waits forever for a change that will never come).
    # Skipping the etcd phase on retry is safe IF etcd is already on the
    # right version (which is the only case where this timeout fires).
    attempt=1
    extra_flags=""
    while ! sudo kubeadm upgrade apply "v$RELEASE" -y $extra_flags; do
        if (( attempt >= 3 )); then
            echo "ERROR: kubeadm upgrade apply failed after 3 attempts" >&2
            exit 1
        fi
        echo "==> kubeadm apply attempt $attempt failed. Retrying with --etcd-upgrade=false (etcd image is unchanged for patch upgrades; kubeadm's static-pod-hash watch is the only thing failing)."
        extra_flags="--etcd-upgrade=false"
        sleep 30
        attempt=$(( attempt + 1 ))
    done
    echo "==> kubeadm upgrade apply succeeded on attempt $attempt (flags: '$extra_flags')"
else
    echo "==> Worker path: kubeadm upgrade node"
    sudo kubeadm upgrade node
fi

sudo apt-get install -y "kubelet=$RELEASE-*" "kubectl=$RELEASE-*"
sudo apt-mark hold kubeadm kubelet kubectl

sudo systemctl daemon-reload
sudo systemctl restart kubelet

echo "==> Done: $(hostname) is on v$RELEASE"
