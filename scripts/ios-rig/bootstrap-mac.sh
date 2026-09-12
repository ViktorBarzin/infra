#!/usr/bin/env bash
# Bootstrap the Mac side of the iOS test rig. Idempotent: safe to re-run, and
# enough on its own to rebuild the rig on a freshly imaged machine.
#
#   scripts/ios-rig/bootstrap-mac.sh            from the devvm, over SSH
#   scripts/ios-rig/bootstrap-mac.sh --local    on the Mac itself
#   scripts/ios-rig/bootstrap-mac.sh --dry-run  print what would change
#
# What it deliberately does not do, because Apple requires a human holding the
# phone: accept the Trust dialog, turn on Developer Mode, trust the developer
# profile after the first install. `ios-rig doctor` reports which are missing.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/rig.env"

LOCAL=0; DRY=0
for a in "$@"; do
  case "$a" in
    --local)   LOCAL=1 ;;
    --dry-run) DRY=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

MAC="${IOS_RIG_MAC_USER}@${IOS_RIG_MAC_HOST}"
SSH_OPTS=(-o ConnectTimeout=12 -o BatchMode=yes)

say()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
run()  {
  if (( DRY )); then printf '  would run: %s\n' "$1"; return 0; fi
  if (( LOCAL )); then bash -lc "$1"
  else ssh "${SSH_OPTS[@]}" "$MAC" "bash -lc $(printf '%q' "$1")"; fi
}
put() {  # put <local> <remote-path-relative-to-home>
  if (( DRY )); then printf '  would copy: %s -> ~/%s\n' "$1" "$2"; return 0; fi
  if (( LOCAL )); then install -D -m "${3:-0644}" "$1" "$HOME/$2"
  else
    ssh "${SSH_OPTS[@]}" "$MAC" "mkdir -p \$HOME/$(dirname "$2")"
    scp -q "${SSH_OPTS[@]}" "$1" "$MAC:$2"
    ssh "${SSH_OPTS[@]}" "$MAC" "chmod ${3:-0644} \$HOME/$2"
  fi
}

render() {  # render <template> -> stdout
  sed -e "s|@DEVELOPER_DIR@|${IOS_RIG_DEVELOPER_DIR}|g" \
      -e "s|@APPIUM_PORT@|${IOS_RIG_APPIUM_PORT}|g" "$1"
}

reload_agent() {  # reload_agent <label>
  run "launchctl bootout gui/\$(id -u)/$1 2>/dev/null || true
       launchctl bootstrap gui/\$(id -u) \$HOME/Library/LaunchAgents/$1.plist
       launchctl list | grep -F $1"
}

say "Homebrew formulae"
run 'export PATH=/opt/homebrew/bin:$PATH HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1
for f in libimobiledevice ideviceinstaller socat; do
  brew list --formula "$f" >/dev/null 2>&1 || brew install "$f"
done
echo "present: $(brew list --formula libimobiledevice ideviceinstaller socat | tr "\n" " ")"'

say "Node and Appium"
run 'export PATH="$HOME/.npm-global/bin:/opt/homebrew/bin:$PATH"
command -v node >/dev/null || brew install node
command -v appium >/dev/null || npm install -g appium
appium driver list --installed 2>&1 | grep -q xcuitest || appium driver install xcuitest
echo "appium $(appium --version)"'

# Appium listened on 0.0.0.0 until 2026-09-12. The Mac sits on a shared guest
# network, so that gave anyone on that wifi full control of the phone. It binds
# to loopback now; the devvm reaches it through `ios-rig tunnel`.
say "Appium LaunchAgent, loopback only"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
render "$HERE/launchagents/me.viktorbarzin.appium.plist.tmpl" > "$TMP/appium.plist"
python3 -c "import plistlib,sys; plistlib.load(open(sys.argv[1],'rb'))" "$TMP/appium.plist"
put "$TMP/appium.plist" "Library/LaunchAgents/me.viktorbarzin.appium.plist"
(( DRY )) || reload_agent me.viktorbarzin.appium

say "WebDriverAgent re-sign LaunchAgent, every 48h"
put "$HERE/resign-wda.sh" "bin/ios-rig-resign-wda.sh" 0755
render "$HERE/launchagents/me.viktorbarzin.wda-resign.plist.tmpl" > "$TMP/resign.plist"
python3 -c "import plistlib,sys; plistlib.load(open(sys.argv[1],'rb'))" "$TMP/resign.plist"
put "$TMP/resign.plist" "Library/LaunchAgents/me.viktorbarzin.wda-resign.plist"
(( DRY )) || reload_agent me.viktorbarzin.wda-resign

say "Done"
echo "Next: scripts/ios-rig/ios-rig doctor"
