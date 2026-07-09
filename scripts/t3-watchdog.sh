#!/usr/bin/env bash
# t3-watchdog.sh — minutely wedge watchdog for t3-serve@<user> (via t3-watchdog.timer).
#
# WHY: OOMPolicy=continue (the settled 2026-06-10 decision — a runaway agent child
# dies, the server survives) leaves a gap: the surviving main process is sometimes
# WOUNDED — it drops its HTTP listener (2026-07-08: ~2h listener-less zombie after
# two cgroup OOM kills) or livelocks with the port open (2026-07-02 class). The unit
# stays "active", so Restart=on-failure never fires. This watchdog probes each
# instance's local port and safe-restarts confirmed-wedged ones, loudly.
#
# GATES (all must hold): unit active; up >WD_GRACE_SECONDS (don't judge a booting
# instance); WD_FAILS_REQUIRED consecutive failed probes (ride out blips); fewer
# than WD_MAX_RESTARTS watchdog restarts in the trailing WD_WINDOW_SECONDS — at the
# cap it logs WATCHDOG-EXHAUSTED (-> critical Loki alert) and stands down.
# DELIBERATELY NOT GATED on the idle/active-turn check (a dead port means every
# session is already broken) nor on /etc/t3-autoupdate.freeze (freeze is VERSION
# policy; this re-execs the already-installed binary). Design + rationale:
# docs/plans/2026-07-08-t3-watchdog-design.md. Runbook: docs/runbooks/t3-watchdog.md.
set -uo pipefail

LOG_TAG=t3-watchdog
# shellcheck source=scripts/t3-safe-restart.sh
. "${T3_SAFE_RESTART_LIB:-/usr/local/lib/t3-safe-restart.sh}"

WD_STATE_DIR="${T3_WD_STATE_DIR:-/run/t3-watchdog}"     # tmpfs: fresh counters after boot (deliberate)
WD_GRACE_SECONDS="${T3_WD_GRACE_SECONDS:-120}"
WD_FAILS_REQUIRED="${T3_WD_FAILS_REQUIRED:-3}"
WD_MAX_RESTARTS="${T3_WD_MAX_RESTARTS:-3}"
WD_WINDOW_SECONDS="${T3_WD_WINDOW_SECONDS:-1800}"
WD_PROBE_TIMEOUT="${T3_WD_PROBE_TIMEOUT:-10}"           # also what catches the livelock class

# T3_PORT from env-file text on stdin (last assignment wins; tolerates quotes).
parse_port() {
  sed -n "s/^[[:space:]]*T3_PORT=[\"']\{0,1\}\([0-9][0-9]*\)[\"']\{0,1\}[[:space:]]*$/\1/p" | tail -1
}

# Count ledger epochs (stdin, one per line) strictly inside (now-WINDOW, now].
restarts_in_window() {
  local now="$1" n=0 e
  while IFS= read -r e; do
    case "$e" in ''|*[!0-9]*) continue;; esac
    [ "$e" -gt $((now - WD_WINDOW_SECONDS)) ] && n=$((n+1))
  done
  echo "$n"
}

# gate_should_restart <active_state> <uptime_s> <fails> <restarts_in_window>
# rc 0 = restart now; rc 1 = hold off; rc 2 = still wedged but at the flap cap.
# Unparseable input -> rc 1 (fail closed: do nothing rather than restart blind).
gate_should_restart() {
  local active="$1" uptime="$2" fails="$3" recent="$4"
  [ "$active" = "active" ] || return 1
  case "$uptime" in ''|*[!0-9]*) return 1;; esac
  [ "$uptime" -gt "$WD_GRACE_SECONDS" ] || return 1
  case "$fails" in ''|*[!0-9]*) return 1;; esac
  [ "$fails" -ge "$WD_FAILS_REQUIRED" ] || return 1
  case "$recent" in ''|*[!0-9]*) return 1;; esac
  [ "$recent" -lt "$WD_MAX_RESTARTS" ] || return 2
  return 0
}

main() {
  mkdir -p "$WD_STATE_DIR"
  local unit u port code rc fails now started uptime recent reason
  # safe_restart_unit contract: $target (version moved to — here: what's installed,
  # used in backup filenames/logs) and $last_good (its rollback target — equal to
  # installed outside a mid-update window, making rollback a no-op reinstall).
  target="$(ver)"
  [ -n "$target" ] || { LOG "cannot read t3 version — skipping sweep"; return 0; }
  last_good="$(tr -d '[:space:]' <"$LAST_GOOD_FILE" 2>/dev/null)"
  [ -n "$last_good" ] || last_good="$target"

  for unit in $(systemctl list-units --type=service --state=running --no-legend 't3-serve@*' 2>/dev/null | awk '{print $1}'); do
    u="$(printf '%s' "$unit" | sed -n 's/^t3-serve@\(.*\)\.service$/\1/p')"; [ -n "$u" ] || continue
    port=""
    [ -r "/etc/t3-serve/$u.env" ] && port="$(parse_port <"/etc/t3-serve/$u.env")"
    [ -n "$port" ] || { LOG "no T3_PORT for $u in /etc/t3-serve/$u.env — skipping (provisioning problem, not a wedge)"; continue; }

    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$WD_PROBE_TIMEOUT" "http://127.0.0.1:$port/" 2>/dev/null)"; rc=$?
    if [ "$code" = "200" ]; then rm -f "$WD_STATE_DIR/$u.fails"; continue; fi

    fails="$(cat "$WD_STATE_DIR/$u.fails" 2>/dev/null || echo 0)"
    case "$fails" in ''|*[!0-9]*) fails=0;; esac
    fails=$((fails+1)); printf '%s\n' "$fails" >"$WD_STATE_DIR/$u.fails"
    case "$rc" in 7) reason="connection-refused";; 28) reason="timeout";; *) reason="http=$code(curl=$rc)";; esac

    now="$(date +%s)"
    started="$(date -d "$(systemctl show -p ActiveEnterTimestamp --value "$unit" 2>/dev/null)" +%s 2>/dev/null || echo '')"
    if [ -n "$started" ]; then uptime=$((now - started)); else uptime=""; fi
    if [ -f "$WD_STATE_DIR/$u.restarts" ]; then
      recent="$(restarts_in_window "$now" <"$WD_STATE_DIR/$u.restarts")"
    else
      recent=0
    fi
    LOG "probe FAILED for $unit (port=$port reason=$reason consecutive=$fails uptime=${uptime:-?}s recent_restarts=$recent)"

    gate_should_restart "$(systemctl is-active "$unit" 2>/dev/null)" "$uptime" "$fails" "$recent"
    case $? in
      0) : ;;
      2) LOG "WATCHDOG-EXHAUSTED: $unit still unhealthy but hit the flap cap ($WD_MAX_RESTARTS restarts/${WD_WINDOW_SECONDS}s) — standing down, human needed"; continue ;;
      *) continue ;;
    esac

    printf '%s\n' "$now" >>"$WD_STATE_DIR/$u.restarts"   # cap counts ATTEMPTS
    if ! backup_user "$u" >/dev/null; then
      # Unlike t3-migrate-idle (healthy instance, waiting is free) we proceed:
      # the instance is DOWN; recovery-restore degrades to an older snapshot.
      LOG "WARN: pre-restart backup FAILED for $u — proceeding anyway (instance is down)"
    fi
    if safe_restart_unit "$unit" "$u"; then
      LOG "WATCHDOG: restarted $unit (reason=$reason) — recovered, pairing verified"
    else
      LOG "WATCHDOG: restart of $unit FAILED verification — safe_restart_unit ran recovery (DB restore + freeze); see its log lines"
    fi
    rm -f "$WD_STATE_DIR/$u.fails"   # fresh process gets a clean slate + grace window
  done
}

# main-guard: run only when executed, not when sourced (tests source this file).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
