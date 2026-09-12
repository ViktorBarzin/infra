#!/usr/bin/env bash
# Rebuild and reinstall WebDriverAgent on the test iPhone.
#
# Runs ON THE MAC, from the me.viktorbarzin.wda-resign LaunchAgent every 48h.
# Free Apple ID certificates last 7 days, so WDA has to be re-signed before it
# lapses or Appium can no longer start a session.
#
# MUST run in the Aqua GUI session. codesign fails with errSecInternalComponent
# in an SSH session because the login keychain holding the signing key is not
# reachable there. Measured 2026-09-12.
#
# Deliberately holds no credentials. It writes a status file that the devvm
# reads through `ios-rig doctor`, and the devvm is what talks to Slack.

set -uo pipefail

UDID="${IOS_RIG_UDID:-00008110-001614D03442801E}"
TEAM_ID="${IOS_RIG_TEAM_ID:-26NB4W97WL}"
WDA_BUNDLE_ID="${IOS_RIG_WDA_BUNDLE_ID:-me.viktorbarzin.wda}"
DEVELOPER_DIR="${IOS_RIG_DEVELOPER_DIR:-/Applications/Xcode_26.6.0_17F113_fb.app/Contents/Developer}"
export DEVELOPER_DIR
export PATH="/opt/homebrew/bin:$HOME/.npm-global/bin:$PATH"

WDA_PROJ="$HOME/.appium/node_modules/appium-xcuitest-driver/node_modules/appium-webdriveragent/WebDriverAgent.xcodeproj"
STATUS="$HOME/.ios-rig-status.json"
LOG="/tmp/wda-resign.log"

write_status() {
  printf '{"ts":"%s","ok":%s,"stage":"%s","detail":"%s","udid":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "${3//\"/\'}" "$UDID" > "$STATUS"
}

fail() { echo "FAIL [$1] $2" | tee -a "$LOG"; write_status false "$1" "$2"; exit 1; }

echo "=== $(date -u +%FT%TZ) re-sign run ===" >> "$LOG"

# The runner holds the old build open. Stop it, rebuild, and let its KeepAlive
# start it again against the freshly signed bundle.
launchctl bootout "gui/$(id -u)/me.viktorbarzin.wda-run" 2>/dev/null || true
trap 'launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/me.viktorbarzin.wda-run.plist" 2>/dev/null || true' EXIT

[[ -f "$WDA_PROJ/project.pbxproj" ]] || fail project-missing "no WebDriverAgent project at $WDA_PROJ"

# Failing these is normal (phone unplugged, laptop travelling) and is not the
# same as the build being broken, so each gets its own stage name.
# Everything here goes through devicectl rather than libimobiledevice.
# iOS 17+ keeps TWO independent pairing records: CoreDevice's RemoteXPC one,
# and the classic lockdown one. They break independently, and the lockdown one
# needs a Trust dialog that is easy to lose. CoreDevice's survives, so the job
# that has to run unattended depends only on that.
DC="$DEVELOPER_DIR/usr/bin/devicectl"
details="$("$DC" device info details --device "$UDID" 2>&1)"

grep -q "bootState: booted" <<<"$details" || fail device-absent "device $UDID is not connected and booted"
grep -q "developerModeStatus: enabled" <<<"$details" || \
  fail developer-mode "Developer Mode is off; enable it in Settings, Privacy and Security"
grep -q "ddiServicesAvailable: true" <<<"$details" || \
  fail ddi "developer disk image services unavailable"

# -allowProvisioningUpdates is what mints the fresh 7-day certificate against
# the free personal team. It needs the login keychain unlocked, which is why
# this runs as an Aqua LaunchAgent rather than over SSH.
if ! xcodebuild \
      -project "$WDA_PROJ" \
      -scheme WebDriverAgentRunner \
      -destination "id=$UDID" \
      -allowProvisioningUpdates \
      DEVELOPMENT_TEAM="$TEAM_ID" \
      PRODUCT_BUNDLE_IDENTIFIER="$WDA_BUNDLE_ID" \
      CODE_SIGN_STYLE=Automatic \
      build-for-testing >> "$LOG" 2>&1; then
  fail build "xcodebuild build-for-testing failed, see $LOG"
fi

# build-for-testing signs and stages the bundle. Installing and launching it is
# the runner LaunchAgent's job, which the trap above restarts on the way out.
echo "OK re-signed $WDA_BUNDLE_ID" >> "$LOG"
write_status true ok "re-signed $WDA_BUNDLE_ID, runner restarting"
