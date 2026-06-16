# Runbook — PVE R730 fan control

**The control logic lives in Home Assistant; the PVE host runs only a thin
actuator.** HA computes the fan setpoint from the CPU temperature and the
dashboard inputs and publishes ONE number, `sensor.r730_fan_command_pct`. The
host daemon reads that number each loop and applies it over IPMI — it does **no**
math. Design + history: `infra/docs/plans/2026-06-04-pve-fan-control-design.md`.

> **History:** (1) 2026-06-04/05 presence-aware two-curve controller (COOL/QUIET
> by garage door). (2) 2026-06-07 single linear curve, presence removed.
> (3) 2026-06-08 **all control moved into HA**, host became a thin actuator,
> additive **bias** replaced the ease-down hysteresis. (4) 2026-06-15 daemon
> **anti-flap**: holds the last command through transient HA losses instead of
> dumping to Dell auto.

## What it is

- **HA (brain), on ha-sofia — NOT in this repo:** the `input_number` sliders, the
  command template sensor, the display/equilibrium sensors, the Lock/Override
  controls, and the dashboard cards. Auto-git-tracked on ha-sofia by the
  version-control add-on.
- `/usr/local/bin/fan-control` — bash **actuator** (source: `infra/scripts/fan-control.sh`).
- `fan-control.service` — systemd unit (`Type=simple`, restarts on failure).
- `/etc/fan-control.env` — config incl. the ha-sofia token (chmod 600, not in git).

## HA brain — where the curve lives (dashboard-it → "Server" view → Fans)

`sensor.r730_fan_command_pct` (template) computes:
`command% = clamp( curve(temp) + bias, 0..100 )`, where `curve(temp)` is a linear
ramp from `(Temp min, Duty min)` to `(Temp max, Duty max)` over
`sensor.r730_cpu_temperature`, plus an **asymmetric output deadband** (rise
immediately; ease down only once it would drop ≥ Hysteresis). When **Lock** is
on it outputs the Override % directly.

**Inputs** (`input_number` sliders): `r730_fan_temp_min`, `r730_fan_temp_max`,
`r730_fan_duty_min`, `r730_fan_duty_max`, `r730_fan_bias` (flat % added on top —
guarantees a floor), `r730_fan_hysteresis` (output deadband %).
Slope = `(Duty max − Duty min)/(Temp max − Temp min)` — steeper/higher-bias/lower-Temp-min
⇒ lower steady-state CPU temp (it's a P controller; the curve sets the equilibrium).

**Manual override:** `input_boolean.r730_fan_lock` (Lock — freeze) + `input_number.r730_fan_manual_pct` (Override %).

**Readout sensors:** `sensor.r730_fan_command_display` ("Fan set point", "X % (Y rpm)"),
`sensor.r730_expected_equilibrium_temp` (predicted equilibrium at current load),
`sensor.r730_cpu_load`, `sensor.r730_fan_speed_avg` (mean of 6 fans),
`sensor.r730_fan_power_avg` (cube-law estimate). The Prometheus-backed REST
sensors live in `rest_resources/idrac_redfish_exporter.yaml` on ha-sofia and have
value-template fallbacks so they don't blink `unavailable` on a transient empty.

## Actuator (host) — what the daemon does

Loop every ~15 s, using only the existing IPMI + HA-REST methods:
1. read `command%` from HA (`/api/states/$COMMAND_ENTITY`), validate (numeric + not stale > `STALE_SECS`);
2. apply it via `ipmitool raw 0x30 0x30 0x02 0xff 0x<NN>` (writes only if the change clears `MIN_STEP`);
3. read CPU temp + fan rpm for safety + telemetry (Pushgateway).

**Anti-flap:** on a missing/stale command it **holds the last applied %** for up
to `HA_GRACE_SECS` (300 s) instead of falling back; only sustained loss hands the
fans to Dell auto.

## Safety (on the host, independent of HA)
`CPU ≥ CEILING (83 °C)`, repeated IPMI failures, sustained HA loss, or daemon
stop/crash → hand the fans back to **Dell auto** (`raw 0x30 0x30 0x01 0x01`;
EXIT trap + systemd `ExecStopPost`). The 83 °C ceiling uses the daemon's own
IPMI temp read, so it protects even if HA is wrong/unreachable.

## Quick status
```bash
ssh root@192.168.1.127 systemctl status fan-control
ssh root@192.168.1.127 'journalctl -u fan-control -n 30 --no-pager'
```
Log line: `temp=64C cmd=49% rpm=9380 (was -1%)` (`cmd` = the % read from HA and
applied). `HA command miss — holding 49%` = a transient HA blip being ridden out;
`HA command lost (...) — Dell auto` = sustained loss.

## Tune
The whole curve (anchors + bias + hysteresis) is tuned **live from the HA
dashboard** — no host access needed. `/etc/fan-control.env` only holds the
actuator plumbing + safety knobs (`COMMAND_ENTITY`, `STALE_SECS`, `HA_GRACE_SECS`,
`MIN_STEP`, `CEILING`); edit it then `systemctl restart fan-control`.

## Deploy / update (daemon source)
```bash
scp -i ~/.ssh/pve_root scripts/fan-control.sh root@192.168.1.127:/tmp/fan-control.new
ssh -i ~/.ssh/pve_root root@192.168.1.127 'install -m0755 /tmp/fan-control.new /usr/local/bin/fan-control && systemctl restart fan-control'
```
(`fan-control.service` only on a unit change → also `systemctl daemon-reload`.)

## Symptoms & checks
| Symptom | Check |
|---------|-------|
| Fans surge then crash to ~7100 then surge | flapping to Dell auto — `journalctl -u fan-control \| grep -E 'holding\|Dell auto'`; pre-2026-06-15 this was the stale-command bug (now fixed). |
| Fans stuck loud | `journalctl` — `CEILING` breach or `HA command lost`? Check CPU temp + HA reachability. |
| A readout blinks `unavailable` | the REST value-template fallback should hold it; a 1×/8h blip at ~02:00 (backup window) is a benign fetch hiccup. |
| Slider changes ignored | does `sensor.r730_fan_command_pct` change in HA? token valid? |
| Box left in manual after crash | `ipmitool raw 0x30 0x30 0x01 0x01` to force Dell auto. |

## Verify wiring
```bash
ssh -i ~/.ssh/pve_root root@192.168.1.127 'set -a; . /etc/fan-control.env; set +a; RUN_ONCE=1 /usr/local/bin/fan-control'
```
The log `cmd=%` should equal `sensor.r730_fan_command_pct`. Move a slider so the
HA sensor changes, re-run, and the applied `cmd=%` should follow.
