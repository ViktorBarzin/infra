#!/usr/bin/env bash
# Unit tests for the pure functions in fan-control.sh (the thin actuator).
# The control math lives in Home Assistant now; the daemon only validates and
# applies the HA-computed command, so these cover the I/O-adjacent pure helpers.
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
ok() {  # <description> <cmd...>  (passes if cmd exits 0)
  if "${@:2}"; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL: %s — expected exit 0\n' "$1"; fi
}
no() {  # <description> <cmd...>  (passes if cmd exits non-zero)
  if "${@:2}"; then fail=$((fail + 1)); printf 'FAIL: %s — expected non-zero exit\n' "$1"; else pass=$((pass + 1)); fi
}

# --- fc_num: sanitise the HA command read (truncate floats, fallback, clamp) ---
eq "num valid"        55 "$(fc_num 55 0 0 100)"
eq "num float trunc"  55 "$(fc_num 55.7 0 0 100)"
eq "num empty->fb"     0 "$(fc_num '' 0 0 100)"
eq "num garbage->fb"   0 "$(fc_num abc 0 0 100)"
eq "num clamp low"     0 "$(fc_num -5 0 0 100)"
eq "num clamp high"  100 "$(fc_num 150 0 0 100)"

# --- fc_fresh: staleness gate on the command's last_updated age ---
ok "fresh well within"   fc_fresh 30 120
ok "fresh at boundary"   fc_fresh 120 120
no "stale just past"     fc_fresh 121 120
no "stale way past"      fc_fresh 600 120

# --- fc_clamp ---
eq "clamp over 100"   100 "$(fc_clamp 150)"
eq "clamp under 0"      0 "$(fc_clamp -5)"
eq "clamp passthrough" 45 "$(fc_clamp 45)"

# --- fc_fan_watts: estimated fan power from RPM (cube-law, calibrated to the sweep) ---
eq "fan_watts 0"     0  "$(fc_fan_watts 0)"
eq "fan_watts 4800"  2  "$(fc_fan_watts 4800)"
eq "fan_watts 9360"  16 "$(fc_fan_watts 9360)"
eq "fan_watts 12720" 42 "$(fc_fan_watts 12720)"
eq "fan_watts 16920" 99 "$(fc_fan_watts 16920)"

# --- temp parsing ---
eq "parse temp line" 74 "$(fc_parse_temp 'Temp             | 0Eh | ok  |  3.1 | 74 degrees C')"
eq "parse temp 7C"   72 "$(fc_parse_temp 'Temp             | 0Eh | ok  |  3.1 | 72 degrees C')"

# --- json field (jq-free): state + last_updated parsing for the command read ---
J='{"entity_id":"sensor.r730_fan_command_pct","state":"57","attributes":{"unit_of_measurement":"%"},"last_changed":"2026-06-08T16:55:20.517745+00:00","last_updated":"2026-06-08T16:55:25.000000+00:00"}'
eq "json state"        "57"                                "$(fc_json_str_field "$J" state)"
eq "json last_updated" "2026-06-08T16:55:25.000000+00:00"  "$(fc_json_str_field "$J" last_updated)"

# --- hex conversion ---
eq "hex 20"  0x14 "$(fc_pct_to_hex 20)"
eq "hex 45"  0x2d "$(fc_pct_to_hex 45)"
eq "hex 100" 0x64 "$(fc_pct_to_hex 100)"
eq "hex 5"   0x05 "$(fc_pct_to_hex 5)"

# --- SDR cache: reads go through a dumped sensor table, not a fresh download ---
# A fake ipmitool logs each call. `sdr dump` writes a cache file (or fails when
# FAKE_DUMP_FAIL=1); a cached read prints nothing while FAKE_STALE exists, which
# stands in for a table that no longer matches the hardware.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat >"$T/ipmitool" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_LOG"
if [[ "$1" == "-S" ]]; then shift 2; cached=1; else cached=0; fi
case "$1 $2" in
  "sdr dump") [[ "${FAKE_DUMP_FAIL:-0}" == 1 ]] && exit 1; echo sdr >"$3"; rm -f "$FAKE_STALE" ;;
  "sdr type")
    (( cached == 1 )) && [[ -e "$FAKE_STALE" ]] && exit 0
    [[ "$3" == temperature ]] && echo 'Temp             | 0Eh | ok  |  3.1 | 61 degrees C'
    [[ "$3" == fan ]] && { echo 'Fan1             | 30h | ok  |  7.1 | 6000 RPM'; echo 'Fan2             | 31h | ok  |  7.1 | 6200 RPM'; } ;;
esac
EOF
chmod +x "$T/ipmitool"
export FAKE_LOG="$T/log" FAKE_STALE="$T/stale"
export IPMITOOL="$T/ipmitool"
calls() { grep -c -- "$1" "$FAKE_LOG" 2>/dev/null || true; }  # <pattern> -> count
reset_fake() { rm -f "$FAKE_LOG" "$FAKE_STALE" "$SDR_CACHE"; FAKE_DUMP_FAIL=0; }
export FAKE_DUMP_FAIL=0

SDR_CACHE="$T/cache/sdr.cache"; reset_fake
eq "cache: first read dumps the table"   61 "$(read_cpu_temp)"
eq "cache: one dump"                      1 "$(calls 'sdr dump')"
eq "cache: read goes through the cache"   1 "$(calls "^-S $SDR_CACHE sdr type temperature")"
eq "cache: fan mean from the cache"    6100 "$(read_fan_rpm)"
eq "cache: no second dump"                1 "$(calls 'sdr dump')"
eq "cache: no live reads"                 0 "$(calls '^sdr type')"

reset_fake; read_cpu_temp >/dev/null; : >"$FAKE_STALE"
eq "stale: empty cached read re-dumps"   61 "$(read_cpu_temp)"
eq "stale: exactly one re-dump"           2 "$(calls 'sdr dump')"
eq "stale: still no live reads"           0 "$(calls '^sdr type')"

reset_fake; export FAKE_DUMP_FAIL=1
eq "dump fails: falls back to a live read" 61 "$(read_cpu_temp)"
eq "dump fails: live read happened"         1 "$(calls '^sdr type temperature')"
export FAKE_DUMP_FAIL=0

reset_fake; SDR_CACHE=""
eq "no cache configured: live read"  61 "$(read_cpu_temp)"
eq "no cache configured: no dump"     0 "$(calls 'sdr dump')"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
