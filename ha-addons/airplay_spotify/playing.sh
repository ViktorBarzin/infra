#!/bin/sh
# playing.sh <airplay|spotify> <on|off>
# Sets input_boolean.<source>_playing in Home Assistant (packages/radio.yaml in
# ha-london-config). The radio automations treat it like VLC playing: the strip
# follows the music and the Pi connects to the Z537.
set -u
curl -sf -o /dev/null -X POST \
  -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"entity_id\": \"input_boolean.$1_playing\"}" \
  "http://supervisor/core/api/services/input_boolean/turn_$2" \
  || echo "playing.sh: could not set input_boolean.$1_playing $2" >&2
