#!/usr/bin/env bash
# One-shot deployment of the forgejo pull path across every k8s node:
# systemd-resolved routing domain ~viktorbarzin.me -> Technitium, plus the
# (vestigial) containerd hosts.toml entry. Cloud-init only fires on VM
# provision, so existing nodes need this manual rollout.
#
# The routing domain is what actually makes pulls hairpin-proof: Technitium's
# split-horizon zone resolves forgejo.viktorbarzin.me (CNAME, auto-synced from
# ingresses) to the zone apex whose A record tracks the live Traefik LB IP —
# no hardcoded service IPs on nodes. The hosts.toml mirror alone CANNOT do
# this: Traefik 404s its bare-IP requests (no Host/SNI match) and the registry
# Bearer auth realm is the absolute public URL fetched outside the mirror
# (2026-06-10 tuya-bridge outage; see
# docs/post-mortems/2026-06-10-tuya-bridge-forgejo-pull-hairpin.md).
#
# What it does, per node:
#   1. drain (ignore-daemonsets, delete-emptydir-data)
#   2. ssh in: write /etc/systemd/resolved.conf.d/viktorbarzin.conf (routing
#      domain), neuter any public global-dns.conf to FallbackDNS-only, drop
#      legacy forgejo-internal-pin /etc/hosts lines, restart systemd-resolved,
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
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/viktorbarzin.conf <<'CONF'
# Route *.viktorbarzin.me to Technitium (split-horizon zone -> live Traefik LB),
# so kubelet image pulls of forgejo.viktorbarzin.me never traverse the public
# NAT-hairpin. Everything else uses the link DNS.
# Managed: setup-forgejo-containerd-mirror.sh / cloud_init.yaml
[Resolve]
DNS=10.0.20.201
Domains=~viktorbarzin.me
CONF
# Public servers in the global DNS= set would race the routing domain —
# demote any legacy global-dns.conf to emergency fallback only.
if [ -f /etc/systemd/resolved.conf.d/global-dns.conf ]; then
  cat > /etc/systemd/resolved.conf.d/global-dns.conf <<'CONF'
# Emergency fallback only (used when no link DNS is configured at all).
[Resolve]
FallbackDNS=8.8.8.8 1.1.1.1
CONF
fi
sed -i '/forgejo-internal-pin/d' /etc/hosts
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
