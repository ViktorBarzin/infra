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

finish
