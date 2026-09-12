#!/usr/bin/env bash
# Build an iOS app with the free personal team and install it on the rig phone.
#
# Runs ON THE MAC under the me.viktorbarzin.ios-rig-build LaunchAgent, because
# codesign needs the login keychain and that is only reachable from the Aqua
# session. Over SSH it fails with errSecInternalComponent.
#
# Reads its inputs from ~/.ios-rig-build.env, which `ios-rig install` writes:
#   RIG_BUILD_DIR    project directory on the Mac (holds .xcodeproj, or project.yml)
#   RIG_BUILD_SCHEME xcodebuild scheme
#   RIG_BUILD_BUNDLE bundle identifier to sign as
#   RIG_BUILD_LAUNCH 1 to launch it after installing

set -uo pipefail

TEAM_ID="${IOS_RIG_TEAM_ID:-26NB4W97WL}"
UDID="${IOS_RIG_UDID:-00008110-001614D03442801E}"
DEVELOPER_DIR="${IOS_RIG_DEVELOPER_DIR:-/Applications/Xcode_26.6.0_17F113_fb.app/Contents/Developer}"
export DEVELOPER_DIR
export PATH="/opt/homebrew/bin:$PATH"

LOG=/tmp/ios-rig-build.log
STATUS="$HOME/.ios-rig-build-status.json"
DC="$DEVELOPER_DIR/usr/bin/devicectl"

write_status() {
  printf '{"ts":"%s","ok":%s,"stage":"%s","detail":"%s","bundle":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "${3//\"/\'}" "${RIG_BUILD_BUNDLE:-}" > "$STATUS"
}
fail() { echo "FAIL [$1] $2" | tee -a "$LOG"; write_status false "$1" "$2"; exit 1; }

: > "$LOG"
echo "=== $(date -u +%FT%TZ) build ===" >> "$LOG"

# shellcheck source=/dev/null
[[ -f "$HOME/.ios-rig-build.env" ]] || fail no-input "no ~/.ios-rig-build.env"
source "$HOME/.ios-rig-build.env"
: "${RIG_BUILD_DIR:?}" "${RIG_BUILD_SCHEME:?}" "${RIG_BUILD_BUNDLE:?}"

cd "$RIG_BUILD_DIR" || fail no-project "no directory $RIG_BUILD_DIR"

# A project.yml means xcodegen owns the .xcodeproj, so regenerate rather than
# carrying a generated file around in git.
if [[ -f project.yml ]]; then
  command -v xcodegen >/dev/null || fail no-xcodegen "project.yml present but xcodegen is not installed"
  xcodegen generate >> "$LOG" 2>&1 || fail xcodegen "xcodegen failed, see $LOG"
fi

PROJ="$(ls -d ./*.xcodeproj 2>/dev/null | head -1)"
[[ -n "$PROJ" ]] || fail no-project "no .xcodeproj in $RIG_BUILD_DIR"

grep -q "developerModeStatus: enabled" <<<"$("$DC" device info details --device "$UDID" 2>&1)" \
  || fail developer-mode "Developer Mode is off on $UDID"

DERIVED="$HOME/Library/Developer/Xcode/DerivedData/ios-rig-build"
rm -rf "$DERIVED"

# -allowProvisioningUpdates mints the 7-day free-team profile. Each NEW bundle
# id also burns one of the 10 App IDs the free tier allows per week.
xcodebuild \
  -project "$PROJ" \
  -scheme "$RIG_BUILD_SCHEME" \
  -configuration Debug \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$RIG_BUILD_BUNDLE" \
  CODE_SIGN_STYLE=Automatic \
  build >> "$LOG" 2>&1 || fail build "xcodebuild failed, see $LOG"

APP="$(find "$DERIVED/Build/Products" -maxdepth 2 -name '*.app' -type d | head -1)"
[[ -n "$APP" ]] || fail no-product "build succeeded but produced no .app"
echo "built $APP" >> "$LOG"

# devicectl, not ideviceinstaller: the lockdown pairing ideviceinstaller needs
# is blocked by Stolen Device Protection on this phone.
"$DC" device install app --device "$UDID" "$APP" >> "$LOG" 2>&1 \
  || fail install "devicectl install failed, see $LOG"

"$DC" device info apps --device "$UDID" 2>/dev/null | grep -qF "$RIG_BUILD_BUNDLE" \
  || fail verify "installed but $RIG_BUILD_BUNDLE is not in the app list"

if [[ "${RIG_BUILD_LAUNCH:-0}" == "1" ]]; then
  # A first launch fails until the developer certificate is trusted on the
  # device, and that message is the useful one to surface.
  "$DC" device process launch --device "$UDID" "$RIG_BUILD_BUNDLE" >> "$LOG" 2>&1 \
    || fail launch "installed but would not launch; trust the certificate in Settings, General, VPN and Device Management"
fi

echo "OK installed $RIG_BUILD_BUNDLE" >> "$LOG"
write_status true ok "installed $RIG_BUILD_BUNDLE"
