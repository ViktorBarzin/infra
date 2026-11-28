#!/usr/bin/env bash
# Copy the AirPlay and Spotify add-on to ha-london and have the Supervisor
# build and start it. The Pi builds the image itself: the Dockerfile only adds
# Alpine packages to go-librespot's image, about a minute on the Pi 3.
# Idempotent. Run from anywhere. The HA side is packages/radio.yaml in the
# ha-london-config repo (input_boolean.airplay_playing, spotify_playing).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ssh_ha() { homelab ha ssh --instance london -- "$@"; }

tar -C "$here" -czf - Dockerfile config.yaml run.sh playing.sh spotify_watch.sh \
  | ssh_ha 'sudo rm -rf /addons/airplay_spotify && sudo mkdir -p /addons/airplay_spotify && sudo tar -C /addons/airplay_spotify -xzf - && ls /addons/airplay_spotify'

ssh_ha 'bash -s' <<'SH'
set -euo pipefail
T=$(sudo cat /run/s6/container_environment/SUPERVISOR_TOKEN)
api() { curl -sf -m 900 -X "$1" -H "Authorization: Bearer $T" -H "Content-Type: application/json" ${3:+-d "$3"} "http://supervisor$2"; }
api POST /store/reload >/dev/null
read -r have want < <(api GET /addons/local_airplay_spotify/info \
  | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d["version"], d["version_latest"])')
if [ "$have" = "None" ]; then
  echo "installing $want (builds the image)"
  api POST /store/addons/local_airplay_spotify/install >/dev/null
elif [ "$have" != "$want" ]; then
  echo "updating $have -> $want (builds the image)"
  api POST /store/addons/local_airplay_spotify/update >/dev/null
else
  echo "rebuilding $have"
  api POST /addons/local_airplay_spotify/rebuild >/dev/null
fi
# The watchdog restarts the add-on when run.sh exits because a receiver died.
api POST /addons/local_airplay_spotify/options '{"watchdog": true}' >/dev/null
api POST /addons/local_airplay_spotify/start >/dev/null || true
sleep 10
api GET /addons/local_airplay_spotify/info | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print("state", d["state"], "version", d["version"], "boot", d["boot"], "watchdog", d["watchdog"])'
SH
