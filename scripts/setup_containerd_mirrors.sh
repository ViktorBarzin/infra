#!/bin/bash
# setup_containerd_mirrors.sh
# Replaces deprecated wildcard registry mirror with per-registry hosts.toml config.
# Run on each K8s WORKER node: ssh wizard@<node-ip> 'sudo bash -s' < scripts/setup_containerd_mirrors.sh
# NOTE: Do NOT run on k8s-master (containerd 1.6.x has conflicts with config_path + mirrors coexisting)

set -euo pipefail

TIMESTAMP=$(date +%s)
CONFIG="/etc/containerd/config.toml"
CERTS_DIR="/etc/containerd/certs.d"

echo "=== Backing up containerd config ==="
cp "$CONFIG" "${CONFIG}.bak.${TIMESTAMP}"

echo "=== Removing deprecated mirror entries ==="
# Remove wildcard mirror and its endpoint
sed -i '/\[plugins\."io\.containerd\.grpc\.v1\.cri"\.registry\.mirrors\."\*"\]/d' "$CONFIG"
sed -i '/endpoint = \["http:\/\/10\.0\.20\.10:5000"\]/d' "$CONFIG"
# Remove any other per-registry mirror sections (e.g. docker.io) to avoid config_path conflict
sed -i '/\[plugins\."io\.containerd\.grpc\.v1\.cri"\.registry\.mirrors\."docker\.io"\]/d' "$CONFIG"
sed -i '/endpoint = \["https:\/\/registry-1\.docker\.io"\]/d' "$CONFIG"
# Remove the mirrors parent section header if it's now empty
sed -i '/\[plugins\."io\.containerd\.grpc\.v1\.cri"\.registry\.mirrors\]$/d' "$CONFIG"

echo "=== Setting config_path ==="
# Replace empty config_path with certs.d path
if grep -q 'config_path = ""' "$CONFIG"; then
  sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|' "$CONFIG"
elif grep -q 'config_path = "/etc/containerd/certs.d"' "$CONFIG"; then
  echo "config_path already set, skipping"
else
  # If config_path line doesn't exist at all, add it under [plugins."io.containerd.grpc.v1.cri".registry]
  sed -i '/\[plugins\."io\.containerd\.grpc\.v1\.cri"\.registry\]/a\      config_path = "/etc/containerd/certs.d"' "$CONFIG"
fi

echo "=== Creating hosts.toml files ==="

# docker.io (Docker Hub) — proxy first, upstream fallback
mkdir -p "$CERTS_DIR/docker.io"
printf 'server = "https://registry-1.docker.io"\n\n[host."http://10.0.20.10:5000"]\n  capabilities = ["pull", "resolve"]\n\n[host."https://registry-1.docker.io"]\n  capabilities = ["pull", "resolve"]\n' > "$CERTS_DIR/docker.io/hosts.toml"

# ghcr.io — proxy first, upstream fallback
mkdir -p "$CERTS_DIR/ghcr.io"
printf 'server = "https://ghcr.io"\n\n[host."http://10.0.20.10:5010"]\n  capabilities = ["pull", "resolve"]\n\n[host."https://ghcr.io"]\n  capabilities = ["pull", "resolve"]\n' > "$CERTS_DIR/ghcr.io/hosts.toml"

# Low-traffic registries (quay.io, registry.k8s.io, reg.kyverno.io) pull directly — no proxy.
# Remove stale hosts.toml from previous config if present.
rm -f "$CERTS_DIR/quay.io/hosts.toml" "$CERTS_DIR/registry.k8s.io/hosts.toml" "$CERTS_DIR/reg.kyverno.io/hosts.toml"
rmdir "$CERTS_DIR/quay.io" "$CERTS_DIR/registry.k8s.io" "$CERTS_DIR/reg.kyverno.io" 2>/dev/null || true

# No containerd restart needed — hosts.toml is re-read on each pull

echo "=== Done ==="
