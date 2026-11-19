#!/usr/bin/env bash
# Copy the journal upload add-on to ha-london and install or update it.
# Idempotent: installs on the first run, rebuilds after that. Run from anywhere.
# The receiver is stacks/monitoring (alloy-journal, 10.0.20.200:19532).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ssh_ha() { homelab ha ssh --instance london -- "$@"; }

# The image is built by GitHub Actions (.github/workflows/build-ha-addon-journal-upload.yml)
# after the change reaches master; the Pi only pulls it. Wait for that tag.
version=$(sed -n 's/^version: "\(.*\)"/\1/p' "$here/config.yaml")
image=viktorbarzin/ha-addon-journal-upload
tag_exists() {
  local tok
  tok=$(curl -sf "https://ghcr.io/token?scope=repository:$image:pull" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
  curl -sf -H "Authorization: Bearer $tok" "https://ghcr.io/v2/$image/tags/list" \
    | python3 -c "import json,sys; sys.exit(0 if '$version' in json.load(sys.stdin)['tags'] else 1)"
}
until tag_exists; do echo "waiting for ghcr.io/$image:$version (push to master builds it)"; sleep 30; done

tar -C "$here" -czf - Dockerfile config.yaml lib.sh run.sh \
  | ssh_ha 'sudo mkdir -p /addons/journal_upload && sudo tar -C /addons/journal_upload -xzf - && ls /addons/journal_upload'

ssh_ha 'bash -s' <<'EOF'
set -euo pipefail
T=$(sudo cat /run/s6/container_environment/SUPERVISOR_TOKEN)
api() { curl -sf -X "$1" -H "Authorization: Bearer $T" "http://supervisor$2"; }
api POST /store/reload >/dev/null
read -r have want < <(api GET /addons/local_journal_upload/info \
  | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d["version"], d["version_latest"])')
if [ "$have" = "None" ]; then
  echo "installing $want (pulls the image)"
  api POST /store/addons/local_journal_upload/install >/dev/null
elif [ "$have" != "$want" ]; then
  echo "updating $have -> $want (pulls the image)"
  api POST /store/addons/local_journal_upload/update >/dev/null
else
  echo "already at $have, restarting"
  api POST /addons/local_journal_upload/restart >/dev/null
fi
api POST /addons/local_journal_upload/start >/dev/null || true
sleep 5
api GET /addons/local_journal_upload/info | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print("state", d["state"], "version", d["version"], "boot", d["boot"])'
EOF
