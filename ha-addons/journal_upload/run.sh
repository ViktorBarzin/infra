#!/bin/sh
# Points the HAOS host's own systemd-journal-upload at the homelab receiver and
# keeps it running. The uploader is the host's binary under its stock hardened
# unit; this add-on only writes a runtime drop-in (HAOS /etc is read-only, /run
# is tmpfs, so the drop-in is rewritten at every start) and watches the unit.
# Stopping the add-on stops the upload and removes the drop-in.
set -eu
. /app/lib.sh

OPTIONS=/data/options.json
UNIT=systemd-journal-upload.service
DROPIN_DIR=/run/systemd/system/$UNIT.d
DROPIN=$DROPIN_DIR/50-homelab.conf
STATE=/var/lib/systemd/journal-upload/state

host() { nsenter -t 1 -m -- "$@"; }
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

url=$(option_url "$OPTIONS")
if ! valid_url "$url"; then
  log "url option '$url' is not an http(s) URL without spaces or quotes"
  exit 1
fi

install_dropin() {
  render_dropin "$url" "${1:-}" | host sh -c "mkdir -p '$DROPIN_DIR' && cat > '$DROPIN'"
  host systemctl daemon-reload
}

start_unit() {
  host systemctl reset-failed "$UNIT" 2>/dev/null || true
  host systemctl restart "$UNIT"
}

cleanup() {
  log "add-on stopping: stopping the uploader and removing the drop-in"
  host systemctl stop "$UNIT" || true
  host rm -f "$DROPIN"
  host systemctl daemon-reload || true
  exit 0
}
trap cleanup TERM INT

# The uploader saves its cursor in $STATE after every batch. With no state yet
# (first install), start from the first entry of the current boot rather than
# the whole 500 MB journal.
cursor=""
if ! host test -s "$STATE"; then
  cursor=$(host journalctl -b -o json --no-pager 2>/dev/null | first_cursor)
fi
install_dropin "$cursor"
start_unit
log "uploading the journal to $url${cursor:+ (first run: from the start of this boot)}"

while true; do
  sleep 60 &
  wait $! || true
  if [ -n "$cursor" ] && host test -s "$STATE"; then
    cursor=""
    install_dropin ""
    log "cursor saved; later restarts resume from it"
  fi
  if ! host systemctl is-active --quiet "$UNIT"; then
    log "uploader not active, restarting it"
    start_unit || log "restart failed: $(host systemctl is-active "$UNIT" || true)"
  fi
done
