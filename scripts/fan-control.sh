#!/usr/bin/env bash
# Presence-aware IPMI fan controller for the Dell R730 PVE host (192.168.1.127).
#
# The server lives in the GARAGE (memory id=1723). Two curves, picked by
# whether someone is physically in the garage:
#   - COOL  : garage empty -> minimise CPU temp, noise is free.
#   - QUIET : someone in the garage -> minimise noise, accept a warmer CPU.
# Presence comes from the ha-sofia garage-door sensor: door open now, OR it
# last changed within HOLD_SECS, => QUIET. Otherwise COOL.
#
# Safety (manual fan mode bypasses the iDRAC's own curve, so we backstop it):
#   - On ANY exit (crash/stop/TERM) the EXIT trap hands fans back to Dell
#     automatic control (raw 0x30 0x30 0x01 0x01). systemd ExecStopPost
#     repeats this belt-and-suspenders.
#   - CPU >= CEILING -> hand back to Dell auto until it recovers (RESUME_BELOW
#     held for RESUME_STABLE s). The firmware's own emergency cooling takes over.
#   - IPMI read failures (>= MAX_IPMI_FAILS) -> hand back to Dell auto.
#
# Deploy: scp to /usr/local/bin/fan-control (strip .sh) + install
# fan-control.service + /etc/fan-control.env. Same pattern as apply-mbps-caps.
# Tests: test-fan-control.sh (sources this file, exercises the pure functions).
# Design: infra/docs/plans/2026-06-04-pve-fan-control-design.md
# Runbook: infra/docs/runbooks/fan-control.md

set -uo pipefail

# ---- configuration (override via /etc/fan-control.env) ----
: "${IPMITOOL:=ipmitool}"
: "${LOOP_INTERVAL:=15}"             # seconds between temperature decisions
: "${PRESENCE_INTERVAL:=30}"         # seconds between ha-sofia garage-door polls
: "${DEADBAND:=3}"                   # degC hysteresis applied to downward fan steps
: "${CEILING:=83}"                   # degC: hand back to Dell auto at/above this
: "${RESUME_BELOW:=75}"              # degC: eligible to resume manual below this...
: "${RESUME_STABLE:=120}"            # ...once held that long
: "${HOLD_SECS:=900}"                # quiet-mode hold after last garage activity (15 min)
: "${HA_URL:=http://192.168.1.8:8123}"
: "${HA_TOKEN:=}"                    # long-lived ha-sofia token; empty => presence disabled (COOL only)
: "${GARAGE_ENTITY:=sensor.garage_door_state_bg}"
: "${GARAGE_OPEN_STATE:=Отворена}"   # ha state string meaning "open"
# HA control: a mode select + manual % the user drives from Home Assistant.
# auto => garage-presence curve (default); cool/quiet => force that curve;
# manual => hold MANUAL_ENTITY %. Empty HA_TOKEN or unreachable HA => auto.
: "${MODE_ENTITY:=input_select.r730_fan_mode}"
: "${MANUAL_ENTITY:=input_number.r730_fan_manual_pct}"
: "${PUSHGATEWAY_URL:=}"             # optional Prometheus Pushgateway base URL
: "${MAX_IPMI_FAILS:=3}"
: "${DRY_RUN:=0}"                    # 1 => log IPMI actions instead of executing
: "${RUN_ONCE:=0}"                   # 1 => one iteration then exit (testing)

# Continuous LINEAR fan curve (2026-06-05): fan% ramps proportionally with CPU
# temp between (T_LO,P_LO) and (T_HI,P_HI), clamped flat outside. Replaces the old
# discrete step-bands (which flapped at band edges — e.g. 45<->65%). Both modes
# reach 100% right at the 83°C ceiling. Anchors are env-tunable.
#   COOL  (garage empty):  30% @50°C .. 100% @83°C  (~2.1%/°C; equilibrium ~60°C/~51%)
#   QUIET (someone there): 20% @68°C .. 100% @83°C  (near-silent until ~70°C)
# Web-researched: a linear curve + 2-3°C hysteresis is the homelab standard; PID is
# overkill for this slow thermal loop. See docs/plans/2026-06-04-pve-fan-control-design.md.
: "${COOL_T_LO:=50}"; : "${COOL_P_LO:=30}"; : "${COOL_T_HI:=83}"; : "${COOL_P_HI:=100}"
: "${QUIET_T_LO:=68}"; : "${QUIET_P_LO:=20}"; : "${QUIET_T_HI:=83}"; : "${QUIET_P_HI:=100}"
: "${MIN_STEP:=3}"   # min fan-% change worth an IPMI write (anti-jitter on the smooth curve)

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }

# ---- pure functions (no side effects; unit-tested) ----

# fc_curve <mode> <temp> -> fan percent (continuous linear interpolation between
# the per-mode (T_LO,P_LO)..(T_HI,P_HI) anchors; clamped flat outside the range).
fc_curve() {
  local mode="$1" temp="$2" tlo plo thi phi
  if [[ "$mode" == "quiet" ]]; then tlo=$QUIET_T_LO; plo=$QUIET_P_LO; thi=$QUIET_T_HI; phi=$QUIET_P_HI
  else tlo=$COOL_T_LO; plo=$COOL_P_LO; thi=$COOL_T_HI; phi=$COOL_P_HI; fi
  if (( temp <= tlo )); then echo "$plo"; return 0; fi
  if (( temp >= thi )); then echo "$phi"; return 0; fi
  echo $(( plo + ( (temp - tlo) * (phi - plo) + (thi - tlo) / 2 ) / (thi - tlo) ))  # rounded
}

# fc_decide <mode> <temp> <current_pct> <deadband> -> fan percent
# Ramps up immediately; only steps down once the curve still wants a lower
# percent even DEADBAND degrees hotter (prevents flapping at band edges).
fc_decide() {
  local mode="$1" temp="$2" current="$3" deadband="$4" target
  target="$(fc_curve "$mode" "$temp")"
  if (( current < 0 || target >= current )); then echo "$target"; return 0; fi
  if (( $(fc_curve "$mode" "$((temp + deadband))") < current )); then echo "$target"; else echo "$current"; fi
}

# fc_presence_mode <state> <last_changed_epoch> <now_epoch> <hold_secs> <open_state> -> quiet|cool
fc_presence_mode() {
  local state="$1" lc="$2" now="$3" hold="$4" open="$5"
  if [[ "$state" == "$open" ]]; then echo "quiet"; return 0; fi
  if (( now - lc < hold )); then echo "quiet"; return 0; fi
  echo "cool"
}

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

# fc_resolve <ha_mode> <temp> <manual_pct> <presence> <current> <deadband> -> pct
# HA mode resolution (the hard ceiling is handled by the caller):
#   manual      -> clamp(manual_pct), no hysteresis
#   cool|quiet  -> that curve (with hysteresis)
#   auto (else) -> presence-driven curve (garage door)
fc_resolve() {
  local ha_mode="$1" temp="$2" manual_pct="$3" presence="$4" current="$5" deadband="$6"
  if [[ "$ha_mode" == "manual" ]]; then fc_clamp "$manual_pct"; return 0; fi
  local eff; [[ "$ha_mode" == "auto" ]] && eff="$presence" || eff="$ha_mode"
  fc_decide "$eff" "$temp" "$current" "$deadband"
}

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

read_fan_rpm() {  # Fan1 RPM — representative (all 6 fans are set together)
  "$IPMITOOL" sdr type fan 2>/dev/null | awk -F'|' '/^Fan1/{gsub(/[^0-9]/,"",$5); print $5+0; exit}'
}

presence_cache="cool"; presence_ts=0
get_presence() {
  local now; now="$(date +%s)"
  if (( now - presence_ts < PRESENCE_INTERVAL )); then echo "$presence_cache"; return 0; fi
  presence_ts="$now"
  [[ -z "$HA_TOKEN" ]] && { echo "$presence_cache"; return 0; }
  local resp state lc_iso lc_epoch
  resp="$(curl -fsS --max-time 5 -H "Authorization: Bearer $HA_TOKEN" \
            "$HA_URL/api/states/$GARAGE_ENTITY" 2>/dev/null)" || { echo "$presence_cache"; return 0; }
  state="$(fc_json_str_field "$resp" state)"
  [[ -z "$state" ]] && { echo "$presence_cache"; return 0; }
  lc_iso="$(fc_json_str_field "$resp" last_changed)"
  lc_epoch="$(date -d "$lc_iso" +%s 2>/dev/null || echo "$now")"
  presence_cache="$(fc_presence_mode "$state" "$lc_epoch" "$now" "$HOLD_SECS" "$GARAGE_OPEN_STATE")"
  echo "$presence_cache"
}

# ha_entity_state <entity> -> state string (empty if HA disabled/unreachable)
ha_entity_state() {
  [[ -z "$HA_TOKEN" ]] && return 0
  local resp
  resp="$(curl -fsS --max-time 5 -H "Authorization: Bearer $HA_TOKEN" \
            "$HA_URL/api/states/$1" 2>/dev/null)" || return 0
  fc_json_str_field "$resp" state
}

push_metrics() {  # <temp> <pct> <mode> <ha_ok> <fallback> [fan_rpm] [fan_watts_est]
  [[ -z "$PUSHGATEWAY_URL" ]] && return 0
  local mode_num; case "$3" in quiet) mode_num=1;; cool) mode_num=2;; manual) mode_num=3;; *) mode_num=0;; esac
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
  log "fan-control start (loop=${LOOP_INTERVAL}s presence=${PRESENCE_INTERVAL}s hold=${HOLD_SECS}s ceiling=${CEILING}C dry_run=${DRY_RUN})"
  trap 'log "exit — restoring Dell auto fan control"; restore_auto' EXIT
  local current=-1 fails=0 in_fallback=0 cool_since=0
  while true; do
    local temp; temp="$(read_cpu_temp)"
    if [[ -z "$temp" ]]; then
      fails=$((fails + 1)); log "WARN cannot read CPU temp ($fails/$MAX_IPMI_FAILS)"
      if (( fails >= MAX_IPMI_FAILS )); then log "ERR temp unreadable — Dell auto"; restore_auto; current=-1; fi
      (( RUN_ONCE == 1 )) && break || { sleep "$LOOP_INTERVAL"; continue; }
    fi
    fails=0

    if (( temp >= CEILING )); then
      (( in_fallback == 0 )) && { log "CEILING temp=${temp}≥${CEILING} — Dell auto"; restore_auto; current=-1; in_fallback=1; }
      push_metrics "$temp" 0 fallback 1 1
      (( RUN_ONCE == 1 )) && break || { sleep "$LOOP_INTERVAL"; continue; }
    fi
    if (( in_fallback == 1 )); then
      if (( temp < RESUME_BELOW )); then
        (( cool_since == 0 )) && cool_since="$(date +%s)"
        if (( $(date +%s) - cool_since >= RESUME_STABLE )); then
          log "recovered (temp<${RESUME_BELOW}C ${RESUME_STABLE}s) — resuming manual"; in_fallback=0; cool_since=0
        else
          push_metrics "$temp" 0 fallback 1 1; (( RUN_ONCE == 1 )) && break || { sleep "$LOOP_INTERVAL"; continue; }
        fi
      else
        cool_since=0; push_metrics "$temp" 0 fallback 1 1
        (( RUN_ONCE == 1 )) && break || { sleep "$LOOP_INTERVAL"; continue; }
      fi
    fi

    # HA-desired mode (auto/cool/quiet/manual); unreachable/unset => auto.
    local ha_mode ha_ok=1; ha_mode="$(ha_entity_state "$MODE_ENTITY")"; [[ -z "$HA_TOKEN" ]] && ha_ok=0
    [[ -z "$ha_mode" ]] && ha_mode="auto"
    case "$ha_mode" in auto|cool|quiet|manual) ;; *) ha_mode="auto" ;; esac
    local manual_pct=0
    if [[ "$ha_mode" == "manual" ]]; then
      manual_pct="$(ha_entity_state "$MANUAL_ENTITY")"; manual_pct="${manual_pct%%.*}"
      [[ "$manual_pct" =~ ^[0-9]+$ ]] || manual_pct=0
    fi
    local presence="cool"; [[ "$ha_mode" == "auto" ]] && presence="$(get_presence)"
    local eff; if [[ "$ha_mode" == "manual" ]]; then eff="manual"; elif [[ "$ha_mode" == "auto" ]]; then eff="$presence"; else eff="$ha_mode"; fi
    local pct; pct="$(fc_resolve "$ha_mode" "$temp" "$manual_pct" "$presence" "$current" "$DEADBAND")"
    # Only write when first-run or the change clears MIN_STEP (kills 1-2% jitter
    # on the continuous curve; fc_decide already gives asymmetric hysteresis).
    if (( current < 0 || pct - current >= MIN_STEP || current - pct >= MIN_STEP )); then
      if set_manual "$pct"; then log "temp=${temp}C ha_mode=${ha_mode} eff=${eff} fan=${pct}% (was ${current}%)"; current="$pct"
      else log "WARN set_manual ${pct}% failed"; fi
    fi
    local rpm fan_w; rpm="$(read_fan_rpm)"; rpm="${rpm:-0}"; fan_w="$(fc_fan_watts "$rpm")"
    push_metrics "$temp" "$current" "$eff" "$ha_ok" 0 "$rpm" "$fan_w"
    (( RUN_ONCE == 1 )) && break || sleep "$LOOP_INTERVAL"
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
