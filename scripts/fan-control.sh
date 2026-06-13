#!/usr/bin/env bash
# IPMI fan ACTUATOR for the Dell R730 PVE host (192.168.1.127).
#
# THIN ACTUATOR — the control logic lives entirely in Home Assistant. HA owns
# the curve thresholds, the duty %, the bias, and the final setpoint: it
# publishes ONE number, `sensor.r730_fan_command_pct` (= computed fan % incl.
# bias and any manual/lock override). This daemon does NOT compute anything — it
# just reads that command each loop and applies it over IPMI, and reads the raw
# sensors (temp/rpm) that feed HA/Prometheus.
#   (Until 2026-06-07 the curve+hysteresis were computed HERE; moved to HA so
#    all tuning + the setpoint determination happen on the dashboard.)
#
# Safety (manual fan mode bypasses the iDRAC's own curve, so we backstop it).
# These are INDEPENDENT of HA — the actuator protects the hardware on its own:
#   - On ANY exit (crash/stop/TERM) the EXIT trap hands fans back to Dell
#     automatic control (raw 0x30 0x30 0x01 0x01). systemd ExecStopPost repeats.
#   - CPU >= CEILING -> hand back to Dell auto until it recovers (RESUME_BELOW
#     held for RESUME_STABLE s). The firmware's own emergency cooling takes over.
#   - IPMI read failures (>= MAX_IPMI_FAILS) -> hand back to Dell auto.
#   - HA unreachable / command missing / STALE -> hand back to Dell auto.
#
# Deploy: scp to /usr/local/bin/fan-control (strip .sh) + install
# fan-control.service + /etc/fan-control.env. Same pattern as apply-mbps-caps.
# Tests: test-fan-control.sh (sources this file, exercises the pure functions).
# Design: infra/docs/plans/2026-06-04-pve-fan-control-design.md
# Runbook: infra/docs/runbooks/fan-control.md

set -uo pipefail

# ---- configuration (override via /etc/fan-control.env) ----
: "${IPMITOOL:=ipmitool}"
: "${LOOP_INTERVAL:=15}"             # seconds between apply cycles
: "${CEILING:=83}"                   # degC: hand back to Dell auto at/above this
: "${RESUME_BELOW:=75}"              # degC: eligible to resume manual below this...
: "${RESUME_STABLE:=120}"            # ...once held that long
: "${HA_URL:=http://192.168.1.8:8123}"
: "${HA_TOKEN:=}"                    # long-lived ha-sofia token; empty => Dell auto (no control)
: "${COMMAND_ENTITY:=sensor.r730_fan_command_pct}"  # HA-computed fan %; we only apply it
: "${STALE_SECS:=120}"               # command older than this => stale => Dell auto
: "${PUSHGATEWAY_URL:=}"             # optional Prometheus Pushgateway base URL
: "${MAX_IPMI_FAILS:=3}"
: "${MIN_STEP:=3}"                   # min fan-% change worth an IPMI write (anti-jitter)
: "${DRY_RUN:=0}"                    # 1 => log IPMI actions instead of executing
: "${RUN_ONCE:=0}"                   # 1 => one iteration then exit (testing)

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }

# ---- pure functions (no side effects; unit-tested) ----

# fc_num <value> <fallback> <min> <max> -> validated integer (floats truncated;
# non-numeric => fallback; out-of-range clamped). Sanitises the HA command read.
fc_num() {
  local v="${1%%.*}" fb="$2" lo="$3" hi="$4"
  [[ "$v" =~ ^-?[0-9]+$ ]] || { echo "$fb"; return 0; }
  (( v < lo )) && v="$lo"; (( v > hi )) && v="$hi"; echo "$v"
}

# fc_fresh <age_secs> <max_secs> -> exit 0 if fresh (age <= max), else 1.
fc_fresh() { (( $1 <= $2 )); }

# fc_parse_temp <ipmitool 'Temp' line> -> integer degC
fc_parse_temp() {
  echo "$1" | grep -oE '[0-9]+ degrees C' | grep -oE '^[0-9]+' | head -1
}

# fc_json_str_field <json> <key> -> string value (first match; jq-free)
fc_json_str_field() {
  printf '%s' "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 \
    | sed -E "s/.*:[[:space:]]*\"(.*)\"\$/\1/"
}

# fc_pct_to_hex <pct> -> 0xNN
fc_pct_to_hex() { printf '0x%02x' "$1"; }

# fc_clamp <pct> -> 0..100
fc_clamp() { local p="$1"; (( p < 0 )) && p=0; (( p > 100 )) && p=100; echo "$p"; }

# fc_fan_watts <rpm> -> estimated TOTAL fan power (W). The iDRAC reports only
# total DCMI watts + RPM (no per-fan power), so this is a MODEL: fan power ∝ RPM³
# (fan affinity law), calibrated to the 2026-06-05 power sweep — fits within ~3W
# (~2W @4800rpm · ~17W @9360 · ~42W @12720 · ~99W @16920). Integer: 0.0205·(rpm/1e3)³.
fc_fan_watts() { echo $(( $1 * $1 * $1 * 205 / 10000000000000 )); }

# ---- side-effecting wrappers ----

ipmi_manual_on=0

set_manual() {  # <pct>
  local pct="$1" hex; hex="$(fc_pct_to_hex "$pct")"
  if (( DRY_RUN == 1 )); then log "DRY set fan ${pct}% (${hex})"; ipmi_manual_on=1; return 0; fi
  if (( ipmi_manual_on == 0 )); then
    "$IPMITOOL" raw 0x30 0x30 0x01 0x00 >/dev/null 2>&1 || return 1
    ipmi_manual_on=1
  fi
  "$IPMITOOL" raw 0x30 0x30 0x02 0xff "$hex" >/dev/null 2>&1
}

restore_auto() {
  if (( DRY_RUN == 1 )); then log "DRY restore Dell auto fan control"; ipmi_manual_on=0; return 0; fi
  "$IPMITOOL" raw 0x30 0x30 0x01 0x01 >/dev/null 2>&1
  ipmi_manual_on=0
}

read_cpu_temp() {
  fc_parse_temp "$("$IPMITOOL" sdr type temperature 2>/dev/null | grep -E '^Temp ' | head -1)"
}

read_fan_rpm() {  # mean RPM across all 6 chassis fans (Fan1..Fan6). All fans run
                  # one global duty, so the mean is representative AND a single
                  # stalled fan won't skew it. Telemetry only — not a control input.
  "$IPMITOOL" sdr type fan 2>/dev/null | awk -F'|' '
    /^Fan[0-9]/ { gsub(/[^0-9]/, "", $5); if ($5 != "") { sum += $5; n++ } }
    END { if (n > 0) printf "%d\n", (sum / n) + 0.5 }'
}

# ha_command_pct -> the HA-computed fan % (0..100 int), or EMPTY when HA is
# disabled/unreachable, the value is non-numeric, or the command is STALE
# (last_updated older than STALE_SECS). Empty => caller hands fans to Dell auto.
ha_command_pct() {
  [[ -z "$HA_TOKEN" ]] && return 0
  local resp state lu lu_epoch now
  resp="$(curl -fsS --max-time 5 -H "Authorization: Bearer $HA_TOKEN" \
            "$HA_URL/api/states/$COMMAND_ENTITY" 2>/dev/null)" || return 0
  state="$(fc_json_str_field "$resp" state)"
  [[ "$state" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 0
  lu="$(fc_json_str_field "$resp" last_updated)"
  lu_epoch="$(date -d "$lu" +%s 2>/dev/null || echo 0)"; now="$(date +%s)"
  (( lu_epoch == 0 )) && return 0
  fc_fresh "$((now - lu_epoch))" "$STALE_SECS" || return 0
  fc_num "$state" 0 0 100
}

push_metrics() {  # <temp> <pct> <mode> <ha_ok> <fallback> [fan_rpm] [fan_watts_est]
  [[ -z "$PUSHGATEWAY_URL" ]] && return 0
  local mode_num; case "$3" in applied) mode_num=2;; *) mode_num=0;; esac
  curl -fsS --max-time 5 --data-binary @- \
    "$PUSHGATEWAY_URL/metrics/job/fan_control/instance/pve-r730" >/dev/null 2>&1 <<EOF || true
# TYPE pve_fan_control_cpu_temp_celsius gauge
pve_fan_control_cpu_temp_celsius $1
# TYPE pve_fan_control_fan_percent gauge
pve_fan_control_fan_percent $2
# TYPE pve_fan_control_mode gauge
pve_fan_control_mode $mode_num
# TYPE pve_fan_control_ha_reachable gauge
pve_fan_control_ha_reachable $4
# TYPE pve_fan_control_fallback gauge
pve_fan_control_fallback $5
# TYPE pve_fan_control_fan_rpm gauge
pve_fan_control_fan_rpm ${6:-0}
# TYPE pve_fan_control_fan_watts_est gauge
pve_fan_control_fan_watts_est ${7:-0}
EOF
}

main() {
  log "fan-control start (actuator; loop=${LOOP_INTERVAL}s ceiling=${CEILING}C cmd=${COMMAND_ENTITY} stale=${STALE_SECS}s dry_run=${DRY_RUN})"
  trap 'log "exit — restoring Dell auto fan control"; restore_auto' EXIT
  local current=-1 fails=0 in_fallback=0 cool_since=0 ha_down=0
  while true; do
    local rpm fan_w; rpm="$(read_fan_rpm)"; rpm="${rpm:-0}"; fan_w="$(fc_fan_watts "$rpm")"

    local temp; temp="$(read_cpu_temp)"
    if [[ -z "$temp" ]]; then
      fails=$((fails + 1)); log "WARN cannot read CPU temp ($fails/$MAX_IPMI_FAILS)"
      if (( fails >= MAX_IPMI_FAILS )); then log "ERR temp unreadable — Dell auto"; restore_auto; current=-1; fi
      (( RUN_ONCE == 1 )) && break || { sleep "$LOOP_INTERVAL"; continue; }
    fi
    fails=0

    # Hardware ceiling — independent of HA; firmware emergency cooling takes over.
    if (( temp >= CEILING )); then
      (( in_fallback == 0 )) && { log "CEILING temp=${temp}≥${CEILING} — Dell auto"; restore_auto; current=-1; in_fallback=1; }
      push_metrics "$temp" 0 fallback 1 1 "$rpm" "$fan_w"
      (( RUN_ONCE == 1 )) && break || { sleep "$LOOP_INTERVAL"; continue; }
    fi
    if (( in_fallback == 1 )); then
      if (( temp < RESUME_BELOW )); then
        (( cool_since == 0 )) && cool_since="$(date +%s)"
        if (( $(date +%s) - cool_since >= RESUME_STABLE )); then
          log "recovered (temp<${RESUME_BELOW}C ${RESUME_STABLE}s) — resuming HA control"; in_fallback=0; cool_since=0
        else
          push_metrics "$temp" 0 fallback 1 1 "$rpm" "$fan_w"; (( RUN_ONCE == 1 )) && break || { sleep "$LOOP_INTERVAL"; continue; }
        fi
      else
        cool_since=0; push_metrics "$temp" 0 fallback 1 1 "$rpm" "$fan_w"
        (( RUN_ONCE == 1 )) && break || { sleep "$LOOP_INTERVAL"; continue; }
      fi
    fi

    # The setpoint is whatever HA computed. No local math — just apply it.
    local cmd; cmd="$(ha_command_pct)"
    if [[ -z "$cmd" ]]; then
      (( ha_down == 0 )) && { log "HA command unavailable/stale — Dell auto until it returns"; restore_auto; current=-1; ha_down=1; }
      push_metrics "$temp" 0 fallback 0 1 "$rpm" "$fan_w"
      (( RUN_ONCE == 1 )) && break || { sleep "$LOOP_INTERVAL"; continue; }
    fi
    (( ha_down == 1 )) && { log "HA command back (${cmd}%) — resuming"; ha_down=0; }

    # Only write when first-run or the change clears MIN_STEP (kills 1-2% jitter).
    if (( current < 0 || cmd - current >= MIN_STEP || current - cmd >= MIN_STEP )); then
      if set_manual "$cmd"; then log "temp=${temp}C cmd=${cmd}% rpm=${rpm} (was ${current}%)"; current="$cmd"
      else log "WARN set_manual ${cmd}% failed"; fi
    fi
    push_metrics "$temp" "$current" applied 1 0 "$rpm" "$fan_w"
    (( RUN_ONCE == 1 )) && break || sleep "$LOOP_INTERVAL"
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
