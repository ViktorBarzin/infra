#!/usr/bin/env bash
# Cutover from the pre-snapshot layout. The deployed box already has a regular
# <user>.tsv holding the last live set; it becomes the first snapshot so restore
# keeps working in the window before the first post-deploy save.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_env
trap teardown_env EXIT

echo "== an existing flat manifest becomes the first snapshot =="

# The old format wrote an EMPTY third field for "no conversation".
printf 'alpha\t/tmp\t11111111-1111-1111-1111-111111111111\nplain\t/tmp\t\n' \
  > "$TMUX_PERSIST_STATE_DIR/$TEST_USER.tsv"
touch -d @1786700000 "$TMUX_PERSIST_STATE_DIR/$TEST_USER.tsv"

# A read path alone triggers the migration — a reboot before the first save
# must still find something to restore.
list="$(tp snapshots "$TEST_USER")"
expected_ts="$(date -u -d @1786700000 +%Y%m%dT%H%M%S)"

assert_eq "$(snap_count)" "1" "the flat manifest became one snapshot"
assert_file_exists "$(snap_dir)/$expected_ts.tsv" "snapshot is stamped with the manifest's mtime"
assert_contains "$list" "$expected_ts" "the migrated snapshot is listed"
assert_contains "$list" "	2" "it carries both sessions"

# The empty uuid must become "-": tab is IFS-whitespace, so a genuinely empty
# field collapses on read and shifts every column after it.
plain_row="$(awk -F'\t' '$1=="plain"' "$(snap_dir)/$expected_ts.tsv")"
assert_eq "$(printf '%s' "$plain_row" | cut -f3)" "-" "an empty uuid is normalised to '-'"

# The pointer is now a symlink onto that snapshot.
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -L "$TMUX_PERSIST_STATE_DIR/$TEST_USER.tsv" ]]; then
  _pass "the manifest is now a pointer"
else
  _fail "the manifest is still a regular file"
fi
assert_contains "$(cat "$TMUX_PERSIST_STATE_DIR/$TEST_USER.tsv")" "alpha" "the pointer resolves"

# --- migration runs once ---
mk_session beta
at_time 1786800000
tp save >/dev/null
assert_eq "$(snap_count)" "2" "the next save adds a snapshot rather than re-migrating"

# Even with the pointer now a symlink, a later read path must not re-migrate.
tp snapshots "$TEST_USER" >/dev/null
assert_eq "$(snap_count)" "2" "a read path does not re-migrate an already-migrated user"

finish
