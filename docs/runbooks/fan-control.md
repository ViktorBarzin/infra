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
> dumping to Dell auto. (5) 2026-10-05 **5-minute mean** as the curve input,
> freshness guard, minute pulse, HA hysteresis removed; **Simple PID Controller**
> installed alongside, switched off until tuned.

## What it is

- **HA (brain), on ha-sofia — NOT in this repo:** the `input_number` sliders, the
  command template sensor, the display/equilibrium sensors, the Lock/Override
  controls, and the dashboard cards. Auto-git-tracked on ha-sofia by the
  version-control add-on.
- `/usr/local/bin/fan-control` — bash **actuator** (source: `infra/scripts/fan-control.sh`).
- `fan-control.service` — systemd unit (`Type=simple`, restarts on failure).
- `/etc/fan-control.env` — config incl. the ha-sofia token (chmod 600, not in git).

## HA brain — where the curve lives (dashboard-it → "Server" view → Fans)

`sensor.r730_fan_command_pct` (template) computes, in order:

1. **Lock** on → the Override % directly.
2. **PI mode** — `input_boolean.r730_fan_use_pid` and `switch.r730_fan_pid_auto_mode`
   both on and the PI output available → `sensor.r730_fan_pid_pid_output`.
3. Otherwise the **curve**: `clamp( curve(t) + bias, 0..100 )`, a linear ramp from
   `(Temp min, Duty min)` to `(Temp max, Duty max)`.

**Input temperature (since 2026-10-05):** `t = max(5-min mean, raw − 5)`. The mean is
`sensor.r730_cpu_temperature_5min` (Statistics helper, `mean`, 5 min, no
`keep_last_sample`); the `raw − 5` term reacts immediately to a jump of more than 5 K.
Before this change the curve followed the raw integer reading, and the daemon's journal
showed 24.7 IPMI writes per hour with 64 % of them reversing direction within 5 minutes
(68 h, 2026-10-02..05); an open-loop replay of the same data with the mean predicts
about 4.6 writes per hour at the same average duty.

**Output format:** one decimal plus 0.01 on odd minutes. The pulse keeps
`last_updated` moving, so the daemon's `STALE_SECS` check never trips on a value that
is legitimately constant (smoothed output, or Lock, which previously fell to Dell auto
after ~35 min). The daemon truncates decimals, so the pulse never causes an IPMI write.
The former HA-side hysteresis was removed for the same reason; the daemon's
`MIN_STEP` (3 %) is the only deadband.

**Freshness guard:** when not locked, if `sensor.r730_cpu_temperature` has no value or
its `last_reported` is older than 150 s, the command is `-1`. HA accepts it as a
number, the daemon's regex rejects it, and the daemon takes its normal path (hold
300 s, then Dell auto). This matters because the REST value template renders the text
`unavailable` when the CPU series is missing from Prometheus; HA rejects that for a
numeric sensor and keeps the previous value, so without the guard the controller
would keep running on a frozen temperature. `sensor.r730_expected_equilibrium_temp`
treats a negative command as unknown.

**PI controller:** Simple PID Controller (HACS `bvweerd/simple_pid_controller`,
v1.6.1), instance "R730 Fan PID": input `sensor.r730_cpu_temperature_5min`, setpoint
60 °C, output 25–90 %, sample time 30 s, Kd 0, start mode "Last known value". Cooling
needs **negative** Kp and Ki. Tuning entities: `number.r730_fan_pid_{setpoint,kp,ki,kd,
output_min,output_max,sample_time,startup_value}`. Status 2026-10-05: installed with
auto mode off and gains 0, pending a step test and model-based tuning; the curve is
active. To switch on without a jump, set start mode "Startup value" with
`startup_value` = the current command, then auto mode on, then
`input_boolean.r730_fan_use_pid` on. Turning `input_boolean.r730_fan_use_pid` off
returns to the curve immediately.

**Inputs** (`input_number` sliders): `r730_fan_temp_min`, `r730_fan_temp_max`,
`r730_fan_duty_min`, `r730_fan_duty_max`, `r730_fan_bias` (flat % added on top —
guarantees a floor). `r730_fan_hysteresis` still exists but is no longer read.
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
`playbooks/pve-host.yml` installs `scripts/fan-control.sh` as
`/usr/local/bin/fan-control` and `scripts/fan-control.service` as the unit, and
restarts the daemon when either changes (since 2026-09-24; it was copied by hand
before that). Dry-run first:
```bash
ansible-playbook -i playbooks/inventory.ini playbooks/pve-host.yml --check --diff
ansible-playbook -i playbooks/inventory.ini playbooks/pve-host.yml
```
`/etc/fan-control.env` holds the ha-sofia token, stays out of git, and the
playbook leaves it alone. The script hands the token to curl through a file
descriptor (`-H @<(printf ...)`) rather than the command line, because snoopy
records every command line on this host and ships it to Loki.

## Symptoms & checks
| Symptom | Check |
|---------|-------|
| Fans surge then crash to ~7100 then surge | flapping to Dell auto — `journalctl -u fan-control \| grep -E 'holding\|Dell auto'`; pre-2026-06-15 this was the stale-command bug (now fixed). |
| Fans stuck loud | `journalctl` — `CEILING` breach or `HA command lost`? Check CPU temp + HA reachability. |
| A readout blinks `unavailable` | the REST value-template fallback should hold it; a 1×/8h blip at ~02:00 (backup window) is a benign fetch hiccup. |
| Slider changes ignored | does `sensor.r730_fan_command_pct` change in HA? token valid? |
| Command shows `-1` | the freshness guard: `sensor.r730_cpu_temperature` has no fresh reading (Prometheus / SNMP iDRAC scrape). The daemon holds 300 s, then Dell auto; it resumes on its own when readings return. |
| Box left in manual after crash | `ipmitool raw 0x30 0x30 0x01 0x01` to force Dell auto. |

## Verify wiring
```bash
ssh -i ~/.ssh/pve_root root@192.168.1.127 'set -a; . /etc/fan-control.env; set +a; RUN_ONCE=1 /usr/local/bin/fan-control'
```
The log `cmd=%` should equal `sensor.r730_fan_command_pct`. Move a slider so the
HA sensor changes, re-run, and the applied `cmd=%` should follow.
