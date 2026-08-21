#!/usr/bin/env bash
# One session, one conversation. Two sessions that share a cwd must never be
# saved carrying the SAME conversation uuid.
#
# What this pins (2026-08-21, emo's sessions). Five of his sessions ran in
# /home/emo, so they shared one project-slug directory, and none had been
# launched with --session-id. Every one of them fell through to source 3 —
# "newest .jsonl by mtime in the slug dir" — so the snapshot recorded ONE uuid
# for all five, a different one each tick depending on which transcript had been
# touched last. Restoring four of those rows resumed the same conversation four
# times over, and since each live name held a different conversation the picker
# suffixed them, so four duplicate sessions arrived in his list as well.
#
# Both halves of the fix are asserted here:
#
#   * @claude_transcript, the stamp Claude's own SessionStart hook leaves on the
#     tmux session, is read BEFORE the guesses. It is per-session and it tracks
#     the CURRENT conversation, so it stays right across a /clear — which argv
#     does not, since argv still names whatever id the process was launched with.
#   * a uuid is claimed by exactly ONE row per capture. A row whose guess was
#     already taken is saved with no conversation, which restores as a plain
#     shell — rather than with someone else's, which restores as a duplicate.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_env
trap teardown_env EXIT

echo "== a saved row names the conversation that session is actually running =="

# A fake home, so the projects root the script reads is a fixture rather than
# the real ~/.claude of whoever runs the suite.
HOME_ROOT="$TEST_TMP/home"
export TMUX_PERSIST_HOME_ROOT="$HOME_ROOT"

# Both sessions live in ONE directory: that is what collapses them onto a single
# slug dir, and it is the shape of the bug.
WORK="$TEST_TMP/proj"
mkdir -p "$WORK"
slug="${WORK//\//-}"; slug="${slug//./-}"
PROJ="$HOME_ROOT/.claude/projects/$slug"
mkdir -p "$PROJ"

UUID_A="aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
UUID_B="bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"

# `claude` here is a copy of sleep: claude_pid_under matches on /proc/<pid>/comm,
# so the NAME is the whole fixture. It takes no --session-id, which is exactly
# the case that broke — the launcher runs a bare `claude` for these sessions.
BIN="$TEST_TMP/bin"; mkdir -p "$BIN"
cp "$(command -v sleep)" "$BIN/claude"

mk_claude_session() { # $1 name
  tt new-session -d -s "$1" -c "$WORK" "exec $BIN/claude 3600" 2>/dev/null
}

# B is the newest by mtime, so B is what the guess returns for EVERY pane.
: > "$PROJ/$UUID_A.jsonl"
sleep 1
: > "$PROJ/$UUID_B.jsonl"

mk_claude_session alpha
mk_claude_session bravo

row_uuid() { awk -F'\t' -v s="$1" '$1==s{print $3}' "$(newest_snap)"; }

# --- the stamp wins over the guess --------------------------------------------
tt set-option -t alpha @claude_transcript "$PROJ/$UUID_A.jsonl"
tt set-option -t bravo @claude_transcript "$PROJ/$UUID_B.jsonl"

tp save >/dev/null 2>&1

assert_eq "$(row_uuid alpha)" "$UUID_A" \
  "alpha keeps its own conversation, though B is the newest in the directory"
assert_eq "$(row_uuid bravo)" "$UUID_B" \
  "bravo keeps its own conversation"

# --- a stamp is only trusted inside that user's own projects root -------------
# The stamp is written by the session's own user, so it is untrusted input.
tt set-option -t alpha @claude_transcript "/etc/passwd"
tp save >/dev/null 2>&1
assert_eq "$(row_uuid alpha)" "-" \
  "a stamp pointing outside the projects root is refused, not saved"

tt set-option -t alpha @claude_transcript "$PROJ/../../../$UUID_A.jsonl"
tp save >/dev/null 2>&1
assert_eq "$(row_uuid alpha)" "-" \
  "a stamp that climbs out of the projects root is refused"

# --- no two rows may carry one uuid -------------------------------------------
# With the stamps gone, both panes fall through to the guess and both want B.
tt set-option -u -t alpha @claude_transcript
tt set-option -u -t bravo @claude_transcript

tp save >/dev/null 2>&1

dupes="$(cut -f3 "$(newest_snap)" | grep -v '^-$' | sort | uniq -d)"
assert_eq "$dupes" "" \
  "no conversation is claimed by two sessions in one capture"

claimed="$(cut -f3 "$(newest_snap)" | grep -c "^$UUID_B\$")"
assert_eq "$claimed" "1" \
  "the contested conversation goes to exactly one session"

unresolved="$(cut -f3 "$(newest_snap)" | grep -c '^-$')"
assert_eq "$unresolved" "1" \
  "the other session is saved with no conversation, not with someone else's"

# --- a stamped row is not robbed by an unstamped one --------------------------
# alpha has no stamp and its guess is B; bravo IS stamped with B. The stamp is
# the exact answer, so bravo must keep B whichever order the panes are listed in.
tt set-option -t bravo @claude_transcript "$PROJ/$UUID_B.jsonl"

tp save >/dev/null 2>&1

assert_eq "$(row_uuid bravo)" "$UUID_B" \
  "the session that is certain of its conversation keeps it"
assert_eq "$(row_uuid alpha)" "-" \
  "the session that only guessed it yields, rather than duplicating it"

finish
