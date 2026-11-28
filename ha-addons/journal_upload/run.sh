#!/bin/sh
# Points the HAOS host's own systemd-journal-upload at the homelab receiver and
# keeps it running. The uploader is the host's binary under its stock hardened
# unit; this add-on only writes a runtime drop-in (HAOS /etc is read-only, /run
# is tmpfs, so the drop-in is rewritten at every start) and watches the unit.
# It also keeps the host's journal in RAM instead of on the SD card: Loki has
# the logs, and the card copy cost ~0.5 GB/day of writes. At stop (a clean
# reboot stops add-ons first) the RAM journal is written to the card, so the
# logs of a network outage survive the Wi-Fi watchdog's reboot.
# Stopping the add-on stops the upload, removes the drop-ins and puts the
# journal back on the card.
set -eu
. /app/lib.sh

OPTIONS=/data/options.json
UNIT=systemd-journal-upload.service
DROPIN_DIR=/run/systemd/system/$UNIT.d
DROPIN=$DROPIN_DIR/50-homelab.conf
STATE=/var/lib/systemd/journal-upload/state
JOURNALD_DIR=/run/systemd/journald.conf.d
JOURNALD_DROPIN=$JOURNALD_DIR/50-homelab.conf
# journald removes this flag when it writes to RAM and sets it on a flush.
FLUSHED=/run/systemd/journal/flushed
RAM_JOURNAL=48M

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

# Journal to RAM. Relinquish first so the restart (needed to read the new
# RuntimeMaxUse) opens the RAM journal, not the card one.
journal_to_ram() {
  want=$(render_journald_dropin "$RAM_JOURNAL")
  have=$(host cat "$JOURNALD_DROPIN" 2>/dev/null || true)
  host journalctl --relinquish-var
  if [ "$want" != "$have" ]; then
    printf '%s\n' "$want" | host sh -c "mkdir -p '$JOURNALD_DIR' && cat > '$JOURNALD_DROPIN'"
    host systemctl restart systemd-journald
  fi
}

cleanup() {
  log "add-on stopping: stopping the uploader, writing the RAM journal to the card"
  host systemctl stop "$UNIT" || true
  host rm -f "$DROPIN" "$JOURNALD_DROPIN"
  host systemctl daemon-reload || true
  host journalctl --flush || log "journal flush failed"
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
journal_to_ram || log "could not move the journal to RAM; it stays on the card"
log "journal kept in RAM (up to $RAM_JOURNAL), written to the card when the add-on stops"

while true; do
  sleep 60 &
  wait $! || true
  if [ -n "$cursor" ] && host test -s "$STATE"; then
    cursor=""
    install_dropin ""
    log "cursor saved; later restarts resume from it"
  fi
  if host test -e "$FLUSHED"; then
    log "journal was flushed to the card; moving it back to RAM"
    host journalctl --relinquish-var || log "relinquish failed"
  fi
  if ! host systemctl is-active --quiet "$UNIT"; then
    log "uploader not active, restarting it"
    start_unit || log "restart failed: $(host systemctl is-active "$UNIT" || true)"
  fi
done
