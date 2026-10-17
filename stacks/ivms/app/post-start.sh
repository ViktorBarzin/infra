#!/usr/bin/env bash
# iVMS asks "Upgrade Detection: ... Enable?" on every client start, and the
# answer does not stick. Answer Disable so nobody enables automatic device
# firmware pushes by accident. Runs in the background after launch.
set -u
. /usr/local/bin/wine-app-lib.sh
for _ in $(seq 180); do
  d=$(timeout 10 xdotool search --onlyvisible --name '^Upgrade Detection$' 2>/dev/null | head -1)
  if [ -n "$d" ]; then
    sleep 1
    wa_click "$d" 307 196   # Disable
    wa_log "dismissed Upgrade Detection (Disable)"
    exit 0
  fi
  sleep 1
done
exit 0
