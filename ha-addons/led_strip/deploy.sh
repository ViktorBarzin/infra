#!/usr/bin/env bash
# Copy the LED strip add-on to ha-london and have the Supervisor build and start it.
# Idempotent: installs on the first run, rebuilds after that. Run from anywhere.
# The HA side (light.livia) is packages/livia.yaml in the ha-london-config repo.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ssh_ha() { homelab ha ssh --instance london -- "$@"; }

tar -C "$here" -czf - Dockerfile config.yaml server.py strandtest.py \
  | ssh_ha 'sudo mkdir -p /addons/led_strip && sudo tar -C /addons/led_strip -xzf - && ls /addons/led_strip'

ssh_ha 'bash -s' <<'EOF'
set -euo pipefail
T=$(sudo cat /run/s6/container_environment/SUPERVISOR_TOKEN)
api() { curl -sf -X "$1" -H "Authorization: Bearer $T" "http://supervisor$2"; }
api POST /store/reload >/dev/null
read -r have want < <(api GET /addons/local_led_strip/info \
  | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d["version"], d["version_latest"])')
if [ "$have" = "None" ]; then
  echo "installing $want (builds on the Pi, a few minutes)"
  api POST /store/addons/local_led_strip/install >/dev/null
elif [ "$have" != "$want" ]; then
  echo "updating $have -> $want (builds on the Pi)"
  api POST /store/addons/local_led_strip/update >/dev/null
else
  echo "rebuilding $have"
  api POST /addons/local_led_strip/rebuild >/dev/null
fi
api POST /addons/local_led_strip/start >/dev/null || true
sleep 5
api GET /addons/local_led_strip/info | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print("state", d["state"], "version", d["version"], "boot", d["boot"])'
EOF
