#!/usr/bin/env bash
# Copy the LED strip add-on to ha-london and have the Supervisor build and start it.
# Idempotent: installs on the first run, rebuilds after that. Run from anywhere.
# The HA side (light.livia) is packages/livia.yaml in the ha-london-config repo.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ssh_ha() { homelab ha ssh --instance london -- "$@"; }

# The image is built by GitHub Actions (.github/workflows/build-ha-addon-led-strip.yml)
# after the change reaches master; the Pi only pulls it. Wait for that tag.
version=$(sed -n 's/^version: "\(.*\)"/\1/p' "$here/config.yaml")
image=viktorbarzin/ha-addon-led-strip
tag_exists() {
  local tok
  tok=$(curl -sf "https://ghcr.io/token?scope=repository:$image:pull" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
  curl -sf -H "Authorization: Bearer $tok" "https://ghcr.io/v2/$image/tags/list" \
    | python3 -c "import json,sys; sys.exit(0 if '$version' in json.load(sys.stdin)['tags'] else 1)"
}
until tag_exists; do echo "waiting for ghcr.io/$image:$version (push to master builds it)"; sleep 30; done

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
  echo "installing $want (pulls the image)"
  api POST /store/addons/local_led_strip/install >/dev/null
elif [ "$have" != "$want" ]; then
  echo "updating $have -> $want (pulls the image)"
  api POST /store/addons/local_led_strip/update >/dev/null
else
  echo "rebuilding $have"
  api POST /addons/local_led_strip/rebuild >/dev/null
fi
api POST /addons/local_led_strip/start >/dev/null || true
sleep 5
api GET /addons/local_led_strip/info | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print("state", d["state"], "version", d["version"], "boot", d["boot"])'
EOF
