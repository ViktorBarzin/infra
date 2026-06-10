#!/usr/bin/env bash
# One-shot deployment of the forgejo.viktorbarzin.me containerd hosts.toml
# entry + /etc/hosts pin across every k8s node. Cloud-init only fires on VM
# provision, so existing nodes need this manual rollout.
#
# The /etc/hosts pin (forgejo.viktorbarzin.me -> Traefik LB) is what actually
# makes pulls hairpin-proof: Traefik 404s the mirror's bare-IP requests (no
# Host/SNI match) and the registry's Bearer auth realm is the absolute public
# URL, so the hosts.toml mirror alone always degrades to the flaky public-IP
# hairpin (2026-06-10 tuya-bridge outage; see
# docs/post-mortems/2026-06-10-tuya-bridge-forgejo-pull-hairpin.md).
#
# What it does, per node:
#   1. drain (ignore-daemonsets, delete-emptydir-data)
#   2. ssh in: mkdir + write /etc/containerd/certs.d/forgejo.viktorbarzin.me/hosts.toml
#      + append the forgejo /etc/hosts pin
#   3. systemctl restart containerd
#   4. uncordon
#
# hosts.toml is documented as hot-reloaded but the post-2026-04-19
# containerd corruption playbook calls for an explicit restart so the
# config is unambiguously in effect. Running drain/uncordon around it
# avoids pulling against an in-flight containerd restart.
#
# Re-run is safe: writes are idempotent.

set -euo pipefail

CERTS_DIR=/etc/containerd/certs.d/forgejo.viktorbarzin.me
HOSTS_TOML='server = "https://forgejo.viktorbarzin.me"

[host."https://10.0.20.203"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
'

NODES=$(kubectl get nodes -o name | sed 's|^node/||')
if [[ -z "$NODES" ]]; then
  echo "ERROR: no nodes returned from kubectl get nodes" >&2
  exit 1
fi

for n in $NODES; do
  echo "=== $n ==="
  kubectl drain "$n" --ignore-daemonsets --delete-emptydir-data --force --grace-period=60

  ssh -o StrictHostKeyChecking=accept-new "wizard@$n" sudo bash <<EOF
set -euo pipefail
mkdir -p "$CERTS_DIR"
cat > "$CERTS_DIR/hosts.toml" <<'TOML'
$HOSTS_TOML
TOML
grep -q forgejo-internal-pin /etc/hosts || \
  echo '10.0.20.203 forgejo.viktorbarzin.me # forgejo-internal-pin (managed: setup-forgejo-containerd-mirror.sh)' >> /etc/hosts
systemctl restart containerd
EOF

  kubectl uncordon "$n"

  # Wait for the node to report Ready before moving to the next one.
  for i in {1..30}; do
    if kubectl get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True; then
      echo "    node Ready"
      break
    fi
    sleep 2
  done
done

echo "All nodes updated."
