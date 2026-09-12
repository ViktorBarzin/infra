#!/usr/bin/env bash
# Bootstrap the Mac side of the iOS test rig. Idempotent: safe to re-run, and
# enough on its own to rebuild the rig on a freshly imaged machine.
#
# Run it FROM the devvm:
#   scripts/ios-rig/bootstrap-mac.sh
# or on the Mac itself:
#   bash bootstrap-mac.sh --local
#
# What it does NOT do, because Apple requires a human holding the phone:
#   - accept the Trust dialog
#   - turn on Developer Mode
#   - trust the developer profile after the first install
# `ios-rig doctor` tells you which of those is outstanding.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/rig.env"

LOCAL=0
[[ "${1:-}" == "--local" ]] && LOCAL=1

run() {
  if [[ $LOCAL == 1 ]]; then
    bash -lc "$1"
  else
    ssh -o ConnectTimeout=12 -o BatchMode=yes \
      "${IOS_RIG_MAC_USER}@${IOS_RIG_MAC_HOST}" "bash -lc $(printf '%q' "$1")"
  fi
}

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

say "Homebrew formulae"
run 'export PATH=/opt/homebrew/bin:$PATH HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1
for f in libimobiledevice ideviceinstaller socat; do
  brew list --formula "$f" >/dev/null 2>&1 || brew install "$f"
done
brew list --formula libimobiledevice ideviceinstaller socat | tr "\n" " "'

say "Node and Appium"
run 'export PATH="$HOME/.npm-global/bin:/opt/homebrew/bin:$PATH"
command -v node >/dev/null || brew install node
command -v appium >/dev/null || npm install -g appium
appium driver list --installed 2>&1 | grep -q xcuitest || appium driver install xcuitest
printf "appium %s\n" "$(appium --version)"'

# Appium listened on 0.0.0.0 until 2026-09-12. The Mac sits on a shared guest
# network, so that let anyone on that wifi drive the phone. It binds to
# loopback now and the devvm reaches it through an SSH tunnel instead.
say "Appium LaunchAgent (loopback only)"
run "cat > \$HOME/Library/LaunchAgents/me.viktorbarzin.appium.plist <<'PLIST'
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
  <key>Label</key><string>me.viktorbarzin.appium</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>export PATH=\"\\\$HOME/bin:\\\$HOME/.npm-global/bin:\\\$HOME/.local/bin:/opt/homebrew/bin:\\\$PATH\"; export DEVELOPER_DIR=\"${IOS_RIG_DEVELOPER_DIR}\"; exec appium --address 127.0.0.1 --port ${IOS_RIG_APPIUM_PORT}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/appium.out</string>
  <key>StandardErrorPath</key><string>/tmp/appium.err</string>
</dict>
</plist>
PLIST
launchctl bootout gui/\$(id -u)/me.viktorbarzin.appium 2>/dev/null || true
launchctl bootstrap gui/\$(id -u) \$HOME/Library/LaunchAgents/me.viktorbarzin.appium.plist
launchctl list | grep me.viktorbarzin.appium"

say "WebDriverAgent re-sign LaunchAgent"
run "mkdir -p \$HOME/bin"
if [[ $LOCAL == 1 ]]; then
  cp "$HERE/resign-wda.sh" "$HOME/bin/ios-rig-resign-wda.sh"
else
  scp -q "$HERE/resign-wda.sh" \
    "${IOS_RIG_MAC_USER}@${IOS_RIG_MAC_HOST}:bin/ios-rig-resign-wda.sh"
fi
run "chmod +x \$HOME/bin/ios-rig-resign-wda.sh"

# Free-team certificates last 7 days. Firing every 2 days means three chances
# to renew before one actually expires, which covers a long weekend where the
# laptop never wakes.
run "cat > \$HOME/Library/LaunchAgents/me.viktorbarzin.wda-resign.plist <<'PLIST'
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
  <key>Label</key><string>me.viktorbarzin.wda-resign</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>\\\$HOME/bin/ios-rig-resign-wda.sh</string>
  </array>
  <key>StartInterval</key><integer>172800</integer>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>/tmp/wda-resign.out</string>
  <key>StandardErrorPath</key><string>/tmp/wda-resign.err</string>
</dict>
</plist>
PLIST
launchctl bootout gui/\$(id -u)/me.viktorbarzin.wda-resign 2>/dev/null || true
launchctl bootstrap gui/\$(id -u) \$HOME/Library/LaunchAgents/me.viktorbarzin.wda-resign.plist
launchctl list | grep me.viktorbarzin.wda-resign"

say "Done"
echo "Next: run 'scripts/ios-rig/ios-rig doctor' from the devvm."
