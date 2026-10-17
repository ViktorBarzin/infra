#!/usr/bin/env bash
# Graceful stop for iVMS-4200, run by the wine-app entrypoint on SIGTERM (and
# after install) before its generic wineboot shutdown. WatchDog.exe restarts
# the server processes when they exit, so it goes first; the rest get a close
# message (taskkill without /f) so they can flush their data files.
set -u
tk() { timeout 15 wine taskkill "$@" >/dev/null 2>&1 || true; }
running() { pgrep -f "[${1:0:1}]${1:1}" >/dev/null; }
wait_gone() { for _ in $(seq "$2"); do running "$1" || return 0; sleep 1; done; return 1; }

tk /f /im WatchDog.exe
tk /im iVMS-4200.Framework.C.exe
wait_gone iVMS-4200.Framework.C.exe 8 || tk /f /im iVMS-4200.Framework.C.exe
for s in DeviceManagement AccessController PersonalManagement Attendance AlarmCenter; do
  tk /im "iVMS-4200.$s.S.exe"
done
tk /im iVMS-4200.Framework.S.exe
wait_gone 'iVMS-4200.*\.S\.exe' 15 || echo "pre-stop: iVMS servers still running, leaving them to wineboot" >&2
exit 0
