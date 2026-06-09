# Runbook — PVE R730 fan-control daemon

Presence-aware IPMI fan controller on the PVE host (192.168.1.127). Runs the
CPU cool when the garage is empty, quiet when someone's in the garage. Design:
`infra/docs/plans/2026-06-04-pve-fan-control-design.md`.

## What it is

- `/usr/local/bin/fan-control` — bash daemon (source: `infra/scripts/fan-control.sh`).
- `fan-control.service` — systemd unit (`Type=simple`, restarts on failure).
- `/etc/fan-control.env` — config incl. the ha-sofia token (chmod 600, not in git).

## HA control (Home Assistant)

Drive the fans from **dashboard-it → "Server" view → Fans**. The view is
deliberately minimal — it shows the current **fan speed** (% of capacity +
absolute RPM) and two controls:

- **Override %** (`input_number.r730_fan_manual_pct`) — the fan % to hold. While
  **unlocked** it continuously mirrors the live commanded fan %, so it always
  shows the actual *absolute* speed and updates as the fan moves (NOT a stale
  value or a delta) — `automation.r730_fan_override_track_live_speed_while_unlocked`
  syncs it to `sensor.r730_fan_control_target` (guarded to ignore
  unavailable/unknown). While **locked** it stops tracking and becomes your
  editable setpoint. A readout under the slider shows the live `% · rpm`.
- **Lock — freeze speed** (`input_boolean.r730_fan_lock`) — turn the algorithm
  off and hold a fixed speed. Toggling it **ON** snapshots the *current*
  commanded % into Override and switches the daemon to `manual`
  (`automation.r730_fan_lock_freeze_current_speed_resume_algo`); toggling it
  **OFF** switches back to `auto`, resuming the presence curve. Fine-tune the
  held % with Override while locked. A 🔒 reminder appears on the view while
  locked.

Under the hood the daemon still reads `input_select.r730_fan_mode`
(auto/cool/quiet/manual) + `input_number.r730_fan_manual_pct` each loop; the Lock
toggle just drives `mode` between `manual` (locked) and `auto` (unlocked).
`cool`/`quiet` remain valid modes if set directly (via the entity) but are no
longer surfaced on the simplified dashboard. `CEILING` (83 °C) still overrides
everything → Dell auto, **even when locked**. A stale non-`auto` mode left while
*unlocked* still auto-reverts to `auto` after 60 min
(`automation.r730_fan_mode_auto_revert`, now a dormant safety net). An HA change
is applied within one daemon loop (~15 s).

Monitoring sensors on the same view: `sensor.r730_fan_speed` (redfish exporter),
`sensor.r730_fan_control_target` + `sensor.r730_fan_control_mode` +
`sensor.r730_fan_power_est` (Pushgateway). Fan **% and RPM are merged into one
"Fan speed" card** (the two had identical trend shapes) — the % trend comes from
the stable Pushgateway sensor, while RPM reads `sensor.r730_fan_speed` but **falls
back to a calibrated estimate (shown with a `~` prefix) whenever the Redfish
sensor is `unavailable`** (it blips out intermittently), so the readout never goes
blank. `r730_fan_power_est` is an ESTIMATE of
total fan power (the iDRAC reports no per-fan power) — modelled from RPM via the
fan affinity law (∝ RPM³), calibrated to the power sweep (~2 W floor → ~99 W full).

The HA objects (helpers, the auto-revert automation, the REST sensors in
`rest_resources/{idrac_redfish_exporter,fan_control}.yaml`, and the dashboard
cards) live on **ha-sofia** and are auto-git-tracked there by the version-control
add-on — they are NOT in this repo.

## Quick status

```bash
ssh root@192.168.1.127 systemctl status fan-control
ssh root@192.168.1.127 'journalctl -u fan-control -n 30 --no-pager'
ssh root@192.168.1.127 'ipmitool sdr type fan | grep ^Fan1; ipmitool sdr type temperature | grep "^Temp "'
```
Log lines look like `temp=60C ha_mode=auto eff=cool fan=50% (was 70%)`
(`ha_mode` = the HA setpoint; `eff` = the effective curve applied).

## Disable / roll back to stock firmware control

```bash
ssh root@192.168.1.127 'systemctl disable --now fan-control && ipmitool raw 0x30 0x30 0x01 0x01'
```
The unit's `ExecStopPost` already restores Dell auto on stop, so the explicit
`raw ... 0x01` is belt-and-suspenders. The box is back to its stock curve.

## Tune

Edit `/etc/fan-control.env` on the host, then `systemctl restart fan-control`.
Common knobs:
- `HOLD_SECS` — how long to stay quiet after the garage door last moved (default 900 = 15 min).
- `CEILING` — temp at which we abandon manual control and let the firmware take over (default 83).
- Curve shape: **linear anchors** near the top of the script — `COOL_T_LO/COOL_P_LO/COOL_T_HI/COOL_P_HI` (default 50°C/30% → 83°C/100%) and `QUIET_*` (68°C/20% → 83°C/100%); fan% interpolates linearly between them (replaced the old discrete step-bands). `MIN_STEP` (default 3%) = smallest fan-% change worth an IPMI write (anti-jitter); `DEADBAND` (3°C) = ease-down hysteresis. Lower `COOL_P_HI` or raise `COOL_T_HI` to run the top end quieter; steepen by raising `COOL_P_LO` / lowering `COOL_T_LO`.

## Deploy / update

```bash
cd infra
scp scripts/fan-control.sh     root@192.168.1.127:/usr/local/bin/fan-control
ssh root@192.168.1.127 chmod +x /usr/local/bin/fan-control
scp scripts/fan-control.service root@192.168.1.127:/etc/systemd/system/fan-control.service
# first install only — create /etc/fan-control.env from fan-control.env.example with the HA token
ssh root@192.168.1.127 'systemctl daemon-reload && systemctl restart fan-control'
```

## HA token

`/etc/fan-control.env` holds a long-lived ha-sofia token used to read
`sensor.garage_door_state_bg`. Mint via Home Assistant → Profile → Security →
Long-lived access tokens, or reuse the existing ha-sofia token. If the token is
missing/empty, the daemon still runs but **COOL-only** (no quiet mode) and logs
`ha_reachable=0`.

## Symptoms & checks

| Symptom | Check |
|---------|-------|
| Fans stuck loud | `journalctl -u fan-control` — is `mode=fallback`? (ceiling breach or IPMI fail). Check CPU temp. |
| Never goes quiet | Token valid? `curl -H "Authorization: Bearer $TOKEN" http://192.168.1.8:8123/api/states/sensor.garage_door_state_bg`. Garage door reporting? |
| Fans flapping | Increase `DEADBAND`. |
| Service won't start | `systemctl status fan-control`; check `ipmitool` works: `ipmitool sdr type temperature`. |
| Box left in manual after crash | `ipmitool raw 0x30 0x30 0x01 0x01` to force Dell auto. |

## Verify presence wiring

```bash
# one iteration, real IPMI + HA, no daemon loop:
ssh root@192.168.1.127 'set -a; . /etc/fan-control.env; set +a; RUN_ONCE=1 /usr/local/bin/fan-control'
```
With the garage closed for >15 min you should see `mode=cool`; within 15 min of
the door moving, `mode=quiet`.
