# Runbook — PVE R730 fan-control daemon

Presence-aware IPMI fan controller on the PVE host (192.168.1.127). Runs the
CPU cool when the garage is empty, quiet when someone's in the garage. Design:
`infra/docs/plans/2026-06-04-pve-fan-control-design.md`.

## What it is

- `/usr/local/bin/fan-control` — bash daemon (source: `infra/scripts/fan-control.sh`).
- `fan-control.service` — systemd unit (`Type=simple`, restarts on failure).
- `/etc/fan-control.env` — config incl. the ha-sofia token (chmod 600, not in git).

## HA control (Home Assistant)

The daemon polls two ha-sofia helpers each loop, so you can drive the fans from
HA — **dashboard-it → "Server" view → Fans**:
- `input_select.r730_fan_mode` — **auto** (garage-presence curve, default),
  **cool** / **quiet** (force that curve), **manual** (hold a fixed %).
- `input_number.r730_fan_manual_pct` — the % used in `manual` mode (slider).

Any non-`auto` override **auto-reverts to `auto` after 60 min**
(`automation.r730_fan_mode_auto_revert` on ha-sofia), so a forgotten override
can't run the fans wrong indefinitely. `CEILING` (83 °C) still overrides
everything → Dell auto. An HA change is applied within one daemon loop (~15 s).

Monitoring sensors on the same view: `sensor.r730_fan_speed` (redfish exporter),
`sensor.r730_fan_control_target` + `sensor.r730_fan_control_mode` (Pushgateway).

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
- Curves themselves are arrays (`COOL_CURVE`, `QUIET_CURVE`) near the top of the script.

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
