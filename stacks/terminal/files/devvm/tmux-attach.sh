#!/usr/bin/env bash
# Invoked by ttyd-multi.service. ttyd's -a flag forwards ?arg=<value> as $1.
# Defence-in-depth: ttyd uses argv (never shell strings) and we re-validate
# here before handing the name to tmux as a quoted argv slot.
set -euo pipefail

name="${1:-main}"
if ! [[ "$name" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
    name=main
fi

exec tmux new-session -A -s "$name" -c /home/wizard/code
