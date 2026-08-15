#!/usr/bin/env bash
# provision-portal.sh — reprovision Viktor's London Meta Portal+ after a factory reset.
#
# Reinstalls the four kitchen-appliance apps and re-applies every device setting
# that makes them usable, starting from a clean, ADB-ready device. Idempotent:
# safe to re-run.
#
#   Immich frame    — built from source (~/code/portal-immich-frame)
#   Spotify         — apk-pure via apkeep, latest (split APK)
#   VirtualSoftKeys — F-Droid (your only way out of a fullscreen app)
#   Home Assistant  — F-Droid "minimal" (dashboards; personal account)
#
# HUMAN PREREQUISITES (cannot be automated — do these first, on the device):
#   1. Portal through OOBE, signed in, joined to the HOME Wi-Fi (the Immich frame
#      endpoint is LAN-gated — it must be on the home LAN / London tunnel).
#   2. Take the OTA update (the official developer-access rollout).
#   3. Enable ADB: Settings > About > tap "Build Number" 7x > back out >
#      Developer options > USB debugging. Plug into the Mac, tap "Allow".
#   4. AFTER this script: open Spotify + Home Assistant and log in (personal
#      accounts — the script cannot do this for you).
#
# Design, rationale, and troubleshooting: infra/docs/runbooks/provision-portal.md
set -euo pipefail

# ---- config (all overridable via env) --------------------------------------
# USB host on the Portal's LAN. By NAME: the Mac's macOS private Wi-Fi address
# rotates, which is what left its previous DHCP reservation stale. It is pinned to
# 192.168.8.168 by a Flint reservation covering both that address and the hardware
# MAC, and mbp-london.viktorbarzin.lan resolves to it.
MAC="${MAC:-viktorbarzin@mbp-london.viktorbarzin.lan}"
RADB="${RADB:-/Users/viktorbarzin/Library/Android/sdk/platform-tools/adb}"  # adb path ON the Mac
FRAME_REPO="${FRAME_REPO:-$HOME/code/portal-immich-frame}"
FRAME_URL="${FRAME_URL:-}"              # empty => build-apk.sh default (London)
NO_BUILD="${NO_BUILD:-}"               # set to 1 to reuse an existing frame APK
APKEEP_IMG="${APKEEP_IMG:-apkeep-local:1.0.0}"
APKEEP_VER="${APKEEP_VER:-1.0.0}"
WORK="$(mktemp -d "${TMPDIR:-/dev/shm}/portal-provision.XXXXXX")"

FRAME_PKG="me.viktorbarzin.portalframe"; FRAME_ACT=".FrameActivity"
SPOTIFY_PKG="com.spotify.music"
VSK_PKG="tw.com.daxia.virtualsoftkeys"
VSK_A11Y="${VSK_PKG}/${VSK_PKG}.service.ServiceFloating"
HA_PKG="io.homeassistant.companion.android.minimal"

log(){ printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# ---- 0. preflight ----------------------------------------------------------
log "Preflight — Portal ADB-reachable via $MAC ?"
DEV="$(ssh "$MAC" "\"$RADB\" devices" | awk 'NR>1 && $2=="device"{print $1}' | head -1)"
[ -n "$DEV" ] || die "No authorized device. Plug in USB + tap Allow on the Portal, then re-run."
MODEL="$(ssh "$MAC" "\"$RADB\" shell getprop ro.product.device" | tr -d '\r')"
echo "   device=$DEV model=$MODEL"
[ "$MODEL" = "aloha" ] || echo "   (note: expected 'aloha'/Portal+, got '$MODEL' — continuing)"

# ---- 1. build the Immich frame APK ----------------------------------------
FRAME_APK="$FRAME_REPO/app/build/outputs/apk/debug/app-debug.apk"
if [ "$NO_BUILD" = 1 ] && [ -f "$FRAME_APK" ]; then
  log "Reusing existing frame APK (NO_BUILD=1)"
else
  log "Building the Immich frame APK (Dockerized Gradle)"
  ( cd "$FRAME_REPO" && FRAME_URL="$FRAME_URL" scripts/build-apk.sh )
fi
[ -f "$FRAME_APK" ] || die "frame APK not found at $FRAME_APK"
cp "$FRAME_APK" "$WORK/frame.apk"

# ---- 2. ensure the containerized apkeep image ------------------------------
if ! docker image inspect "$APKEEP_IMG" >/dev/null 2>&1; then
  log "Building apkeep container ($APKEEP_IMG)"
  docker build -t "$APKEEP_IMG" - <<EOF
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libssl3 unzip && rm -rf /var/lib/apt/lists/*
ADD https://github.com/EFForg/apkeep/releases/download/${APKEEP_VER}/apkeep-x86_64-unknown-linux-gnu /usr/local/bin/apkeep
RUN chmod +x /usr/local/bin/apkeep
EOF
fi

# ---- 3. Spotify: fetch latest xapk (apk-pure) + pick device-matching splits -
# apk-pure serves whatever variant is current, so select splits dynamically:
# base + best ABI (arm64 preferred, else v7a — the Portal+ abilist includes
# armeabi-v7a) + one density (mdpi preferred; any is accepted by manual install)
# + English.
log "Fetching Spotify (apk-pure, latest) via apkeep"
docker run --rm --network host -v "$WORK:/out" "$APKEEP_IMG" apkeep -a "$SPOTIFY_PKG" -d apk-pure /out
[ -f "$WORK/${SPOTIFY_PKG}.xapk" ] || die "apkeep did not produce ${SPOTIFY_PKG}.xapk"
mkdir -p "$WORK/spotify"
docker run --rm -v "$WORK:/out" "$APKEEP_IMG" sh -c "cd /out/spotify && unzip -o -q ../${SPOTIFY_PKG}.xapk"

pick(){ ls "$WORK"/spotify/"$1" 2>/dev/null | head -1; }      # exact name or empty
SP_BASE="$(pick "${SPOTIFY_PKG}.apk")"; [ -n "$SP_BASE" ] || SP_BASE="$(pick 'base.apk')"
SP_ABI="$(pick 'config.arm64_v8a.apk')"; [ -n "$SP_ABI" ] || SP_ABI="$(pick 'config.armeabi_v7a.apk')"
SP_DEN="$(pick 'config.mdpi.apk')"
for d in nodpi hdpi tvdpi xhdpi ldpi xxhdpi xxxhdpi; do [ -n "$SP_DEN" ] && break; SP_DEN="$(pick "config.$d.apk")"; done
SP_EN="$(pick 'config.en.apk')"
[ -n "$SP_BASE" ] && [ -n "$SP_ABI" ] || die "Spotify base/ABI split missing in xapk"
SP_SPLITS="$SP_BASE"; for s in "$SP_ABI" "$SP_DEN" "$SP_EN"; do [ -n "$s" ] && SP_SPLITS="$SP_SPLITS $s"; done
SP_NAMES=""; for s in $SP_SPLITS; do SP_NAMES="$SP_NAMES $(basename "$s")"; done
echo "   splits:$SP_NAMES"

# ---- 4. VirtualSoftKeys + HA: fetch from F-Droid's stable repo URLs ---------
# (apkeep's own F-Droid index parser is broken in v1.0.0 — the direct API+repo
# URLs are the durable path anyway.)
log "Fetching VirtualSoftKeys + Home Assistant from F-Droid"
fdroid(){ # $1 = package id -> $WORK/<pkg>.apk (latest suggested build)
  local pkg="$1" vc
  vc="$(curl -fsSL "https://f-droid.org/api/v1/packages/$pkg" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["suggestedVersionCode"])')"
  [ -n "$vc" ] || die "F-Droid: no versionCode for $pkg"
  curl -fsSL -o "$WORK/$pkg.apk" "https://f-droid.org/repo/${pkg}_${vc}.apk"
  echo "   $pkg -> vc$vc ($(stat -c%s "$WORK/$pkg.apk") bytes)"
}
fdroid "$VSK_PKG"
fdroid "$HA_PKG"

# ---- 5. push APKs to the Mac ----------------------------------------------
log "Copying APKs to the Mac"
REMOTE="/tmp/portal-provision.$$"
ssh "$MAC" "rm -rf '$REMOTE' && mkdir -p '$REMOTE/spotify'"
scp -q "$WORK/frame.apk" "$WORK/$VSK_PKG.apk" "$WORK/$HA_PKG.apk" "$MAC:$REMOTE/"
scp -q $SP_SPLITS "$MAC:$REMOTE/spotify/"

# ---- 6+7. install + appliance settings + launch (all on the Mac) -----------
# Runs as one remote script so the accessibility-list read/append happens on the
# device side and is never transported through nested quoting. CRITICAL: VSK is
# APPENDED to enabled_accessibility_services — never replace it, or the Portal's
# own presence / screen-on services get unbound and the frame stops waking.
log "Installing + applying settings on the device"
ssh "$MAC" bash -s -- \
    "$RADB" "$REMOTE" "$VSK_PKG" "$HA_PKG" "$FRAME_PKG" "$FRAME_ACT" "$VSK_A11Y" "$SP_NAMES" <<'REMOTE'
set -e
ADB="$1"; DIR="$2"; VSKPKG="$3"; HAPKG="$4"; FPKG="$5"; FACT="$6"; VSKA11Y="$7"; SPNAMES="$8"
echo "-- install"   # no '| tail' — keep adb's exit code so set -e catches a failed install
"$ADB" install -r    "$DIR/frame.apk"
"$ADB" install -r -g "$DIR/$VSKPKG.apk"
"$ADB" install -r -g "$DIR/$HAPKG.apk"
SP=""; for n in $SPNAMES; do SP="$SP $DIR/spotify/$n"; done
"$ADB" install-multiple -r -g $SP
echo "-- settings"
E="$("$ADB" shell settings get secure enabled_accessibility_services | tr -d '\r')"
case ":$E:" in
  *"$VSKPKG/"*) echo "   VSK already bound" ;;
  *null*)       "$ADB" shell settings put secure enabled_accessibility_services "$VSKA11Y" ;;
  *)            "$ADB" shell settings put secure enabled_accessibility_services "$E:$VSKA11Y" ;;
esac
"$ADB" shell settings put secure accessibility_enabled 1
"$ADB" shell appops set "$VSKPKG" SYSTEM_ALERT_WINDOW allow
# Let the frame offer its own updates (portal-immich-frame ADR-0006). Without
# this the startup check still runs and downloads, but the install prompt never
# appears — so a device provisioned without it silently stops taking updates.
# It does NOT permit silent installs; Android still asks whoever is at the device.
"$ADB" shell appops set "$FPKG" REQUEST_INSTALL_PACKAGES allow
# ...and let the install actually complete. The Portal ships NO Play/GMS, so
# nothing on the device can answer a package-verification request: the check
# times out and the installer aborts with INSTALL_FAILED_VERIFICATION_FAILURE,
# AFTER the download, the checksum and the user tapping Install (observed on the
# London Portal+ 2026-08-15). Sideloads were unaffected and hid this, because
# verifier_verify_adb_installs is already 0 — only app-initiated session installs
# go through the verifier.
"$ADB" shell settings put global package_verifier_enable 0
# ...and let the frame bring ITSELF back after an update. Android stops the app to
# replace it and never restarts it, so without this the update turns the display
# off until someone walks up to the Portal. The frame relaunches from a
# MY_PACKAGE_REPLACED receiver, which is a background activity start and needs
# this app-op on Android 10 (portal-immich-frame v0.1.10+). REQUIRED on the Sofia
# Portal Mini (Android 10); belt-and-braces on the London Portal Plus, which is
# Android 9 and predates the background-activity-start restriction.
"$ADB" shell appops set "$FPKG" SYSTEM_ALERT_WINDOW allow
"$ADB" shell settings put system screen_off_timeout 2147483647   # never sleep (LCD, always mains)
"$ADB" shell settings put secure screensaver_enabled 0           # no dream/screensaver
"$ADB" shell am start -n "$FPKG/$FACT"
echo "-- verify"   # guarded: a no-match grep must not trip the remote 'set -e'
"$ADB" shell pm list packages -3 | sed 's/^/   /' || true
"$ADB" shell dumpsys activity activities | grep -i mResumedActivity | head -1 || true
rm -rf "$DIR" || true
REMOTE

cat <<'DONE'

>> DONE (device side). Now, physically at the Portal:
   * Confirm the Immich slideshow is showing. adb screencap DOES capture it now
     (verified 2026-08-15); a black image is the older WebView-surface behaviour.
   * Confirm the VirtualSoftKeys Back/Home pills appear (your exit button).
   * Open Spotify and Home Assistant and log in (personal accounts).
DONE
