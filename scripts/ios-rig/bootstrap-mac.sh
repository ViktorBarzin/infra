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

# launchctl bootout is asynchronous. Bootstrapping before the old job has
# finished unloading fails with "Bootstrap failed: 5: Input/output error" and
# leaves NOTHING loaded, which is how a re-run of this script took Appium down
# on 2026-09-12. Wait for the label to disappear, then retry the bootstrap.
reload_agent() {  # reload_agent <label>
  run "label=$1
       plist=\$HOME/Library/LaunchAgents/$1.plist
       launchctl bootout gui/\$(id -u)/\$label 2>/dev/null || true
       for _ in \$(seq 1 20); do
         launchctl list | grep -qF \$label || break
         sleep 0.5
       done
       for attempt in 1 2 3 4 5; do
         if launchctl bootstrap gui/\$(id -u) \$plist 2>/dev/null; then break; fi
         sleep 1
       done
       launchctl list | grep -F \$label || { echo \"FAILED to load \$label\"; exit 1; }"
}

say "Homebrew formulae"
run 'export PATH=/opt/homebrew/bin:$PATH HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1
for f in libimobiledevice ideviceinstaller socat; do
  brew list --formula "$f" >/dev/null 2>&1 || brew install "$f"
done
brew list --versions libimobiledevice ideviceinstaller socat'

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

say "WebDriverAgent runner LaunchAgent"
put "$HERE/run-wda.sh" "bin/ios-rig-run-wda.sh" 0755
render "$HERE/launchagents/me.viktorbarzin.wda-run.plist.tmpl" > "$TMP/wdarun.plist"
python3 -c "import plistlib,sys; plistlib.load(open(sys.argv[1],'rb'))" "$TMP/wdarun.plist"
put "$TMP/wdarun.plist" "Library/LaunchAgents/me.viktorbarzin.wda-run.plist"
(( DRY )) || reload_agent me.viktorbarzin.wda-run

say "Keep-awake LaunchAgent"
render "$HERE/launchagents/me.viktorbarzin.ios-rig-awake.plist.tmpl" > "$TMP/awake.plist"
python3 -c "import plistlib,sys; plistlib.load(open(sys.argv[1],'rb'))" "$TMP/awake.plist"
put "$TMP/awake.plist" "Library/LaunchAgents/me.viktorbarzin.ios-rig-awake.plist"
(( DRY )) || reload_agent me.viktorbarzin.ios-rig-awake

say "Build and install LaunchAgent (on demand)"
run 'export PATH=/opt/homebrew/bin:$PATH HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1
brew list --formula xcodegen >/dev/null 2>&1 || brew install xcodegen
brew list --versions xcodegen'
put "$HERE/build-install.sh" "bin/ios-rig-build-install.sh" 0755
render "$HERE/launchagents/me.viktorbarzin.ios-rig-build.plist.tmpl" > "$TMP/build.plist"
python3 -c "import plistlib,sys; plistlib.load(open(sys.argv[1],'rb'))" "$TMP/build.plist"
put "$TMP/build.plist" "Library/LaunchAgents/me.viktorbarzin.ios-rig-build.plist"
(( DRY )) || reload_agent me.viktorbarzin.ios-rig-build

say "Done"
echo "Next: scripts/ios-rig/ios-rig doctor"
