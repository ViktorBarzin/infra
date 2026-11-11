#!/usr/bin/env bash
# t3-restore-state — put a user's newest T3 snapshot back as their live
# ~/.t3/userdata/statev2.sqlite (threads, projects, paired sessions).
# Deploy to the devvm at /usr/local/bin/t3-restore-state (playbooks/devvm.yml).
#
#   t3-restore-state [--if-missing] [--dry-run] [--snapshot FILE] <user>|--all
#
# The snapshot is the newest daily state-YYYYMMDD-HHMMSS.sqlite[.gz] under
# /var/backups/t3-state/<user>/ (T3_RESTORE_FROM), the directory
# t3-backup-state writes and the PVE host's t3-state-pull copies from. On a
# rebuilt devvm, copy the host's /mnt/backup/t3-state/ back into it first
# (docs/architecture/backup-dr.md, "T3 snapshots").
#
# --if-missing  restore only when the user has no state DB at all. This is the
#               form t3-provision-users calls before it starts t3-serve@<user>,
#               so a live database is never replaced by an automatic run.
# Without it, the live database (and its -wal/-shm) is moved aside to
# statev2.sqlite.before-restore-<ts>, never deleted, and a running
# t3-serve@<user> is stopped for the swap and started again.
#
# A snapshot must pass `PRAGMA quick_check` before anything is stopped or
# moved. Tests: scripts/t3-restore-state.test.sh.
set -uo pipefail

FROM="${T3_RESTORE_FROM:-/var/backups/t3-state}"
HOME_BASE="${T3_HOME_BASE:-/home}"
USER_MAP="${T3_USER_MAP:-/etc/ttyd-user-map}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"

log() { echo "t3-restore-state: $*"; logger -t t3-restore-state "$*" 2>/dev/null || true; }
die() { log "ERROR: $*"; return 1; }

IF_MISSING=0 DRY_RUN=0 ALL=0 SNAPSHOT="" TARGET=""
usage() { echo "usage: t3-restore-state [--if-missing] [--dry-run] [--snapshot FILE] <user>|--all" >&2; exit 64; }
while [ $# -gt 0 ]; do
  case "$1" in
    --if-missing) IF_MISSING=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --all) ALL=1 ;;
    --snapshot) [ $# -ge 2 ] || usage; SNAPSHOT=$2; shift ;;
    -*) usage ;;
    *) [ -z "$TARGET" ] || usage; TARGET=$1 ;;
  esac
  shift
done
{ [ "$ALL" = 1 ] && [ -z "$TARGET" ] && [ -z "$SNAPSHOT" ]; } || { [ "$ALL" = 0 ] && [ -n "$TARGET" ]; } || usage

# newest_snapshot <user> -> path of the newest daily snapshot, or nothing
newest_snapshot() {
  local f
  f=$(find "$FROM/$1" -maxdepth 1 -type f -regextype posix-extended \
    -regex '.*/state-[0-9]{8}-[0-9]{6}\.sqlite(\.gz)?' -printf '%f\n' 2>/dev/null | sort | tail -1)
  [ -z "$f" ] || echo "$FROM/$1/$f"
}

restore_user() {
  local u=$1 snap home data live group tmp ts was_active=0
  id "$u" >/dev/null 2>&1 || { die "$u: no such user"; return; }
  home="$HOME_BASE/$u"
  [ -d "$home" ] || { die "$u: no home directory at $home"; return; }
  data="$home/.t3/userdata"
  live="$data/statev2.sqlite"
  group=$(id -gn "$u")

  if [ "$IF_MISSING" = 1 ] && { [ -e "$live" ] || [ -e "$data/state.sqlite" ]; }; then
    log "$u already has a T3 database; leaving it"
    return 0
  fi
  snap=${SNAPSHOT:-$(newest_snapshot "$u")}
  if [ -z "$snap" ]; then
    [ "$IF_MISSING" = 1 ] && { log "$u: no snapshot in $FROM/$u; nothing to restore"; return 0; }
    die "$u: no snapshot in $FROM/$u"; return
  fi
  [ -f "$snap" ] || { die "$u: $snap does not exist"; return; }
  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] would restore $snap -> $live$([ -e "$live" ] && echo ", moving the current one aside")"
    return 0
  fi

  install -d -o "$u" -g "$group" -m 0700 "$home/.t3" "$data" || { die "$u: cannot create $data"; return; }
  tmp="$data/.restore-$$.sqlite"
  if [[ $snap == *.gz ]]; then gzip -dc "$snap" >"$tmp"; else cp "$snap" "$tmp"; fi || {
    rm -f "$tmp"; die "$u: cannot read $snap"; return; }
  if [ "$(sqlite3 "$tmp" 'PRAGMA quick_check;' 2>&1)" != ok ]; then
    rm -f "$tmp" "$tmp-journal"; die "$u: $snap fails quick_check; live database left as it is"; return
  fi
  chown "$u:$group" "$tmp" && chmod 0600 "$tmp"

  if $SYSTEMCTL is-active --quiet "t3-serve@$u.service"; then
    was_active=1
    $SYSTEMCTL stop "t3-serve@$u.service" || { rm -f "$tmp"; die "$u: could not stop t3-serve@$u"; return; }
  fi
  if [ -e "$live" ]; then
    ts=$(date +%Y%m%d-%H%M%S)
    mv "$live" "$live.before-restore-$ts"
    for side in wal shm; do [ -e "$live-$side" ] && mv "$live-$side" "$live.before-restore-$ts-$side"; done
    log "$u: kept the replaced database as $live.before-restore-$ts"
  fi
  rm -f "$live-wal" "$live-shm"
  mv "$tmp" "$live"
  log "$u: restored $snap -> $live"
  if [ "$was_active" = 1 ]; then
    $SYSTEMCTL start "t3-serve@$u.service" || log "WARN: $u: t3-serve@$u did not start; check journalctl -u t3-serve@$u"
  fi
  return 0
}

rc=0
if [ "$ALL" = 1 ]; then
  while read -r u; do
    restore_user "$u" || rc=1
  done < <(awk -F= '!/^[[:space:]]*#/ && NF==2 { gsub(/[[:space:]]/,"",$2); print $2 }' "$USER_MAP" 2>/dev/null | sort -u)
else
  restore_user "$TARGET" || rc=1
fi
exit "$rc"
