#!/usr/bin/env bash
# Reconcile per-user t3 instances from /etc/ttyd-user-map.
# Each "authentik_user=os_user" line -> an enabled t3-serve@<os_user> on a
# sticky port, plus /etc/t3-serve/dispatch.json (authentik_user -> {os_user,port})
# consumed by t3-dispatch.
set -euo pipefail
MAP=/etc/ttyd-user-map
ENVDIR=/etc/t3-serve
BASE_PORT=3773
install -d -m 0755 "$ENVDIR"

port_of() { grep -oE 'T3_PORT=[0-9]+' "$1" | cut -d= -f2; }

next_port() {            # lowest free port >= BASE_PORT not already assigned
  local used p
  used=$(grep -hoE 'T3_PORT=[0-9]+' "$ENVDIR"/*.env 2>/dev/null | cut -d= -f2 | sort -n)
  p=$BASE_PORT
  while echo "$used" | grep -qx "$p"; do p=$((p+1)); done
  echo "$p"
}

declare -A DISPATCH
while IFS='=' read -r ak os; do
  [[ -z "${ak// }" || "$ak" =~ ^[[:space:]]*# ]] && continue
  ak=$(echo "$ak" | xargs); os=$(echo "$os" | xargs)
  [[ -z "$ak" || -z "$os" ]] && continue
  if ! id "$os" >/dev/null 2>&1; then
    logger -t t3-provision "skip $ak: no OS user $os"; continue
  fi
  envf="$ENVDIR/$os.env"
  [[ -f "$envf" ]] || echo "T3_PORT=$(next_port)" > "$envf"
  port=$(port_of "$envf")
  systemctl enable --now "t3-serve@$os.service" >/dev/null 2>&1 || true
  DISPATCH[$ak]="{\"os_user\":\"$os\",\"port\":$port}"
done < "$MAP"

tmp=$(mktemp)
{ printf '{'; first=1
  for ak in "${!DISPATCH[@]}"; do
    [[ $first -eq 0 ]] && printf ','; first=0
    printf '"%s":%s' "$ak" "${DISPATCH[$ak]}"
  done; printf '}\n'; } > "$tmp"
install -m 0644 "$tmp" "$ENVDIR/dispatch.json"; rm -f "$tmp"
logger -t t3-provision "reconcile complete: $(wc -c < "$ENVDIR/dispatch.json") bytes"
