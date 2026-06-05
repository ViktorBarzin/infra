#!/usr/bin/env bash
# Unit tests for the pure functions in fan-control.sh.
# Sources the script (main is guarded), exercises curve/decide/resolve/presence/parse.
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

# --- COOL curve (continuous linear: 30% @50C .. 100% @83C) ---
eq "cool <=T_LO clamps" 30  "$(fc_curve cool 40)"
eq "cool 50 -> 30"      30  "$(fc_curve cool 50)"
eq "cool 55 -> 41"      41  "$(fc_curve cool 55)"
eq "cool 60 -> 51"      51  "$(fc_curve cool 60)"
eq "cool 64 -> 60"      60  "$(fc_curve cool 64)"
eq "cool 70 -> 72"      72  "$(fc_curve cool 70)"
eq "cool 75 -> 83"      83  "$(fc_curve cool 75)"
eq "cool 83 -> 100"     100 "$(fc_curve cool 83)"
eq "cool >=T_HI clamps" 100 "$(fc_curve cool 90)"

# --- QUIET curve (continuous linear: 20% @68C .. 100% @83C) ---
eq "quiet <=T_LO clamps" 20  "$(fc_curve quiet 60)"
eq "quiet 68 -> 20"      20  "$(fc_curve quiet 68)"
eq "quiet 70 -> 31"      31  "$(fc_curve quiet 70)"
eq "quiet 75 -> 57"      57  "$(fc_curve quiet 75)"
eq "quiet 80 -> 84"      84  "$(fc_curve quiet 80)"
eq "quiet 83 -> 100"     100 "$(fc_curve quiet 83)"

# --- decide: asymmetric hysteresis (ramp up now, ease down only past the deadband) ---
eq "decide uninit -> target" 68 "$(fc_decide cool 68 -1 3)"
eq "decide ramp up now"      68 "$(fc_decide cool 68 25 3)"
eq "decide equal holds"      62 "$(fc_decide cool 65 62 3)"
eq "decide down held"        72 "$(fc_decide cool 68 72 3)"   # curve(68)=68<72 but curve(71)=75 !<72 -> hold
eq "decide down past"        60 "$(fc_decide cool 64 72 3)"   # curve(64)=60, curve(67)=66<72 -> drop

# --- fc_clamp / fc_resolve: HA mode resolution ---
eq "clamp over 100"   100 "$(fc_clamp 150)"
eq "clamp under 0"      0 "$(fc_clamp -5)"
eq "clamp passthrough" 45 "$(fc_clamp 45)"
eq "resolve manual=slider"      42 "$(fc_resolve manual 64 42 cool -1 3)"
eq "resolve manual clamped"    100 "$(fc_resolve manual 64 150 cool -1 3)"
eq "resolve cool=cool curve"    51 "$(fc_resolve cool 60 0 cool -1 3)"
eq "resolve quiet=quiet curve"  73 "$(fc_resolve quiet 78 0 cool -1 3)"
eq "resolve auto+empty=cool"    51 "$(fc_resolve auto 60 0 cool -1 3)"
eq "resolve auto+present=quiet" 31 "$(fc_resolve auto 70 0 quiet -1 3)"

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
