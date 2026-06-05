#!/usr/bin/env bash
# Unit tests for the pure functions in fan-control.sh.
# Sources the script (main is guarded), exercises curve/decide/presence/parse.
# Run: bash infra/scripts/test-fan-control.sh

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/fan-control.sh"

pass=0 fail=0
eq() {  # <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL: %s — expected [%s] got [%s]\n' "$1" "$2" "$3"
  fi
}

# --- COOL curve (power-tuned 2026-06-05: knee at 60%) ---
eq "cool 40 -> 30"  30  "$(fc_curve cool 40)"
eq "cool 54 -> 30"  30  "$(fc_curve cool 54)"
eq "cool 55 -> 50"  50  "$(fc_curve cool 55)"
eq "cool 63 -> 50"  50  "$(fc_curve cool 63)"
eq "cool 64 -> 60"  60  "$(fc_curve cool 64)"
eq "cool 72 -> 60"  60  "$(fc_curve cool 72)"
eq "cool 73 -> 80"  80  "$(fc_curve cool 73)"
eq "cool 78 -> 80"  80  "$(fc_curve cool 78)"
eq "cool 79 -> 100" 100 "$(fc_curve cool 79)"
eq "cool 91 -> 100" 100 "$(fc_curve cool 91)"

# --- QUIET curve ---
eq "quiet 50 -> 20" 20  "$(fc_curve quiet 50)"
eq "quiet 72 -> 20" 20  "$(fc_curve quiet 72)"
eq "quiet 73 -> 40" 40  "$(fc_curve quiet 73)"
eq "quiet 77 -> 40" 40  "$(fc_curve quiet 77)"
eq "quiet 78 -> 65" 65  "$(fc_curve quiet 78)"
eq "quiet 81 -> 65" 65  "$(fc_curve quiet 81)"
eq "quiet 82 -> 100" 100 "$(fc_curve quiet 82)"

# --- decide: hysteresis ---
eq "decide uninit -> target"  60 "$(fc_decide cool 68 -1 3)"
eq "decide ramp up now"       60 "$(fc_decide cool 68 25 3)"
eq "decide equal holds"       60 "$(fc_decide cool 64 60 3)"
eq "decide down held in band" 80 "$(fc_decide cool 70 80 3)"   # 70+3=73 still 80% -> hold
eq "decide down past band"    60 "$(fc_decide cool 69 80 3)"   # 69+3=72 -> 60% < 80 -> drop
eq "decide 100 holds"        100 "$(fc_decide cool 77 100 3)"  # 77+3=80 -> 100 -> hold
eq "decide 100 drops"         80 "$(fc_decide cool 75 100 3)"  # 75+3=78 -> 80 < 100 -> drop

# --- presence ---
now=1000000
eq "presence open -> quiet"          quiet "$(fc_presence_mode Отворена 0 $now 900 Отворена)"
eq "presence closed recent -> quiet" quiet "$(fc_presence_mode Затворена $((now - 100)) $now 900 Отворена)"
eq "presence closed stale -> cool"   cool  "$(fc_presence_mode Затворена $((now - 1000)) $now 900 Отворена)"
eq "presence closed edge -> cool"    cool  "$(fc_presence_mode Затворена $((now - 900)) $now 900 Отворена)"

# --- temp parsing ---
eq "parse temp line" 74 "$(fc_parse_temp 'Temp             | 0Eh | ok  |  3.1 | 74 degrees C')"
eq "parse temp 7C"   72 "$(fc_parse_temp 'Temp             | 0Eh | ok  |  3.1 | 72 degrees C')"

# --- json field (jq-free) ---
J='{"entity_id":"sensor.garage_door_state_bg","state":"Отворена","attributes":{"friendly_name":"Garage Door State BG"},"last_changed":"2026-06-04T16:55:20.517745+00:00","last_updated":"2026-06-04T16:55:20.517745+00:00"}'
eq "json state"        "Отворена"                          "$(fc_json_str_field "$J" state)"
eq "json last_changed" "2026-06-04T16:55:20.517745+00:00"  "$(fc_json_str_field "$J" last_changed)"

# --- hex conversion ---
eq "hex 20"  0x14 "$(fc_pct_to_hex 20)"
eq "hex 45"  0x2d "$(fc_pct_to_hex 45)"
eq "hex 100" 0x64 "$(fc_pct_to_hex 100)"
eq "hex 5"   0x05 "$(fc_pct_to_hex 5)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
