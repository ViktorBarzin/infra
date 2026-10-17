#!/usr/bin/env bash
# wine-app entrypoint: virtual display + noVNC, first-start/upgrade install of
# the app described in /app, then run and supervise it. Contract: README.md.
set -euo pipefail

log() { echo "[wine-app $(date +%H:%M:%S)] $*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# Containerd hands out a huge RLIMIT_NOFILE; x11vnc sweeps the whole fd table
# on every connect and stalls for minutes. Lowering is always permitted.
ulimit -n 65536 2>/dev/null || true

# --- app contract -----------------------------------------------------------
[ -r /app/app.env ] || die "/app/app.env not found (mount the app ConfigMap at /app)"
set -a
# shellcheck disable=SC1091
. /app/app.env
set +a
for v in APP_NAME APP_VERSION APP_INSTALLER_URL APP_INSTALLER_SHA256 APP_LAUNCH APP_READY_WINDOW; do
  [ -n "${!v:-}" ] || die "$v is not set in /app/app.env"
done
[ -r /app/install.sh ] || die "/app/install.sh not found"
APP_WINETRICKS=${APP_WINETRICKS:-}
APP_SERVICES_WAIT=${APP_SERVICES_WAIT:-0}
SCREEN_GEOMETRY=${SCREEN_GEOMETRY:-1600x900x24}

export WINEPREFIX=/data/prefix DISPLAY=:0
MARKER="/data/.installed-${APP_NAME}-${APP_VERSION}"
STATE=/tmp/wine-app-state   # starting | installing | running | stopping

# Idle signals for the sleeper. Touched once now so a fresh pod starts with a
# full grace period.
touch /tmp/last-viewer
echo 0 > /tmp/input-idle-ms
echo starting > "$STATE"

PIDS=()
CLIENT_LOOP=""

# --- shutdown ---------------------------------------------------------------
# Order: stop restarting the client, let the app close itself (/app/pre-stop.sh),
# end the Wine session, then kill whatever is left. Fits in ~45s.
wine_stop() {
  if [ -x /app/pre-stop.sh ] && pgrep -x wineserver >/dev/null; then
    timeout 25 /app/pre-stop.sh || log "pre-stop.sh exited $?"
  fi
  if pgrep -x wineserver >/dev/null; then
    timeout 10 wineboot --end-session --force --shutdown >/dev/null 2>&1 || true
    timeout 5 wineserver -w 2>/dev/null || true
    wineserver -k 2>/dev/null || true
  fi
}

# stop_all <exit-code> <reason>
stop_all() {
  trap - TERM INT
  echo stopping > "$STATE"
  log "$2: shutting down"
  if [ -n "$CLIENT_LOOP" ]; then kill "$CLIENT_LOOP" 2>/dev/null || true; fi
  wine_stop
  kill "${PIDS[@]}" 2>/dev/null || true
  log "stopped"
  exit "$1"
}
trap 'stop_all 0 SIGTERM' TERM INT

# --- display and remote viewing ---------------------------------------------
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0
Xvfb :0 -screen 0 "$SCREEN_GEOMETRY" -nolisten tcp &
PIDS+=($!)
for _ in $(seq 50); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.2; done
xdpyinfo >/dev/null 2>&1 || die "Xvfb did not start"

x11vnc -display :0 -rfbport 5900 -localhost -nopw -forever -shared -quiet -nolookup -noxdamage &
PIDS+=($!)
websockify --web /usr/share/novnc 0.0.0.0:6080 127.0.0.1:5900 &
PIDS+=($!)

# Idle signals: viewers = established connections to x11vnc on :5900 (noVNC's
# websockify connects there once per browser; probes and Traefik keep-alives
# only ever touch :6080). Input idle time comes from the X server.
(
  while true; do
    if [ "$(ss -Htn state established '( sport = :5900 )' 2>/dev/null | wc -l)" -gt 0 ]; then
      touch /tmp/last-viewer
    fi
    xprintidle > /tmp/input-idle-ms.tmp 2>/dev/null && mv /tmp/input-idle-ms.tmp /tmp/input-idle-ms
    sleep 30
  done
) &
PIDS+=($!)

# --- install / upgrade --------------------------------------------------------
download_installer() {
  local dir=/data/.download name f
  name=$(basename "${APP_INSTALLER_URL%%\?*}")
  f="$dir/$name"
  mkdir -p "$dir"
  if ! echo "${APP_INSTALLER_SHA256}  $f" | sha256sum -c --status - 2>/dev/null; then
    rm -f "$dir"/*
    log "downloading $APP_INSTALLER_URL"
    local referer=()
    [ -n "${APP_INSTALLER_REFERER:-}" ] && referer=(-e "$APP_INSTALLER_REFERER")
    curl -fsSL --retry 3 -A 'Mozilla/5.0' "${referer[@]}" -o "$f.part" "$APP_INSTALLER_URL" >&2
    mv "$f.part" "$f"
  fi
  # sha256 is the hard gate.
  echo "${APP_INSTALLER_SHA256}  $f" | sha256sum -c - >&2 || { rm -f "$f"; die "installer sha256 mismatch"; }
  # Authenticode is advisory: logged, never fatal, so unsigned installers work.
  if file -b "$f" | grep -q '^PE32'; then
    if osslsigncode verify -in "$f" > /tmp/authenticode.txt 2>&1; then
      log "authenticode OK: $(grep -m1 'Subject:' /tmp/authenticode.txt | sed 's/^[[:space:]]*//')"
    else
      log "authenticode check did not pass (advisory): $(tail -1 /tmp/authenticode.txt)"
    fi
  fi
  echo "$f"
}

install_app() {
  local mode installer t0=$SECONDS
  if compgen -G "/data/.installed-${APP_NAME}-*" >/dev/null && [ -f "$WINEPREFIX/system.reg" ]; then
    mode=upgrade   # an earlier version is installed: install over the prefix
  else
    mode=fresh     # nothing completed yet: start from an empty prefix
  fi
  log "installing ${APP_NAME} ${APP_VERSION} (${mode})"
  echo installing > "$STATE"
  installer=$(download_installer) || die "installer download/verification failed"

  if [ "$mode" = fresh ]; then
    rm -rf "$WINEPREFIX"
    # The first wineboot of a prefix must not see the X display: under X it
    # failed with "could not load kernel32.dll" (2026-10-17).
    env -u DISPLAY wineboot -i >/dev/null 2>&1 || die "wineboot -i failed"
    wineserver -w
  fi
  if [ -n "$APP_WINETRICKS" ]; then
    # shellcheck disable=SC2086
    winetricks -q $APP_WINETRICKS >/tmp/winetricks.log 2>&1 || { tail -20 /tmp/winetricks.log >&2; die "winetricks $APP_WINETRICKS failed"; }
  fi

  bash /app/install.sh "$installer" || die "/app/install.sh failed (exit $?)"
  wine_stop

  rm -f /data/.installed-"${APP_NAME}"-*
  date -u +%FT%TZ > "$MARKER"
  rm -rf /data/.download
  log "installed ${APP_NAME} ${APP_VERSION} in $((SECONDS - t0))s"
}

# A SIGTERM during the install is handled once the current step returns; if
# the pod is killed first, the missing marker makes the next start retry.
if [ ! -f "$MARKER" ]; then
  install_app
  # Start over from a clean boot, the same path every later start takes. On
  # 2026-10-17 an iVMS super user created in the same container run as the
  # install was never written to disk, while one created after a restart was.
  log "restarting the entrypoint after install"
  trap - TERM INT
  kill "${PIDS[@]}" 2>/dev/null || true
  wait 2>/dev/null || true
  exec "$0" "$@"
fi

# --- run ----------------------------------------------------------------------
openbox >/dev/null 2>&1 &
PIDS+=($!)

# A persistent wineserver: if it (or services.exe) goes away, the prefix is in
# trouble and the pod should restart rather than limp on.
wineserver -p
wineboot >/dev/null 2>&1 || log "wineboot exited $? (continuing)"
[ "$APP_SERVICES_WAIT" -gt 0 ] && sleep "$APP_SERVICES_WAIT"

# The client: restarted a few seconds after it exits, because users close the
# window by accident.
(
  trap 'exit 0' TERM
  while true; do
    log "launching $APP_LAUNCH"
    wine "$APP_LAUNCH" >/tmp/app.log 2>&1 || true
    log "app exited; restarting in 5s"
    sleep 5
  done
) &
CLIENT_LOOP=$!
echo running > "$STATE"

# Optional app hook, in the background once the app is launching (e.g. to
# dismiss a first-screen dialog).
if [ -x /app/post-start.sh ]; then
  ( /app/post-start.sh || log "post-start.sh exited $?" ) &
fi

# --- supervise -----------------------------------------------------------------
while true; do
  sleep 5 &
  wait $! || true
  for i in "${!PIDS[@]}"; do
    kill -0 "${PIDS[$i]}" 2>/dev/null || stop_all 1 "process ${PIDS[$i]} exited"
  done
  pgrep -x wineserver >/dev/null || stop_all 1 "wineserver died"
  pgrep -f '[C]:\\windows\\system32\\services.exe' >/dev/null || stop_all 1 "services.exe died"
done
