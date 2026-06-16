# PVE R730 presence-aware fan control — design

**Date:** 2026-06-04
**Status:** implemented; **redesigned 2026-06-08, anti-flap 2026-06-15** (see update below)
**Scripts:** `infra/scripts/fan-control.{sh,service,env.example}`, `test-fan-control.sh`
**Runbook:** `infra/docs/runbooks/fan-control.md`

> ## Update — control moved to HA; host is a thin actuator
>
> - **2026-06-07:** presence/two-curve scheme replaced by a single linear curve;
>   all garage-presence logic removed.
> - **2026-06-08:** **all control moved into Home Assistant.** HA owns the curve
>   thresholds, duty %, an additive **bias** (replaces the ease-down hysteresis),
>   plus manual/lock, and publishes `sensor.r730_fan_command_pct =
>   clamp(curve(temp)+bias, 0..100)` with an asymmetric output deadband. The host
>   `fan-control.sh` is now a **thin actuator**: read that one number, validate,
>   apply over IPMI — no local math. Independent host safety (CPU≥83 °C, IPMI
>   fail, HA loss) hands the fans to Dell auto. It's a P controller, so the curve
>   slope/offset set the steady-state equilibrium temperature (not a setpoint).
> - **2026-06-15:** daemon **anti-flap** — on a transient HA miss it HOLDS the
>   last applied % for `HA_GRACE_SECS` (300 s) instead of dumping to Dell auto,
>   and `STALE_SECS` loosened 120→1800 (staleness only happens at flat temp,
>   where the held value is still valid). Killed a ~14%-of-the-time flap to the
>   Dell floor; verified fallback 14%→0%, command std 16→3 over 8 h.
>
> The HA objects (sliders, command template, display/equilibrium sensors,
> Lock/Override, dashboard cards, REST sensors) live on ha-sofia, not this repo.
> Sections below are retained as historical context.

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

## Power characterization (sweep 2026-06-05)

Averaged wall power (iDRAC DCMI) + temp at each fan setting:

| Fan | RPM | Power | CPU | load |
|-----|-----|-------|-----|------|
| auto | 7,080 | 296 W | 68°C | 21 |
| 20 % | 4,800 | 281 W | 73°C | 20 |
| 30 % | 6,360 | 288 W | 72°C | 19 |
| 50 % | 9,360 | 299 W | 65°C | 18 |
| 60 % | 11,040 | 303 W | 61°C | 17 |
| 70 % | 12,720 | 324 W | 59°C | 16 |
| 100 % | 16,920 | 378 W | 59°C | 17 |

**The cooling-per-watt knee is ~60 %.** Fan power follows ~RPM³: 60→70 % costs
+21 W for −2°C; 70→100 % costs **+54 W for 0°C** (the CPU floors ~59°C at cluster
load — more airflow does nothing). Full speed draws ~97 W (~850 kWh/yr) over the
floor and buys nothing past 60 %.

**Decision (2026-06-05):** the COOL curve caps its normal band at 60 % (~303 W,
~61°C) — capturing essentially all achievable cooling while avoiding the wasteful
80–100 % zone, now reserved as a high-load safety ramp (≥73/79°C) before the 83°C
ceiling. QUIET is unchanged (already at the low-power floor: 20 % / 4,800 RPM /
281 W). Verified live after re-tune: 63°C, 60 %, ~267 W.

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
4. **Two continuous LINEAR curves**, picked by presence. (Originally discrete
   step-bands; replaced 2026-06-05 — the bands flapped at edges, e.g. 45↔65%.
   Web research: a linear curve + 2–3°C hysteresis is the homelab standard; PID
   is overkill for this slow thermal loop and even PID projects "only lower, don't
   chase a setpoint".) fan% interpolates between per-mode anchors, clamped flat
   outside; both reach 100% right at the 83°C ceiling:

   | Mode | T_LO → P_LO | T_HI → P_HI | slope |
   |------|-------------|-------------|-------|
   | COOL (garage empty) | 50°C → 30% | 83°C → 100% | ~2.1%/°C (≈51% at the ~60°C equilibrium) |
   | QUIET (occupied) | 68°C → 20% | 83°C → 100% | ~4.7%/°C (near-silent until ~70°C) |

   Anchors are env-tunable (`COOL_T_LO/P_LO/T_HI/P_HI`, `QUIET_*`). Under normal
   load the COOL equilibrium (~60°C → ~51%) sits near the measured ~60% power
   knee; the ramp toward 100% only engages at genuinely high temp (safety).
   Anti-oscillation: asymmetric hysteresis (ramp up immediately, ease down only
   once the curve wants lower 3°C hotter) **plus** a `MIN_STEP` (3%) min-change
   threshold so 1–2% wiggles don't churn IPMI writes.

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

Pushes to the Pushgateway (`http://10.0.20.100:30091`, job `fan_control`):
`pve_fan_control_cpu_temp_celsius`, `_fan_percent`, `_mode` (1 quiet / 2 cool /
3 manual / 0 fallback), `_ha_reachable`, `_fallback`, `_fan_rpm`, and
`_fan_watts_est`.

**Fan power is ESTIMATED** — the iDRAC exposes only total DCMI watts + RPM (no
per-fan power), so `_fan_watts_est` models it from RPM via the fan affinity law
(power ∝ RPM³), calibrated to the 2026-06-05 sweep: `fan_W ≈ 0.0205·(RPM/1000)³`
(≈2 W at the floor → ~99 W at full; fits the sweep within ~3 W). Surfaced in HA
as `sensor.r730_fan_power_est` + a "Fan Power (est)" card on the dashboard-it
Server view, next to total power (`sensor.r730_power_consumption`, redfish) — so
the fan tax of the control curve is visible. The existing CPU-temp alert is
unaffected.

## Testing

`test-fan-control.sh` sources the script (main is guarded by a `BASH_SOURCE`
check) and unit-tests the pure functions: both curves, hysteresis up/down,
presence open/recent/stale, temperature parsing, jq-free JSON field extraction,
and percent→hex. 36 assertions, no hardware needed. The daemon also supports
`DRY_RUN=1` and `RUN_ONCE=1` for integration checks.

## HA control (added 2026-06-05, on the host daemon)

Delivered ahead of the cron migration (which is Vault-gated) by teaching the
**host daemon** to poll two ha-sofia helpers each loop (`fc_resolve`):
`input_select.r730_fan_mode` (auto/cool/quiet/manual) +
`input_number.r730_fan_manual_pct`. `auto` = the garage-presence curve above;
cool/quiet force that curve; manual holds a fixed %; `CEILING` still overrides.
The **simplified dashboard (2026-06-05)** exposes just three things — fan speed
(%/RPM), an **Override %** slider, and a **Lock** toggle. Lock = "freeze current
speed / algo off": `automation.r730_fan_lock_freeze_current_speed_resume_algo`
snapshots the live target % into Override and sets `mode=manual` on lock-ON, and
`mode=auto` on lock-OFF — the daemon needs no change, the toggle just drives the
mode. `cool`/`quiet` stay reachable via the entity but are off the dashboard. The
60-min `automation.r730_fan_mode_auto_revert` is retained as a dormant safety net
(manual now only happens while locked, which it skips). The daemon just polls and
actuates.
Monitoring + control live on the dashboard-it "Server" view (REST sensors: fan
RPM from the redfish exporter; mode/target-% from the Pushgateway). The same
logic already exists in the Python controller (`r730-fan-control/`) for the
eventual in-cluster CronJob; when that deploys it supersedes the host daemon.

## Rollback

`systemctl disable --now fan-control && ipmitool raw 0x30 0x30 0x01 0x01` on the
host returns the box to stock firmware fan control. See the runbook.
