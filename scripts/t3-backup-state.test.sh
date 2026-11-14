#!/bin/bash
# Tests for scripts/t3-backup-state.sh. The home base, backup directory and
# user map are temp dirs, the user is whoever runs the test (so the ownership
# calls work without root), runuser is a stub that runs the command, and
# sqlite3 is a wrapper that logs the VACUUM INTO target before running the
# real sqlite3 (or failing, when SQLITE_FAIL=1).
#
# The regression this guards: on 2026-11-12 devvm-cleanup gzipped a copy that
# was still being written, because it compresses every *.sqlite in the backup
# directory but the newest and a pre-bump snapshot was being written at the
# same time. A copy in progress must never carry a name that devvm-cleanup,
# retention or t3-restore-state match.
# Run: bash scripts/t3-backup-state.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

ME=$(id -un)
HOMES=$WORK/home
DEST=$WORK/backups
TARGETS=$WORK/targets
REAL_SQLITE=$(command -v sqlite3)
mkdir -p "$WORK/bin" "$HOMES/$ME/.t3/userdata"
printf '# comment\nsomeone=%s\n' "$ME" >"$WORK/map"
"$REAL_SQLITE" "$HOMES/$ME/.t3/userdata/statev2.sqlite" \
  "CREATE TABLE t(x); INSERT INTO t VALUES (1),(2),(3);"

cat >"$WORK/bin/runuser" <<'STUB'
#!/bin/bash
[ "$1" = -u ] && shift 2
[ "$1" = -- ] && shift
exec "$@"
STUB
cat >"$WORK/bin/sqlite3" <<STUB
#!/bin/bash
# Log the VACUUM INTO target, and the snapshot names visible mid-copy.
t=\$(printf '%s' "\$2" | sed -n "s/^VACUUM INTO '\\(.*\\)'\$/\\1/p")
[ -n "\$t" ] && echo "\$t" >>"$TARGETS"
if [ "\${SQLITE_FAIL:-0}" = 1 ]; then
  [ -n "\$t" ] && echo partial >"\$t"
  exit 1
fi
exec "$REAL_SQLITE" "\$@"
STUB
chmod +x "$WORK/bin/runuser" "$WORK/bin/sqlite3"

run() {
  PATH="$WORK/bin:$PATH" T3_HOME_BASE=$HOMES T3_BACKUP_DEST=$DEST \
    T3_USER_MAP=$WORK/map bash "$HERE/t3-backup-state.sh" >"$WORK/out" 2>&1
}

# 1. A successful run leaves one complete daily snapshot and no temp file.
: >"$TARGETS"
if run; then ok "run exits 0"; else bad "run exits 0: $(cat "$WORK/out")"; fi
mapfile -t snaps < <(find "$DEST/$ME" -maxdepth 1 -name 'state-*.sqlite')
if [ "${#snaps[@]}" = 1 ] && [[ $(basename "${snaps[0]}") =~ ^state-[0-9]{8}-[0-9]{6}\.sqlite$ ]]; then
  ok "one daily snapshot with the restore name"
else
  bad "one daily snapshot with the restore name: ${snaps[*]:-none}"
fi
if [ "${#snaps[@]}" = 1 ] && [ "$("$REAL_SQLITE" "${snaps[0]}" 'PRAGMA integrity_check; SELECT count(*) FROM t;' | tr '\n' ' ')" = "ok 3 " ]; then
  ok "snapshot passes integrity_check and has the rows"
else
  bad "snapshot passes integrity_check and has the rows"
fi
left=$(find "$DEST/$ME" -maxdepth 1 -type f ! -name 'state-*.sqlite' | wc -l)
if [ "$left" = 0 ]; then ok "no temp file left after success"; else bad "no temp file left after success: $(ls -A "$DEST/$ME")"; fi

# 2. The copy in progress has a name no other tool matches.
tgt=$(head -1 "$TARGETS")
b=$(basename "$tgt")
case "$b" in
  *.sqlite) bad "in-progress copy is not *.sqlite (devvm-cleanup gzips those): $b" ;;
  state-*) bad "in-progress copy is not state-* (retention, restore and the seed glob match those): $b" ;;
  *) ok "in-progress copy has a name nothing else matches ($b)" ;;
esac
[ "$(dirname "$tgt")" = "$DEST/$ME" ] && ok "in-progress copy is on the same filesystem (rename is atomic)" \
  || bad "in-progress copy is on the same filesystem: $tgt"

# 3. A failed copy exits 1 and leaves nothing behind.
rm -rf "$DEST"; : >"$TARGETS"
if SQLITE_FAIL=1 run; then bad "failed copy exits non-zero"; else ok "failed copy exits non-zero"; fi
grep -q "backup FAILED for $ME" "$WORK/out" && ok "failure is logged" || bad "failure is logged: $(cat "$WORK/out")"
left=$(find "$DEST/$ME" -maxdepth 1 -type f | wc -l)
if [ "$left" = 0 ]; then ok "failed copy leaves no file"; else bad "failed copy leaves no file: $(ls -A "$DEST/$ME")"; fi

echo
if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
