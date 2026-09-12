#!/usr/bin/env bash
# Keep WebDriverAgent running on the test iPhone, and publish the URL it is
# listening on.
#
# Runs ON THE MAC under the me.viktorbarzin.wda-run LaunchAgent, which has
# KeepAlive set, so this script runs in the foreground and lets launchd restart
# it whenever WDA dies (phone reboot, cable pull, certificate expiry).
#
# WDA is reached over WI-FI, not usbmuxd. Stolen Device Protection on this
# phone gates the classic lockdown pairing behind a Face ID that is not
# enrolled for the current owner, so the usbmux path is unavailable. WDA binds
# to the device's Wi-Fi address as well, and that is what everything uses.

set -uo pipefail

UDID="${IOS_RIG_UDID:-00008110-001614D03442801E}"
DEVELOPER_DIR="${IOS_RIG_DEVELOPER_DIR:-/Applications/Xcode_26.6.0_17F113_fb.app/Contents/Developer}"
export DEVELOPER_DIR
export PATH="/opt/homebrew/bin:$HOME/.npm-global/bin:$PATH"

WDA_DIR="$HOME/.appium/node_modules/appium-xcuitest-driver/node_modules/appium-webdriveragent"
LOG=/tmp/wda-run.log
URL_FILE="$HOME/.ios-rig-wda-url"

cd "$WDA_DIR" || { echo "no WebDriverAgent at $WDA_DIR"; exit 1; }
: > "$LOG"

xcodebuild -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner \
  -destination "id=$UDID" test-without-building >> "$LOG" 2>&1 &
XCB=$!

# WDA prints its listening address once, as
#   ServerURLHere->http://192.168.9.205:8100<-ServerURLHere
# The phone takes a DHCP lease, so this address changes and is never assumed.
for _ in $(seq 1 90); do
  url="$(sed -n 's/.*ServerURLHere->\(http[^<]*\)<-ServerURLHere.*/\1/p' "$LOG" | head -1)"
  if [[ -n "$url" ]]; then
    printf '%s\n' "$url" > "$URL_FILE"
    echo "WDA listening on $url"
    break
  fi
  kill -0 "$XCB" 2>/dev/null || { echo "xcodebuild exited before WDA came up"; break; }
  sleep 2
done

if [[ ! -s "$URL_FILE" ]]; then
  rm -f "$URL_FILE"
  # Surface the reason rather than dying silently. The usual one is the
  # developer certificate not being trusted on the device yet.
  grep -iE "not trusted|Testing failed|TEST EXECUTE FAILED|denied" "$LOG" | head -3
fi

wait "$XCB"
rm -f "$URL_FILE"
