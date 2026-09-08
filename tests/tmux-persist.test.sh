#!/usr/bin/env bash
# Entry point matching this directory's `tests/<name>.test.sh` convention.
# The tmux-persist suite is several files (it drives the real script against a
# throwaway state dir and a private tmux socket), so they live in
# tests/tmux-persist/ and this runs them all.
#
#   tests/tmux-persist.test.sh              # all
#   tests/tmux-persist/run.sh partial_loss  # one, by substring
exec bash "$(cd "$(dirname "$0")" && pwd)/tmux-persist/run.sh" "$@"
