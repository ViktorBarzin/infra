#!/usr/bin/env bash
# Scripted GUI install of Hikvision iVMS-4200 V3 (client components only),
# called by the wine-app entrypoint as: install.sh <installer.exe>
# with DISPLAY and WINEPREFIX set and no window manager running.
#
# The installer is a Qt bootstrapper that ignores silent-install flags, so this
# drives its windows with xdotool. Its windows have no titles; they are found
# by WM_CLASS (the lower-cased installer file name) and size, and every click
# is relative to the window it targets. Coordinates were measured against
# iVMS-4200V3.14.1.4_E.exe on 2026-10-17; a new installer version that moves
# a button makes the matching step fail with a screenshot in the log.
set -euo pipefail
. /usr/local/bin/wine-app-lib.sh

INSTALLER=${1:?usage: install.sh <installer.exe>}
CLASS=$(basename "$INSTALLER" | tr '[:upper:]' '[:lower:]')
DRIVE_C="$WINEPREFIX/drive_c"
IVMS_DIR="$DRIVE_C/Program Files (x86)/iVMS-4200 Site/iVMS-4200 Client"

wa_log "starting $INSTALLER (window class $CLASS)"
wine "$INSTALLER" >/tmp/ivms-installer.log 2>&1 &
INSTALLER_PID=$!

alive() { kill -0 "$INSTALLER_PID" 2>/dev/null; }

# 1. Licence page (720x520): tick "I agree", then Next.
W1=$(wa_wait_window 300 "$CLASS" 720 520) || wa_fail "licence page did not appear within 300s"
wa_wait_stable 30 "$W1" || wa_fail "licence page kept repainting"
# Re-running an installer whose version is already installed opens a
# "installation maintenance" page in the same window instead, with Modify /
# Repair / Remove radios and Remove pre-selected (red dot at 55,440). Never
# press anything there.
px=$(wa_pixel "$W1" 55 440 || true)
if [ -n "$px" ] && [ $((16#${px:1:2})) -gt 180 ] && [ $((16#${px:3:2})) -lt 90 ]; then
  wa_fail "installer opened its maintenance page (Modify/Repair/Remove): this iVMS version is already installed in the prefix. Not touching it."
fi
wa_log "licence page: window $W1"
wa_click "$W1" 55 418 10     # agree checkbox
wa_click "$W1" 647 487       # Next

# 2. Component page (720x550, a new window). The default selection is the
#    client modules; this installer build offers no server or HikCentral
#    components here. Click Install.
W2=$(wa_wait_window 60 "$CLASS" 720 550) || wa_fail "component page did not appear within 60s"
wa_wait_stable 30 "$W2" || wa_fail "component page kept repainting"
wa_log "component page: window $W2"
wa_click "$W2" 657 522       # Install

# 3. Progress. The bundled Web Components setup fails to register its browser
#    plugin (WebVideoActiveX.ocx needs MFC42) and shows an "Error" box with
#    Abort/Retry/Ignore. The plugin is for web browsers only: Ignore it.
#    The finish page is another 720x520 window with a green tick at (267,320).
deadline=$((SECONDS + 1800))
FINISH=""
while [ $SECONDS -lt $deadline ]; do
  alive || wa_fail "installer exited before the finish page"
  err=$(timeout 10 xdotool search --onlyvisible --name '^Error$' 2>/dev/null | head -1 || true)
  if [ -n "$err" ]; then
    wa_log "error dialog $err (WebVideoActiveX.ocx registration): pressing Ignore"
    wa_screenshot ivms-ocx-error >/dev/null 2>&1 || true
    wa_click "$err" 260 146
    sleep 2
    continue
  fi
  for id in $(wa_list_windows | awk -v c="$CLASS" '$6==c && $4==720 && $5==520 {print $1}'); do
    [ "$id" = "$W1" ] && continue
    px=$(wa_pixel "$id" 267 320 || true)
    # green tick, about #34D14E
    if [ -n "$px" ] && [ $((16#${px:3:2})) -gt 150 ] && [ $((16#${px:1:2})) -lt 120 ]; then
      FINISH=$id
      break 2
    fi
  done
  sleep 3
done
[ -n "$FINISH" ] || wa_fail "finish page did not appear within 30 minutes"
wa_log "finish page: window $FINISH"
wa_wait_stable 30 "$FINISH" || true

# 4. Untick both post-install options (launch the client, open the readme)
#    and press Finish. The entrypoint starts the client itself.
wa_click "$FINISH" 55 362 5
wa_click "$FINISH" 55 412 5
wa_click "$FINISH" 631 480
for _ in $(seq 120); do alive || break; sleep 1; done
alive && wa_fail "installer still running 120s after Finish"
wait "$INSTALLER_PID" || wa_log "installer exit status $? (ignored; files are checked below)"

# 5. Assert the result.
for f in \
  "$IVMS_DIR/Client/iVMS-4200.Framework.C.exe" \
  "$IVMS_DIR/Server/iVMS-4200.Framework.S.exe" \
  "$IVMS_DIR/Server/WatchDog.exe" \
  "$DRIVE_C/users/Public/iVMS-4200 Site/Nginx/conf/nginx.conf"; do
  [ -f "$f" ] || wa_fail "missing after install: $f"
done
grep -aq '"DisplayName"="iVMS-4200' "$WINEPREFIX/system.reg" \
  || wa_fail "no iVMS-4200 uninstall registration in system.reg"
wa_log "iVMS-4200 installed: $(du -sh "$IVMS_DIR" | cut -f1) in $IVMS_DIR"
