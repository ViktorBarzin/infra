#!/usr/bin/env bash
# Retention holds the newest SNAPSHOT_KEEP snapshots, prunes oldest first, and
# never prunes the newest one (the manifest points at it).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_env
trap teardown_env EXIT

echo "== retention keeps the newest N snapshots, oldest pruned first =="

export TMUX_PERSIST_SNAPSHOT_KEEP=5

# Seed 8 snapshots, all older than the save below (which lands 2026-08-14).
for i in 1 2 3 4 5 6 7 8; do
  seed_snapshot "2026080${i}T000000" "s$i	/tmp	-"
done
assert_eq "$(snap_count)" "8" "8 snapshots seeded"

mk_session live
at_time 1786700000          # 2026-08-14, newer than every seeded snapshot
tp save >/dev/null

assert_eq "$(snap_count)" "5" "pruned down to SNAPSHOT_KEEP"
assert_file_missing "$(snap_dir)/20260801T000000.tsv" "oldest snapshot pruned"
assert_file_missing "$(snap_dir)/20260804T000000.tsv" "4th-oldest snapshot pruned"
assert_file_exists  "$(snap_dir)/20260805T000000.tsv" "5th-oldest snapshot kept"
assert_file_exists  "$(snap_dir)/20260808T000000.tsv" "newest seeded snapshot kept"

# The save itself wrote the newest one; it must survive its own prune.
newest="$(newest_snap)"
assert_contains "$(cat "$newest")" "live" "the just-written snapshot survived the prune"
assert_eq "$(cat "$TMUX_PERSIST_STATE_DIR/$TEST_USER.tsv")" "$(cat "$newest")" \
  "manifest still resolves after pruning"

# A save that writes nothing (unchanged set) must not prune either — the count
# stays put rather than drifting down on every tick.
at_time 1786700300
tp save >/dev/null
assert_eq "$(snap_count)" "5" "an unchanged save does not prune further"

echo "== a snapshot list longer than a pipe buffer still prunes cleanly =="

# prune_snapshots used to pipe the file list into `head -n <excess>`. With a
# small excess, head exits after a line or two while the writer still has more
# than the 64 KiB pipe buffer to write, so the writer dies of SIGPIPE, and under
# `set -o pipefail` that ended the whole save for every later user. Production
# hit it in 6 of 33 runs in the week to 2026-10-23, with 200 snapshots (KEEP)
# and an excess of 1; 3000 rows of ~60-byte paths make it certain rather than
# likely.
rm -f "$(snap_dir)"/*.tsv
export TMUX_PERSIST_SNAPSHOT_KEEP=3000
mkdir -p "$(snap_dir)"
for ((i = 0; i < 3000; i++)); do
  TZ=UTC printf -v ts '%(%Y%m%dT%H%M%S)T' "$((1780000000 + i * 60))"
  printf 's\t/tmp\t-\n' > "$(snap_dir)/$ts.tsv"
done
oldest="$(ls -1 "$(snap_dir)"/*.tsv | sort | head -1)"
tt kill-server 2>/dev/null
mk_session biglist
at_time 1786800000          # newer than every seeded snapshot
out="$(tp save 2>&1)"; rc=$?
assert_eq "$rc" "0" "save exits 0 with a list longer than the pipe buffer"
assert_eq "$(snap_count)" "3000" "pruned down to SNAPSHOT_KEEP"
assert_file_missing "$oldest" "the oldest snapshot was the one pruned"
assert_contains "$(cat "$(newest_snap)")" "biglist" "the just-written snapshot survived the prune"

finish
