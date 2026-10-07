# Runbook — PVE R730 fan control

**The control logic lives in Home Assistant; the PVE host runs only a thin
actuator.** A PID controller in HA turns the CPU temperature into a fan duty, and
HA publishes ONE number, `sensor.r730_fan_command_pct`. The host daemon reads that
number each loop and applies it over IPMI — it does **no** math. Design + history:
`infra/docs/plans/2026-06-04-pve-fan-control-design.md`.

> **History:** (1) 2026-06-04/05 presence-aware two-curve controller (COOL/QUIET
> by garage door). (2) 2026-06-07 single linear curve, presence removed.
> (3) 2026-06-08 **all control moved into HA**, host became a thin actuator,
> additive **bias** replaced the ease-down hysteresis. (4) 2026-06-15 daemon
> **anti-flap**: holds the last command through transient HA losses instead of
> dumping to Dell auto. (5) 2026-10-05 **5-minute mean** as the curve input,
> freshness guard, minute pulse, HA hysteresis removed; **Simple PID Controller**
> tuned from a step test and active the same day (setpoint 60 °C), the curve kept as
> the fallback. (6) 2026-10-07 **curve removed**: the PID is the only automatic mode,
> and Dell auto (through the daemon's hold-then-fallback path) takes over when the
> PID is off or has no output. Deleted: the curve sliders (`r730_fan_temp_min/max`,
> `r730_fan_duty_min/max`, `r730_fan_bias`, `r730_fan_hysteresis`),
> `input_boolean.r730_fan_use_pid`, `sensor.r730_expected_equilibrium_temp`,
> `input_select.r730_fan_mode` and the "R730 fan mode auto-revert" automation. Their
> last configuration is in `Claude shared/r730-fan-pid/backup-before-cleanup-2026-10-07.json`
> on the NAS.

## What it is

- **HA (brain), on ha-sofia — NOT in this repo:** the Simple PID Controller
  instance, the command template sensor, the Lock/Override helpers, the two
  faceplate scripts, and the dashboard cards. Auto-git-tracked on ha-sofia by the
  version-control add-on.
- `/usr/local/bin/fan-control` — bash **actuator** (source: `infra/scripts/fan-control.sh`).
- `fan-control.service` — systemd unit (`Type=simple`, restarts on failure).
- `/etc/fan-control.env` — config incl. the ha-sofia token (chmod 600, not in git).

## HA brain (dashboard-it → "Server" view → "R730 FAN PID" faceplate)

**Faceplate (since 2026-10-07)**, in the style of a DCS loop faceplate: PV / SP / OP
values on top (the raw reading as small text under PV), a PV bar (40–90 °C; amber =
5-min mean, white line with the white pointer on its level = SP, white marks 45 / 75 =
SP limits, red line = the daemon's 83 °C ceiling), an OP bar (0–100 %; blue = the
controller's command, white line = % the daemon applied, which trails the command in
`MIN_STEP` steps; grey marks = Output min/max), AUTO / MAN
buttons, SP ±0.5 °C and OP ±1 % arrows, and a footer with the applied %, the measured
rpm and whether the daemon is on the HA command or Dell auto. MAN is the Lock (OP is
the Override %). In AUTO the SP value can be typed in place, in MAN the OP value;
a typed value is sent only on Enter and only inside the limits (SP 45–75 °C, OP from
Output min to 100 %), otherwise the field turns red and nothing is sent; Escape or
leaving the field restores the shown value. Next to it, "PID tuning" holds Auto mode,
Kp, Ki, Kd and Output min/max. Built from button-card cards inside a stack-in-card;
the generator and the last card JSON are on the NAS
(`Claude shared/r730-fan-pid/faceplate-generator/`).

Scripts behind the buttons: `script.r730_fan_pid_auto` (AUTO; from MAN it calls
`simple_pid_controller.set_output` with the current Override %, waits until the PID
output is there and only then unlocks, so the switch is bumpless; toggling Auto mode
does not re-initialise the controller because the integration reads the switch once
per sample) and `script.r730_fan_pid_nudge` (fields `target` sp/op, `delta` or
`value`; SP kept within 45–75 °C, OP within Output min..100 % and only in MAN).

`sensor.r730_fan_command_pct` (template) computes, in order:

1. **Lock** on → the Override % directly (no freshness check).
2. **PID** — `switch.r730_fan_pid_auto_mode` on, `sensor.r730_fan_pid_pid_output`
   available, and a fresh CPU reading (see the freshness guard) → the PID output.
3. Otherwise `-1`. HA accepts it as a number, the daemon's regex rejects it, so the
   daemon holds the last applied % for `HA_GRACE_SECS` (300 s) and then hands the
   fans to **Dell auto**. Turning the PID's Auto mode off therefore means Dell auto
   after five minutes.

**Output format:** one decimal plus 0.01 on odd minutes. The pulse keeps
`last_updated` moving, so the daemon's `STALE_SECS` check never trips on a value that
is legitimately constant (smoothed output, or Lock, which previously fell to Dell auto
after ~35 min). The daemon truncates decimals, so the pulse never causes an IPMI write.
The daemon's `MIN_STEP` is the only deadband: 2 % since 2026-10-07, set in
`/etc/fan-control.env` (the script default is 3). A replay of the two measured days
put the 5-min mean within ±1 K of the setpoint 61 % / 51 % of the time at 2 %, against
50 % / 40 % at 3 %, for 3–4 writes per hour instead of 1.5. A 1 % step added little
more and made the duty flip between neighbouring values (77–93 quick reversals a day),
because the daemon truncates and has no other deadband.

**Freshness guard:** when not locked, if `sensor.r730_cpu_temperature` has no value or
its `last_reported` is older than 150 s, the command is `-1` (step 3 above). This
matters because the REST value template renders the text `unavailable` when the CPU
series is missing from Prometheus; HA rejects that for a numeric sensor and keeps the
previous value, so without the guard the controller would keep running on a frozen
temperature. The only such gap in the 30 days to 2026-10-06 came from a node reboot
that moved the single `snmp-exporter` pod: 8 minutes without iDRAC data, then 38 s
of Dell auto before the readings returned.

**PID controller:** Simple PID Controller (HACS `bvweerd/simple_pid_controller`,
v1.6.1), instance "R730 Fan PID". Process value: `sensor.r730_cpu_temperature_5min`
(Statistics helper, `mean`, 5 min, no `keep_last_sample`). Setpoint 60 °C, output
25–90 %, sample time 30 s, Kd 0, windup protection on, start mode "Last known value".
Cooling needs **negative** Kp and Ki. Tuning entities:
`number.r730_fan_pid_{setpoint,kp,ki,kd,output_min,output_max,sample_time,startup_value}`;
setpoint on the faceplate, Kp/Ki/Kd and the output limits on "PID tuning", sample time
and startup value on the "R730 Fan PID" device page. To set the controller's output
without a jump, call `simple_pid_controller.set_output` on `sensor.r730_fan_pid_pid_output`
with a `value` inside the output limits (what the AUTO script does).

**Tuning basis (2026-10-05):** a step test (Lock at 30 → 38 → 30 → 38 → 30 %, 15 min
each, garage closed) showed the CPU temperature falling about 0.40 K per % duty, a time
constant of about 160 s, a dead time of about 90 s, and a rise of about 0.15–0.20 K per %
of CPU load. Chosen: Kp −0.5 %/K, Ki −0.001 %/(K·s) (Ti ≈ 500 s). A closed-loop model
calibrated to the old curve controller (24.7 writes/h, σ 2.3 K) predicted about 2 IPMI
writes per hour, an average duty of ~30 %, and the CPU held at 60 °C with a 99th
percentile around 66 °C.

**Measured** (daemon journal + HA history):

| | Curve, 2026-10-02..05 (68 h) | PID, 10-05 14:00 → 10-06 13:00 | PID, 10-06 10:49 → 10-07 10:49 |
|---|---|---|---|
| IPMI writes per hour | 24.7 | 1.6 | 1.5 |
| Reversals within 5 min | 64 % | 0 | 1 |
| Average duty | ~37 % | 28 % | 28 % |
| Average fan speed | 7450 rpm | 6030 rpm | 6190 rpm |
| CPU average | 57.1 °C | 59.7 °C | 59.8 °C |
| CPU 5-min mean, p99 / max | – | 65.9 / 68.4 °C | 66.5 / 69.0 °C |
| CPU raw max | 69 °C | 74 °C | 74 °C |

The duty autocorrelation stayed positive at 10–60 min lags on both days, so there is no
slow oscillation. The raw peaks are single 30–60 s readings during load bursts (around
03:00–04:00, 06:00 and 13:00, load up to 63–74 %). A counterfactual replay of the
measured days (actual temperature plus the modelled fan-path response to the change in
duty) reproduces the measurements and shows that higher Kp/Ki lower the 5-min peak by
1–2 K at 2.6–7 writes per hour without moving the raw peak; a lower setpoint does move it
(58 °C: raw ≈ 73 °C, 5-min ≈ 67 °C, duty about 5 % higher). The iDRAC upper non-critical
threshold for CPU1 is 88 °C; the daemon's own ceiling is 83 °C.

**Manual override (MAN on the faceplate):** `input_boolean.r730_fan_lock` +
`input_number.r730_fan_manual_pct` (Override %). While unlocked, the automation
"R730 fan override — track live speed while unlocked" keeps Override % equal to the
live applied % (`sensor.r730_fan_control_target`); "R730 fan lock — freeze current
speed" snapshots it once more when Lock turns on, and the command template then
outputs it, so entering MAN does not move the fans. Leave MAN with the faceplate's AUTO
button: turning the Lock off any other way skips the re-initialisation and the
command jumps to whatever the PID computed meanwhile.

**Readout sensors:** `sensor.r730_fan_command_display` ("X % (Y rpm)", rpm estimated as
160 × % + 1520; no longer on a dashboard), `sensor.r730_cpu_load`,
`sensor.r730_fan_speed_avg` (mean of 6 fans),
`sensor.r730_fan_power_avg` (cube-law estimate). The Prometheus-backed REST
sensors live in `rest_resources/idrac_redfish_exporter.yaml` on ha-sofia and have
value-template fallbacks so they don't blink `unavailable` on a transient empty. The
daemon's own state comes from the Pushgateway through `rest_resources/fan_control.yaml`:
`sensor.r730_fan_control_target` (applied %) and `sensor.r730_fan_control_mode`, where
the daemon pushes 2 while it applies or holds the HA command (labelled "Cool", a name
kept from the June design) and 0 for Dell auto.

**Chart "R730 — CPU & Fans"** (same view, apexcharts-card inside a config-template-card
with 1 h / 12 h / 1 week buttons): since 2026-10-07 the four header numbers are the
live entity states (`show.in_header: raw`), the lines draw the recorded states as steps
for 1 h and 12 h (`group_by.func: raw`), and the week view averages 5-minute intervals,
because a week holds about 45 000 records across the four lines (the history fetch
alone took 18 s) and that is more points than the chart has pixels. Legend values are
hidden so no averaged number appears next to the live ones. The chart's "Fan Speed" is
the measured mean of the six fans; the fans run at the last value the daemon wrote,
which can differ from the command (OP) by up to `MIN_STEP`; the faceplate shows both.

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
The PID (setpoint, Kp, Ki, Kd, output min/max) is tuned **live from the HA
dashboard** — no host access needed. `/etc/fan-control.env` only holds the
actuator plumbing + safety knobs (`COMMAND_ENTITY`, `STALE_SECS`, `HA_GRACE_SECS`,
`MIN_STEP`, `CEILING`); edit it then `systemctl restart fan-control`. The unit
reads it as a systemd `EnvironmentFile`, which keeps everything after `=` as the
value, so put comments on their own line: `MIN_STEP=2  # note` reached the script
as `2  # note` on 2026-10-07 and broke its arithmetic test until the line was fixed.
A restart hands the fans to Dell auto for a few seconds (`ExecStopPost`) before the
new process writes the HA command again.

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
| Fans stuck loud | `journalctl` — `CEILING` breach or `HA command lost`? Check CPU temp + HA reachability, and whether the PID's Auto mode is on. |
| A readout blinks `unavailable` | the REST value-template fallback should hold it; a 1×/8h blip at ~02:00 (backup window) is a benign fetch hiccup. |
| PID setting changes ignored | does `sensor.r730_fan_pid_pid_output` move, and does `sensor.r730_fan_command_pct` follow it? token valid? |
| Command shows `-1` | the PID's Auto mode is off, its output is unavailable (e.g. right after an HA restart), or the freshness guard fired because `sensor.r730_cpu_temperature` has no fresh reading (Prometheus / SNMP iDRAC scrape). The daemon holds 300 s, then Dell auto; it resumes on its own when the command returns. |
| Box left in manual after crash | `ipmitool raw 0x30 0x30 0x01 0x01` to force Dell auto. |
| Faceplate field does not take a click or loses typed text | the input needs `pointer-events:auto` (button-card disables pointer events on its content), and it must live in its own card: a button-card re-creates nested cards when it re-renders, which drops focus. Both are handled in the generator on the NAS. |

## Verify wiring
```bash
ssh -i ~/.ssh/pve_root root@192.168.1.127 'set -a; . /etc/fan-control.env; set +a; RUN_ONCE=1 /usr/local/bin/fan-control'
```
The log `cmd=%` should equal `sensor.r730_fan_command_pct`. Switch the faceplate to
MAN and type a different OP so the HA sensor changes, re-run, and the applied `cmd=%`
should follow; return with AUTO.
