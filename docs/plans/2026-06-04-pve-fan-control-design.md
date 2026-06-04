# PVE R730 presence-aware fan control — design

**Date:** 2026-06-04
**Status:** implemented
**Scripts:** `infra/scripts/fan-control.{sh,service,env.example}`, `test-fan-control.sh`
**Runbook:** `infra/docs/runbooks/fan-control.md`

## Problem

The Dell R730 PVE host (192.168.1.127) runs its CPU at ~72–77°C under normal
cluster load. That is safe (firmware warning at 88°C, critical 93°C) but the
iDRAC's stock fan curve optimises for quiet, not cool — it pins the fans at the
~7080 RPM floor even at 72°C / load 30 and only ramps near ~80°C. We want the
CPU to run cooler when it costs nothing (the box is in the garage, usually
empty) while staying quiet when someone is physically in the garage.

## Measured fan/temp relationship (manual IPMI sweep, 2026-06-04)

At a comparable CPU load (~45–53 % busy):

| Fan setting | Fan RPM | CPU temp |
|-------------|---------|----------|
| Auto (floor) | 7,080  | 71–72°C  |
| 50 %        | 9,360  | 65–66°C  |
| 70 %        | 12,800 | 60–61°C  |
| 100 %       | 17,000 | 55–56°C  |

Best °C-per-RPM is the first step; beyond ~70 % it is mostly noise. ~16°C of
swing is available.

## Decisions

1. **Custom bash daemon + systemd service**, deployed to the PVE host the same
   way as `apply-mbps-caps` / `daily-backup` (source in `infra/scripts/`, scp to
   `/usr/local/bin`). It cannot be Terraform/k8s — it runs on the bare host where
   IPMI lives. (OSS `tigerblue77/Dell-iDRAC-fan-controller` was considered;
   rejected — it is a Docker container, off-pattern here, and unaware of our
   constraints.)
2. **CPU temperature is the only control input.** The Tesla T4 has its own
   always-on fan (owner-confirmed), so it self-cools and does not depend on
   chassis airflow — no GPU coupling needed.
3. **Presence = the garage door**, because the server is *in the garage*
   (memory id=1723); noise only matters to people physically there. Signal:
   ha-sofia `sensor.garage_door_state_bg`. Open now, or last changed within
   `HOLD_SECS` (15 min) ⇒ someone's around ⇒ QUIET; otherwise COOL.
   `house_mode` was rejected — it tracks *apartment* occupancy, irrelevant to
   garage noise.
4. **Two curves**, picked by presence:

   | CPU °C | COOL % (empty) | CPU °C | QUIET % (occupied) |
   |--------|----------------|--------|--------------------|
   | ≤52    | 25 | ≤72 | 20 (≈silent floor) |
   | 53–60  | 45 | 73–77 | 40 |
   | 61–67  | 65 | 78–81 | 65 |
   | 68–73  | 85 | ≥82 | 100 |
   | ≥74    | 100 | | |

   3°C downward hysteresis prevents flapping at band edges (ramp up immediately,
   step down only once the curve still wants lower 3°C hotter).

## Safety

Manual fan mode bypasses the iDRAC's own protection, so it is backstopped:

- **Daemon exit/crash/stop** → bash `EXIT` trap + systemd `ExecStopPost` both
  run `ipmitool raw 0x30 0x30 0x01 0x01` (restore Dell auto). `Restart=on-failure`.
- **CPU ≥ `CEILING` (83°C)** → hand back to Dell auto until temp holds below
  `RESUME_BELOW` (75°C) for `RESUME_STABLE` (120 s), then resume manual.
- **IPMI read failures ≥ `MAX_IPMI_FAILS`** → restore Dell auto.
- **ha-sofia unreachable** → keep the last good presence decision; default COOL
  at cold start (thermally safe).

## Observability

Pushes to the existing Pushgateway (`http://10.0.20.100:30091`, job
`fan_control`): `pve_fan_control_cpu_temp_celsius`, `_fan_percent`, `_mode`
(1 quiet / 2 cool / 0 fallback), `_ha_reachable`, `_fallback`. The existing CPU-
temp alert is unaffected.

## Testing

`test-fan-control.sh` sources the script (main is guarded by a `BASH_SOURCE`
check) and unit-tests the pure functions: both curves, hysteresis up/down,
presence open/recent/stale, temperature parsing, jq-free JSON field extraction,
and percent→hex. 36 assertions, no hardware needed. The daemon also supports
`DRY_RUN=1` and `RUN_ONCE=1` for integration checks.

## Rollback

`systemctl disable --now fan-control && ipmitool raw 0x30 0x30 0x01 0x01` on the
host returns the box to stock firmware fan control. See the runbook.
