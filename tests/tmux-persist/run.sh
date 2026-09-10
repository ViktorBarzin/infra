#!/usr/bin/env bash
# Run every tmux-persist test. Each test file runs in its own process with its
# own private tmux socket and its own temporary STATE_DIR, so they are safe to
# run while real sessions are live on this machine.
#
#   tests/tmux-persist/run.sh              # all
#   tests/tmux-persist/run.sh partial_loss # substring filter
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
filter="${1:-}"
failed=0 ran=0

for t in test_*.sh; do
  [[ -n "$filter" && "$t" != *"$filter"* ]] && continue
  ran=$((ran + 1))
  printf '\n--- %s ---\n' "$t"
  bash "$t" || failed=$((failed + 1))
done

echo
if (( ran == 0 )); then
  echo "no tests matched '$filter'" >&2
  exit 1
fi
if (( failed > 0 )); then
  printf '%d/%d test file(s) FAILED\n' "$failed" "$ran" >&2
  exit 1
fi
printf 'all %d test file(s) passed\n' "$ran"
