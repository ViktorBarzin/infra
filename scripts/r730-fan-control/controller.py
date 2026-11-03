#!/usr/bin/env python3
"""R730 fan-control CronJob actuator (runs once per invocation).

Pulls desired state from Home Assistant, reads CPU temp / fan RPM from the iDRAC
over IPMI-over-LAN, computes the target with fan_logic.plan_fan, sets the fans,
and pushes metrics to the Pushgateway. Stateless: hysteresis uses the read-back
fan RPM. Safety: CPU>=CEILING hands fans back to Dell auto; the iDRAC's own
thermal protection + a Prometheus staleness alert are the backstops.
"""
import logging
import os
import subprocess
import sys
import time

import requests

import fan_logic as fl

log = logging.getLogger("fan-control")

IDRAC_HOST = os.environ.get("IDRAC_HOST", "192.168.1.4")
IDRAC_USER = os.environ.get("IDRAC_USER", "root")
IDRAC_PASS = os.environ.get("IDRAC_PASS", "")
HA_URL = os.environ.get("HA_URL", "http://192.168.1.8:8123").rstrip("/")
HA_TOKEN = os.environ.get("HA_TOKEN", "")
MODE_ENTITY = os.environ.get("MODE_ENTITY", "input_select.r730_fan_mode")
MANUAL_ENTITY = os.environ.get("MANUAL_ENTITY", "input_number.r730_fan_manual_pct")
GARAGE_ENTITY = os.environ.get("GARAGE_ENTITY", "sensor.garage_door_state_bg")
GARAGE_OPEN_STATE = os.environ.get("GARAGE_OPEN_STATE", "Отворена")
HOLD_SECS = int(os.environ.get("HOLD_SECS", "900"))
DEADBAND = int(os.environ.get("DEADBAND", "3"))
CEILING = int(os.environ.get("CEILING", "83"))
PUSHGATEWAY_URL = os.environ.get("PUSHGATEWAY_URL", "http://10.0.20.100:30091").rstrip("/")
DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"

MODE_NUM = {"fallback": 0, "quiet": 1, "cool": 2, "manual": 3}


def ipmi(*args: str) -> str:
    env = dict(os.environ, IPMI_PASSWORD=IDRAC_PASS)
    cmd = ["ipmitool", "-I", "lanplus", "-H", IDRAC_HOST, "-U", IDRAC_USER, "-E", *args]
    return subprocess.run(cmd, env=env, capture_output=True, text=True,
                          timeout=15, check=True).stdout


def _first_int(text: str, needle: str) -> int | None:
    for line in text.splitlines():
        if line.startswith(needle):
            for tok in line.split("|")[-1].split():
                if tok.isdigit():
                    return int(tok)
    return None


def read_sensors() -> tuple[int, int, int]:
    temp = _first_int(ipmi("sdr", "type", "temperature"), "Temp ")
    rpm = _first_int(ipmi("sdr", "type", "fan"), "Fan1")
    watts = next((int(t) for t in ipmi("dcmi", "power", "reading").split()
                  if t.isdigit()), 0)
    if temp is None or rpm is None:
        raise RuntimeError(f"unparseable sensors temp={temp} rpm={rpm}")
    return temp, rpm, watts


def set_manual(pct: int) -> None:
    if DRY_RUN:
        log.info("DRY set fan %d%%", pct)
        return
    ipmi("raw", "0x30", "0x30", "0x01", "0x00")
    ipmi("raw", "0x30", "0x30", "0x02", "0xff", fl.pct_to_ipmi_hex(pct))


def restore_auto() -> None:
    if DRY_RUN:
        log.info("DRY restore Dell auto")
        return
    ipmi("raw", "0x30", "0x30", "0x01", "0x01")


def ha_state(entity: str) -> tuple[str, float] | None:
    try:
        r = requests.get(f"{HA_URL}/api/states/{entity}", timeout=6,
                         headers={"Authorization": f"Bearer {HA_TOKEN}"})
        r.raise_for_status()
        d = r.json()
        lc = d.get("last_changed", "")
        epoch = time.mktime(time.strptime(lc[:19], "%Y-%m-%dT%H:%M:%S")) if lc else time.time()
        return d["state"], epoch
    except Exception as e:  # noqa: BLE001 - HA optional; degrade to safe defaults
        log.warning("HA read %s failed: %s", entity, e)
        return None


def desired() -> tuple[str, int, str]:
    """(mode, manual_pct, presence). HA-unreachable degrades to auto/cool (safe)."""
    mode_state = ha_state(MODE_ENTITY)
    mode = (mode_state[0] if mode_state else "auto").lower()
    if mode not in ("auto", "cool", "quiet", "manual"):
        mode = "auto"
    manual_pct = 0
    if mode == "manual":
        m = ha_state(MANUAL_ENTITY)
        manual_pct = int(float(m[0])) if m else 0
    presence = "cool"
    if mode == "auto":
        g = ha_state(GARAGE_ENTITY)
        presence = fl.presence_mode(g[0], g[1], time.time(), HOLD_SECS,
                                    GARAGE_OPEN_STATE) if g else "cool"
    return mode, manual_pct, presence


def push_metrics(**kv: float) -> None:
    body = "".join(f"# TYPE pve_fan_control_{k} gauge\npve_fan_control_{k} {v}\n"
                   for k, v in kv.items())
    try:
        requests.post(f"{PUSHGATEWAY_URL}/metrics/job/fan_control/instance/r730-cron",
                      data=body.encode(), timeout=6).raise_for_status()
    except Exception as e:  # noqa: BLE001
        log.warning("pushgateway failed: %s", e)


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    try:
        temp, rpm, watts = read_sensors()
    except Exception as e:  # noqa: BLE001 - cannot read => do not touch fans; alert via staleness/ipmi_ok
        log.error("IPMI read failed, leaving fans untouched: %s", e)
        push_metrics(ipmi_ok=0, last_run_timestamp=time.time())
        return 1

    mode, manual_pct, presence = desired()
    action, pct = fl.plan_fan(mode, temp, manual_pct, presence,
                              fl.rpm_to_pct(rpm), DEADBAND, CEILING)

    if action == "auto":
        restore_auto()
        eff = "fallback"
        set_pct = 0
    else:
        set_manual(pct)
        eff = presence if mode == "auto" else mode if mode != "manual" else "manual"
        set_pct = pct

    log.info("temp=%dC rpm=%d watts=%d desired=%s presence=%s -> %s %d%%",
             temp, rpm, watts, mode, presence, action, set_pct)
    push_metrics(cpu_temp_celsius=temp, fan_percent=set_pct, fan_rpm=rpm,
                 watts=watts, fan_watts_est=fl.fan_watts(rpm),
                 mode=MODE_NUM.get(eff, 0), ceiling=int(action == "auto"),
                 ipmi_ok=1, last_run_timestamp=time.time())
    return 0


if __name__ == "__main__":
    sys.exit(main())
