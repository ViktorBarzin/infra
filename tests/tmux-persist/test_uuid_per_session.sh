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

# --- the guess abstains between rivals ----------------------------------------
# With the stamps gone both panes fall through to the guess, and BOTH
# transcripts have been written since they started. "Newest wins" is then only
# whoever wrote last, so neither session may claim either conversation.
tt set-option -u -t alpha @claude_transcript
tt set-option -u -t bravo @claude_transcript
touch "$PROJ/$UUID_A.jsonl" "$PROJ/$UUID_B.jsonl"

tp save >/dev/null 2>&1

assert_eq "$(row_uuid alpha)" "-" \
  "with two conversations live in one directory the guess abstains for alpha"
assert_eq "$(row_uuid bravo)" "-" \
  "and abstains for bravo too, rather than racing on mtime"

# --- but it still answers when it is the only candidate ------------------------
# A session alone in its own directory is what the fallback exists for, so
# abstaining must not have turned it off altogether.
SOLO="$TEST_TMP/solo"; mkdir -p "$SOLO"
solo_slug="${SOLO//\//-}"; solo_slug="${solo_slug//./-}"
SOLO_PROJ="$HOME_ROOT/.claude/projects/$solo_slug"; mkdir -p "$SOLO_PROJ"
UUID_S="cccccccc-3333-4333-8333-cccccccccccc"
: > "$SOLO_PROJ/$UUID_S.jsonl"
tt new-session -d -s solo -c "$SOLO" "exec $BIN/claude 3600" 2>/dev/null

tp save >/dev/null 2>&1

assert_eq "$(row_uuid solo)" "$UUID_S" \
  "a lone session in its own directory still resolves by mtime"

# --- no two rows may carry one uuid -------------------------------------------
# The collision that actually reached production: a restore had started four
# sessions with `--resume <same uuid>`, so four panes each named that
# conversation from argv — confidently, and identically.
#
# bash is the fixture here because comm is the FILE's name: a copy called
# `claude` is what claude_pid_under matches, while the flags trailing -c's
# command land in /proc/<pid>/cmdline for argv resolution to read.
#
# `; true` is load-bearing. bash exec-optimises a lone command in -c, replacing
# itself with it — which leaves the pane as `sleep`, comm and all, and the flags
# gone from cmdline. A second statement makes it stay and wait.
ABIN="$TEST_TMP/argvbin"; mkdir -p "$ABIN"
cp "$(command -v bash)" "$ABIN/claude"
mk_resuming_session() { # $1 name, $2 uuid
  tt new-session -d -s "$1" -c "$WORK" \
    "exec $ABIN/claude -c 'sleep 3600; true' --resume $2" 2>/dev/null
}

tt kill-session -t alpha 2>/dev/null
tt kill-session -t bravo 2>/dev/null
mk_resuming_session twin_one "$UUID_B"
mk_resuming_session twin_two "$UUID_B"

tp save >/dev/null 2>&1

dupes="$(cut -f3 "$(newest_snap)" | grep -v '^-$' | sort | uniq -d)"
assert_eq "$dupes" "" \
  "no conversation is claimed by two sessions in one capture"

claimed="$(cut -f3 "$(newest_snap)" | grep -c "^$UUID_B\$")"
assert_eq "$claimed" "1" \
  "the contested conversation goes to exactly one of the twins"

assert_eq "$(cut -f3 "$(newest_snap)" | grep -c '^-$')" "1" \
  "the other twin is saved with no conversation, not with a copy of the first"

# --- a certain answer outranks a guess ----------------------------------------
# twin_one names B from argv; twin_two is STAMPED with B. The stamp is the exact
# answer, so it keeps B whichever order the panes happen to be listed in.
tt set-option -t twin_two @claude_transcript "$PROJ/$UUID_B.jsonl"

tp save >/dev/null 2>&1

assert_eq "$(row_uuid twin_two)" "$UUID_B" \
  "the session that is certain of its conversation keeps it"
assert_eq "$(row_uuid twin_one)" "-" \
  "the session that was less sure yields, rather than duplicating it"

finish
