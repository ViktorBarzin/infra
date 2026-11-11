#!/bin/bash
# Tests for scripts/t3-restore-state.sh. The home base, snapshot directory and
# user map are temp dirs, the target user is whoever runs the test (so the
# ownership calls work without root), and systemctl is a stub that logs.
# Run: bash scripts/t3-restore-state.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

ME=$(id -un)
HOMES=$WORK/home
SNAPS=$WORK/snaps
CALLS=$WORK/calls
mkdir -p "$WORK/bin" "$HOMES/$ME" "$SNAPS/$ME"
printf '# comment\nsomeone=%s\n' "$ME" >"$WORK/map"

cat >"$WORK/bin/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >>"$CALLS"
[ "$1" = is-active ] && { [ "${SERVE_ACTIVE:-0}" = 1 ]; exit; }
exit 0
STUB
chmod +x "$WORK/bin/systemctl"

# db <path> <marker>: a real SQLite database holding one row, <marker>.
db() { rm -f "$1"; sqlite3 "$1" "create table t(v text); insert into t values('$2');"; }
marker() { sqlite3 "$1" 'select v from t' 2>/dev/null; }

run_restore() { # [args...] -> log, then rc=<n>
  : >"$CALLS"
  (
    export PATH="$WORK/bin:$PATH" CALLS
    export T3_HOME_BASE="$HOMES" T3_RESTORE_FROM="$SNAPS" T3_USER_MAP="$WORK/map"
    bash "$HERE/t3-restore-state.sh" "$@"
    echo "rc=$?"
  ) 2>&1
}
LIVE=$HOMES/$ME/.t3/userdata/statev2.sqlite

db "$WORK/old.sqlite" "older"; gzip -c "$WORK/old.sqlite" >"$SNAPS/$ME/state-20261110-033652.sqlite.gz"
db "$SNAPS/$ME/state-20261111-034710.sqlite" "newest"
db "$SNAPS/$ME/state-prebump-0.1.9-20261112-040000.sqlite" "prebump"

# --- a fresh home: the newest daily snapshot goes in ---------------------------
out=$(run_restore --if-missing "$ME")
[ "$(marker "$LIVE")" = newest ] && ok "the newest daily snapshot becomes statev2.sqlite" || bad "fresh: $out"
[ "$(stat -c %U "$LIVE")" = "$ME" ] && [ "$(stat -c %a "$LIVE")" = 600 ] \
  && ok "the restored database belongs to the user, mode 600" || bad "owner: $(stat -c '%U %a' "$LIVE")"
[ "$(stat -c %a "$HOMES/$ME/.t3/userdata")" = 700 ] && ok "a missing ~/.t3/userdata is created 700" || bad "dir mode"
[ "$(tail -1 <<<"$out")" = rc=0 ] && ok "a restore exits 0" || bad "rc: $out"
grep -q 'systemctl start' "$CALLS" && bad "started a serve that was not running" || ok "a serve that was not running stays stopped"

# --- --if-missing never touches a database that is there ------------------------
db "$LIVE" "live work"
out=$(run_restore --if-missing "$ME")
[ "$(marker "$LIVE")" = "live work" ] && ok "--if-missing leaves an existing database alone" || bad "if-missing: $out"
rm -f "$LIVE"; db "$HOMES/$ME/.t3/userdata/state.sqlite" "pre-0.1.0"
out=$(run_restore --if-missing "$ME")
[ -e "$LIVE" ] && bad "--if-missing restored over a pre-0.1.0 state.sqlite" || ok "--if-missing also counts an old state.sqlite as there"
rm -f "$HOMES/$ME/.t3/userdata/state.sqlite"

# --- an explicit restore keeps the database it replaces ---------------------------
db "$LIVE" "live work"; echo wal >"$LIVE-wal"
out=$(SERVE_ACTIVE=1 run_restore "$ME")
[ "$(marker "$LIVE")" = newest ] && ok "an explicit restore replaces the live database" || bad "explicit: $out"
aside=$(find "$HOMES/$ME/.t3/userdata" -name 'statev2.sqlite.before-restore-*' ! -name '*-wal' | head -1)
# The WAL check comes first: opening the aside copy lets sqlite3 consume it.
[ -n "$aside" ] && [ -e "$aside-wal" ] && [ "$(marker "$aside")" = "live work" ] \
  && ok "the replaced database and its WAL are kept beside it" || bad "aside: $(ls -a "$HOMES/$ME/.t3/userdata")"
[ -e "$LIVE-wal" ] && bad "left the old WAL next to the restored database" || ok "no stale WAL is left on the restored database"
grep -n 'systemctl' "$CALLS" | grep -q "stop t3-serve@$ME" && grep -q "start t3-serve@$ME" "$CALLS" \
  && [ "$(grep -n "stop t3-serve" "$CALLS" | cut -d: -f1)" -lt "$(grep -n "start t3-serve" "$CALLS" | cut -d: -f1)" ] \
  && ok "a running serve is stopped for the swap and started again" || bad "serve: $(cat "$CALLS")"

# --- --snapshot picks a given file; .gz works ----------------------------------------
out=$(run_restore --snapshot "$SNAPS/$ME/state-20261110-033652.sqlite.gz" "$ME")
[ "$(marker "$LIVE")" = older ] && ok "--snapshot restores the named file, gzipped or not" || bad "snapshot: $out"

# --- --dry-run changes nothing ------------------------------------------------------
before=$(sha256sum "$LIVE")
out=$(run_restore --dry-run "$ME")
[ "$(sha256sum "$LIVE")" = "$before" ] && grep -q 'state-20261111-034710.sqlite' <<<"$out" \
  && ok "--dry-run names the snapshot and changes nothing" || bad "dry-run: $out"

# --- a damaged snapshot is refused --------------------------------------------------
printf 'SQLite format 3\000garbage' >"$SNAPS/$ME/state-20261112-034000.sqlite"
before=$(sha256sum "$LIVE")
out=$(run_restore "$ME")
[ "$(sha256sum "$LIVE")" = "$before" ] && [ "$(tail -1 <<<"$out")" = rc=1 ] \
  && ok "a snapshot that fails quick_check is refused and the live database kept" || bad "damaged: $out"
grep -q 'stop' "$CALLS" && bad "stopped the serve for a refused snapshot" || ok "a refused snapshot never stops the serve"
compgen -G "$HOMES/$ME/.t3/userdata/.restore*" >/dev/null && bad "left a temp file" || ok "no temp file is left behind"
rm "$SNAPS/$ME/state-20261112-034000.sqlite"

# --- nothing to restore ---------------------------------------------------------------
rm -rf "${SNAPS:?}/$ME"
rm -f "$LIVE"
out=$(run_restore --if-missing "$ME")
[ "$(tail -1 <<<"$out")" = rc=0 ] && [ ! -e "$LIVE" ] && ok "--if-missing with no snapshot is a quiet no-op" || bad "no snap if-missing: $out"
out=$(run_restore "$ME")
[ "$(tail -1 <<<"$out")" = rc=1 ] && ok "an explicit restore with no snapshot fails" || bad "no snap explicit: $out"

# --- --all walks the user map -----------------------------------------------------------
mkdir -p "$SNAPS/$ME"; db "$SNAPS/$ME/state-20261111-034710.sqlite" "newest"
out=$(run_restore --all --if-missing)
[ "$(marker "$LIVE")" = newest ] && ok "--all restores every mapped user" || bad "all: $out"

out=$(run_restore nosuchuser-xyz)
[ "$(tail -1 <<<"$out")" = rc=1 ] && ok "an unknown user fails" || bad "unknown: $out"

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
