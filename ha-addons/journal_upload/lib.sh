# Helpers for run.sh, kept free of side effects so test_lib.sh can test them.

# The systemd drop-in that points the host's stock systemd-journal-upload unit
# at our receiver. DynamicUser=no + the static systemd-journal-upload user,
# because HAOS keeps /var/lib/private on tmpfs: with a dynamic user the cursor
# state would vanish at every reboot. StateDirectory (systemd/journal-upload)
# then lands in /var/lib/systemd, which HAOS persists. The uploader rewrites
# its cursor after every batch (every few seconds), so it saves to a RAM file
# that run.sh copies to the card hourly and at stop.
# $1 = receiver URL, $2 = cursor file, $3 = optional cursor to start from
# (first run only).
render_dropin() {
  cursor=""
  [ -n "${3:-}" ] && cursor=" --cursor=\"$3\""
  printf '%s\n' \
    '[Service]' \
    'DynamicUser=no' \
    'User=systemd-journal-upload' \
    'ExecStart=' \
    "ExecStart=/usr/lib/systemd/systemd-journal-upload --save-state=$2 -u $1$cursor"
}

# The journald drop-in that caps the RAM journal. The add-on keeps the host's
# journal in RAM (journalctl --relinquish-var) so the SD card is not written
# for every log line; Loki holds the logs. RuntimeMaxUse is the RAM buffer
# that covers a receiver outage: the journal grows ~11 MB/day on ha-london.
# $1 = size, e.g. 48M.
render_journald_dropin() {
  printf '%s\n' '[Journal]' "RuntimeMaxUse=$1"
}

# The url option from the add-on's options.json, empty when unset.
option_url() { jq -r '.url // empty' "$1"; }

# The __CURSOR of the first JSON journal entry on stdin, empty when none.
first_cursor() { head -n 1 | jq -r '.__CURSOR // empty' 2>/dev/null || true; }

# A URL we are willing to paste into a unit file: http(s), no spaces or quotes.
valid_url() {
  case "$1" in
    http://*|https://*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[[:space:]\"\'\;\\%\$\`]*) return 1 ;;
  esac
  return 0
}
