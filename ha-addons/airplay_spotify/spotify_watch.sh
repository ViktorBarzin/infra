#!/bin/sh
# go-librespot has no hook for play and stop, so read its status every 2 s and
# tell Home Assistant when that changes. Paused counts as not playing.
set -u
last=""
while sleep 2; do
  now=$(curl -sf http://127.0.0.1:3678/status \
    | jq -r 'if (.track != null and (.stopped | not) and (.paused | not)) then "on" else "off" end' 2>/dev/null)
  [ -n "$now" ] || now=off
  if [ "$now" != "$last" ]; then
    /app/playing.sh spotify "$now"
    last=$now
  fi
done
