#!/bin/bash
# Tests for scripts/t3-state-pull.sh. The "devvm" is a local directory: with
# T3_PULL_SRC empty the script hands rsync plain paths, so the real rsync lists
# and copies real files. mountpoint and curl are stubs. No host or devvm access.
# Run: bash scripts/t3-state-pull.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

REMOTE=$WORK/remote
BACKUP=$WORK/backup
DEST=$BACKUP/t3-state
METRICS=$WORK/metrics
mkdir -p "$WORK/bin" "$BACKUP"
: >"$WORK/key"

cat >"$WORK/bin/mountpoint" <<'STUB'
#!/bin/bash
[ "${NOT_MOUNTED:-0}" = 1 ] && exit 1
exit 0
STUB
cat >"$WORK/bin/curl" <<'STUB'
#!/bin/bash
cat >>"$METRICS"
exit 0
STUB
chmod +x "$WORK/bin/mountpoint" "$WORK/bin/curl"

# snap <user> <name> <age> [content]: a remote file, mtime <age> ago.
# A .gz gets real gzip content; a .sqlite gets a real SQLite header.
snap() {
  local u=$1 name=$2 age=$3 body=${4:-"rows for $1/$2"}
  mkdir -p "$REMOTE/$u"
  if [[ $name == *.gz ]]; then
    printf 'SQLite format 3\000%s' "$body" | gzip -c >"$REMOTE/$u/$name"
  else
    printf 'SQLite format 3\000%s' "$body" >"$REMOTE/$u/$name"
  fi
  touch -d "$age" "$REMOTE/$u/$name"
}

run_pull() { # -> prints the log, then rc=<n>
  : >"$METRICS"
  (
    export PATH="$WORK/bin:$PATH" METRICS
    export T3_PULL_SRC="" T3_PULL_REMOTE_ROOT="$REMOTE/" T3_PULL_SSH_KEY="$WORK/key"
    export T3_PULL_BACKUP_ROOT="$BACKUP" T3_PULL_DEST="$DEST" T3_PULL_KEEP=2
    export T3_PULL_LOCKFILE="$WORK/lock" T3_PULL_PUSHGATEWAY=http://stub
    bash "$HERE/t3-state-pull.sh"
    echo "rc=$?"
  ) 2>&1
}
have() { [ -s "$DEST/$1" ]; }
lsdest() { (cd "$DEST" 2>/dev/null && find . -type f | sort | tr '\n' ' '); }

# --- night 1: a fresh host disk ------------------------------------------
snap wizard state-20261108-034706.sqlite.gz "4 days ago"
snap wizard state-20261109-034745.sqlite.gz "3 days ago"
snap wizard state-20261110-033652.sqlite.gz "2 days ago"
snap wizard state-20261111-034710.sqlite "1 day ago" "newest wizard"
snap wizard state-prebump-0.1.8-20261110-034113.sqlite.gz "2 days ago"
snap wizard state-20260713-033730.sqlite-journal "100 days ago"
snap emo state-20261111-034710.sqlite "1 day ago"
snap emo state-20260609-193639.sqlite-shm "150 days ago"
out=$(run_pull)

[ "$(tail -1 <<<"$out")" = "rc=0" ] && ok "a clean pull exits 0" || bad "clean pull: $out"
have wizard/state-20261111-034710.sqlite.gz && have wizard/state-20261110-033652.sqlite.gz \
  && ok "the newest KEEP snapshots per user are pulled" || bad "pulled: $(lsdest)"
have wizard/state-20261109-034745.sqlite.gz && bad "pulled more than KEEP" || ok "older snapshots are not pulled"
[ "$(gzip -dc "$DEST/wizard/state-20261111-034710.sqlite.gz" | tail -c 13)" = "newest wizard" ] \
  && ok "an uncompressed snapshot is stored gzipped with its content intact" || bad "content: $(gzip -dc "$DEST/wizard/state-20261111-034710.sqlite.gz" | od -c | head -2)"
find "$DEST/wizard" -type f | grep -q -E 'prebump|journal|\.sqlite$' && bad "pulled a non-daily file: $(lsdest)" || ok "pre-bump copies, journals and bare .sqlite files stay behind"
have emo/state-20261111-034710.sqlite.gz && ok "every user directory is pulled" || bad "emo: $(lsdest)"
[ "$(stat -c %a "$DEST/wizard")" = 700 ] && [ "$(stat -c %a "$DEST/wizard/state-20261111-034710.sqlite.gz")" = 600 ] \
  && ok "snapshots are root-only on the host (they hold T3 auth sessions)" || bad "modes: $(stat -c '%a %n' "$DEST/wizard" "$DEST"/wizard/*)"
grep -qx 't3-state/wizard/state-20261111-034710.sqlite.gz' "$BACKUP/.changed-files" \
  && ok "new files are queued for the nightly offsite copy" || bad "manifest: $(cat "$BACKUP/.changed-files" 2>/dev/null)"
want=$(date -u -d '2026-11-11 03:47:10' +%s)
grep -qx "t3_state_pull_newest_snapshot_timestamp{user=\"wizard\"} $want" "$METRICS" \
  && ok "the newest snapshot's own time is published per user" || bad "metrics: $(cat "$METRICS")"
grep -q '^t3_state_pull_last_status 0$' "$METRICS" && grep -q '^t3_state_pull_last_success_timestamp ' "$METRICS" \
  && ok "a clean pull records success" || bad "status metrics: $(cat "$METRICS")"

# --- night 2: nothing new on the devvm -------------------------------------
touch -d "3 days ago" "$DEST/wizard/state-20261111-034710.sqlite.gz"
before=$(stat -c %Y "$DEST/wizard/state-20261111-034710.sqlite.gz")
lines=$(wc -l <"$BACKUP/.changed-files")
out=$(run_pull)
[ "$(stat -c %Y "$DEST/wizard/state-20261111-034710.sqlite.gz")" = "$before" ] \
  && [ "$(wc -l <"$BACKUP/.changed-files")" = "$lines" ] \
  && ok "a snapshot already on the host is not fetched again" || bad "refetch: $out"

# --- night 3: the devvm compressed yesterday's and wrote a new one -----------
rm "$REMOTE/wizard/state-20261111-034710.sqlite"
snap wizard state-20261111-034710.sqlite.gz "1 day ago" "newest wizard"
snap wizard state-20261112-034000.sqlite "3 hours ago"
out=$(run_pull)
have wizard/state-20261112-034000.sqlite.gz && ok "the next night's snapshot arrives" || bad "night 3: $(lsdest) $out"
have wizard/state-20261110-033652.sqlite.gz && bad "kept more than KEEP: $(lsdest)" || ok "the oldest generation is pruned past KEEP"
have wizard/state-20261111-034710.sqlite.gz && ok "the previous generation is kept" || bad "kept: $(lsdest)"

# --- a snapshot still being written is left for the next night ---------------
snap wizard state-20261113-034000.sqlite "1 minute ago"
out=$(run_pull)
have wizard/state-20261113-034000.sqlite.gz && bad "pulled a file still being written" || ok "a file modified in the last 30 minutes is skipped"
[ "$(tail -1 <<<"$out")" = "rc=0" ] && ok "skipping an unsettled file is not a failure" || bad "unsettled rc: $out"
rm "$REMOTE/wizard/state-20261113-034000.sqlite"

# --- a damaged file never becomes a restore point -----------------------------
mkdir -p "$REMOTE/emo"
printf 'not gzip' >"$REMOTE/emo/state-20261112-034000.sqlite.gz"
touch -d "3 hours ago" "$REMOTE/emo/state-20261112-034000.sqlite.gz"
out=$(run_pull)
have emo/state-20261112-034000.sqlite.gz && bad "kept a damaged gzip" || ok "a damaged gzip is discarded"
[ "$(tail -1 <<<"$out")" = "rc=1" ] && ok "a damaged file fails the step" || bad "damaged rc: $out"
have emo/state-20261111-034710.sqlite.gz && ok "a failed user keeps the copies it had" || bad "emo kept: $(lsdest)"
grep -q '^t3_state_pull_last_status 1$' "$METRICS" && ok "the failure is published" || bad "fail metric: $(cat "$METRICS")"
rm "$REMOTE/emo/state-20261112-034000.sqlite.gz"
printf 'garbage' >"$REMOTE/emo/state-20261112-034000.sqlite"
touch -d "3 hours ago" "$REMOTE/emo/state-20261112-034000.sqlite"
out=$(run_pull)
have emo/state-20261112-034000.sqlite.gz && bad "kept a file that is not SQLite" || ok "a file without the SQLite header is discarded"
rm "$REMOTE/emo/state-20261112-034000.sqlite"

# --- a snapshot that shrank to nothing holds the old ones ---------------------
# What a rebuilt devvm that never got its T3 state back would send: a tiny
# fresh database. Pruning would push the real history out within KEEP nights.
snap wizard state-20261114-034000.sqlite "3 hours ago" "x"
big=$(head -c 200000 /dev/urandom | base64 -w0)
snap wizard state-20261112-034000.sqlite.gz "2 days ago" "$big"
rm -f "$DEST/wizard/state-20261112-034000.sqlite.gz"
out=$(run_pull)
have wizard/state-20261114-034000.sqlite.gz && have wizard/state-20261112-034000.sqlite.gz && have wizard/state-20261111-034710.sqlite.gz \
  && ok "a newest snapshot under a quarter of the largest one prunes nothing" || bad "shrink: $(lsdest) $out"
[ "$(tail -1 <<<"$out")" = "rc=1" ] && ok "the shrink fails the step so someone looks" || bad "shrink rc: $out"
rm "$REMOTE/wizard/state-20261114-034000.sqlite" "$DEST/wizard/state-20261114-034000.sqlite.gz"

# --- the devvm does not answer ------------------------------------------------
mv "$REMOTE" "$REMOTE.away"
snapshot_list=$(lsdest)
out=$(run_pull)
[ "$(tail -1 <<<"$out")" = "rc=1" ] && ok "an unreachable devvm fails the step" || bad "unreachable rc: $out"
[ "$(lsdest)" = "$snapshot_list" ] && ok "an unreachable devvm deletes nothing" || bad "unreachable: $(lsdest)"
grep -q 't3_state_pull_newest_snapshot_timestamp{user="wizard"}' "$METRICS" \
  && ok "the host's newest snapshot age is still published, so staleness shows" || bad "unreachable metrics: $(cat "$METRICS")"
mv "$REMOTE.away" "$REMOTE"

out=$(NOT_MOUNTED=1 run_pull)
[ "$(tail -1 <<<"$out")" = "rc=1" ] && grep -q 'not mounted' <<<"$out" \
  && ok "no backup disk, no pull" || bad "not mounted: $out"

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
