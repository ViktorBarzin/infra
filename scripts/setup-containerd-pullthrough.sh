#!/usr/bin/env bash
set -euo pipefail

############################################
# CONFIGURATION
############################################

# Internal pull-through registry endpoint
# Examples:
#   http://registry.internal:5000
#   https://registry.internal
INTERNAL_REGISTRY="http://10.0.20.10:5002"

# Path where containerd reads registry configs
CERTS_DIR="/etc/containerd/certs.d"

# Optional: path to CA file if INTERNAL_REGISTRY uses HTTPS with custom CA
# Leave empty if not needed
INTERNAL_CA_PATH=""

# Restart containerd at the end
RESTART_CONTAINERD=true

############################################
# REGISTRIES TO MIRROR
############################################

REGISTRIES=(
  "docker.io"
  "registry-1.docker.io"
  "registry.k8s.io"
  "quay.io"
  "ghcr.io"
  "gcr.io"
  "us-docker.pkg.dev"
  "public.ecr.aws"
  "mcr.microsoft.com"
)

############################################
# FUNCTIONS
############################################

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: must be run as root" >&2
    exit 1
  fi
}

ensure_containerd_config_path() {
  local cfg="/etc/containerd/config.toml"

  if [[ ! -f "$cfg" ]]; then
    echo "Generating default containerd config"
    containerd config default > "$cfg"
  fi

  if ! grep -q 'config_path *= *"/etc/containerd/certs.d"' "$cfg"; then
    echo "Enabling config_path in containerd config"

    # Minimal and safe append if section exists
    if grep -q '\[plugins\."io.containerd.grpc.v1.cri".registry\]' "$cfg"; then
      sed -i '/\[plugins\."io.containerd.grpc.v1.cri".registry\]/a \  config_path = "/etc/containerd/certs.d"' "$cfg"
    else
      cat >> "$cfg" <<'EOF'

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
EOF
    fi
  fi
}

write_hosts_toml() {
  local registry="$1"
  local dir="$CERTS_DIR/$registry"
  local file="$dir/hosts.toml"

  mkdir -p "$dir"

  cat > "$file" <<EOF
server = "https://$registry"

[host."$INTERNAL_REGISTRY"]
  capabilities = ["pull", "resolve"]
EOF

  if [[ -n "$INTERNAL_CA_PATH" ]]; then
    cat >> "$file" <<EOF
  ca = "$INTERNAL_CA_PATH"
EOF
  fi
}

############################################
# MAIN
############################################

require_root
ensure_containerd_config_path

echo "Creating registry mirror configurations..."

for r in "${REGISTRIES[@]}"; do
  echo "  - $r"
  write_hosts_toml "$r"
done

if [[ "$RESTART_CONTAINERD" == "true" ]]; then
  echo "Restarting containerd"
  systemctl restart containerd
fi

echo "Done."
