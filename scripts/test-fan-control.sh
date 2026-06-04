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

# --- COOL curve ---
eq "cool 40 -> 25"  25  "$(fc_curve cool 40)"
eq "cool 52 -> 25"  25  "$(fc_curve cool 52)"
eq "cool 53 -> 45"  45  "$(fc_curve cool 53)"
eq "cool 60 -> 45"  45  "$(fc_curve cool 60)"
eq "cool 61 -> 65"  65  "$(fc_curve cool 61)"
eq "cool 67 -> 65"  65  "$(fc_curve cool 67)"
eq "cool 68 -> 85"  85  "$(fc_curve cool 68)"
eq "cool 73 -> 85"  85  "$(fc_curve cool 73)"
eq "cool 74 -> 100" 100 "$(fc_curve cool 74)"
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
eq "decide uninit -> target"  85 "$(fc_decide cool 68 -1 3)"
eq "decide ramp up now"       85 "$(fc_decide cool 68 25 3)"
eq "decide equal holds"       65 "$(fc_decide cool 65 65 3)"
eq "decide down held in band" 85 "$(fc_decide cool 67 85 3)"   # 67+3=70 still 85% -> hold
eq "decide down past band"    65 "$(fc_decide cool 64 85 3)"   # 64+3=67 -> 65% < 85 -> drop
eq "decide 100 holds at 71"  100 "$(fc_decide cool 71 100 3)"  # 71+3=74 -> 100 -> hold
eq "decide 100 drops at 70"   85 "$(fc_decide cool 70 100 3)"  # 70+3=73 -> 85 < 100 -> drop

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
