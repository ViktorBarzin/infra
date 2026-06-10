#!/usr/bin/env bash
# One-shot deployment of the (vestigial) forgejo containerd hosts.toml entry
# across every k8s node, plus cleanup of legacy node-side DNS customization.
# Cloud-init only fires on VM provision, so existing nodes need this manual
# rollout.
#
# Node DNS is intentionally STOCK: internal split-horizon for
# *.viktorbarzin.me happens at pfSense Unbound (domain override ->
# Technitium), whose split-horizon zone serves the live Traefik LB IP for
# every ingress host — nodes need no resolved drop-ins or /etc/hosts pins.
# The hosts.toml mirror alone CANNOT keep pulls internal: Traefik 404s its
# bare-IP requests (no Host/SNI match) and the registry Bearer auth realm is
# the absolute public URL fetched outside the mirror (2026-06-10 tuya-bridge
# outage; see docs/post-mortems/2026-06-10-tuya-bridge-forgejo-pull-hairpin.md).
#
# What it does, per node:
#   1. drain (ignore-daemonsets, delete-emptydir-data)
#   2. ssh in: remove legacy DNS customization (forgejo-internal-pin
#      /etc/hosts lines, viktorbarzin.conf / global-dns.conf resolved
#      drop-ins), restart systemd-resolved,
#      write /etc/containerd/certs.d/forgejo.viktorbarzin.me/hosts.toml
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
sed -i '/forgejo-internal-pin/d' /etc/hosts
rm -f /etc/systemd/resolved.conf.d/viktorbarzin.conf \
      /etc/systemd/resolved.conf.d/global-dns.conf
systemctl restart systemd-resolved
mkdir -p "$CERTS_DIR"
cat > "$CERTS_DIR/hosts.toml" <<'TOML'
$HOSTS_TOML
TOML
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
