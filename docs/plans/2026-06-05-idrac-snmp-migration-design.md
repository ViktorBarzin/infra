# iDRAC monitoring: Redfish → SNMP migration (design)

**Date:** 2026-06-05
**Status:** approved (Viktor) — SNMP primary + thin Redfish remnant
**Stack:** `stacks/monitoring`

## Problem

The R730 iDRAC Redfish exporter (`idrac-redfish-exporter`, mrlhansen
`idrac_exporter`, image `viktorbarzin/idrac-redfish-exporter:2.4.1-voltage-fix`)
is configured `metrics: all: true`. It collects on-demand and walks every
Redfish subtree, making dozens of sequential ~1–2 s requests to a slow BMC.

Measured live (Prometheus `scrape_duration_seconds{job="redfish-idrac"}`, 24 h):
- **avg 18.5 s, peak 28.3 s**, occasional fast-fail 0.085 s.
- Pinned to a **3 m interval / 45 s timeout** because it cannot run at the 2 m
  global cadence.

The cost is dominated by walks that feed **dashboard-only** panels (`memory`
10 DIMMs, `network`, `events`/SEL); the operationally important metrics (fan
speed, temps, power, voltage) come from cheap single-request collectors.

## Decision

Make **SNMP the fast primary source** and keep a **thin, slow Redfish remnant**
for the few things SNMP cannot serve. SNMP walks are fast (the `snmp-ups` job
runs at 30 s); the iDRAC SNMP agent is already enabled and reachable.

Rejected alternatives: (1) pure collector-trim of Redfish — still BMC-bound and
slow; (2) pure SNMP / retire Redfish — would require re-pointing the **external
ha-sofia** `sensor.r730_fan_speed` REST sensor (collides with a live session
editing the fan dashboard) and would drop two cosmetic panels.

## Key findings (ground-truthed)

- **The `snmp-idrac` job was dead.** It specified **no `module`** param, so
  `snmp_exporter` defaulted to `if_mib` and returned only the iDRAC NIC's
  interface counters — zero health/power/thermal. Both iDRAC jobs relabel to
  `r730_idrac_*`, which hid this. The alert `iDRACSNMPMetricsMissing` is
  **misnamed** — its expr `absent(r730_idrac_idrac_system_health)` checks a
  *Redfish* metric.
- **A generated `dell_idrac` module already exists**, unmounted, in
  `prometheus_snmp_chart_values.yaml` (~lines 79–1628). The mounted config is
  `ups_snmp_values.yaml` (huawei/if_mib/ip_mib only). iDRAC SNMP = v2c,
  community `Public0` (already the `public_v2` auth in `ups_snmp_values.yaml`).
- **Live snmpwalk (Public0, 192.168.1.4) confirms** these return real data:
  fan RPM `coolingDeviceReading` (.4.700.12.1.6 = 7080 RPM), temps
  `temperatureProbeReading` (.700.20.1.6, tenths-°C), system watts
  `amperageProbeReading` (.600.30.1.6 = 252 W), PSU input voltage
  `powerSupplyCurrentInputVoltage` (.600.12.1.16), PSU watts/health, global
  health `globalSystemStatus` (.5.2.1), `systemState*` rollups (.200),
  `physicalDisk*` status, `memoryDevice*` size/status/type/speed (.1100),
  `networkDevice*` status/connection (.1100.90), BIOS `2.19.0` (.300.50.1.8),
  model/service-tag (.5.1.3).
- **Genuine SNMP gaps — but inert or cosmetic today:**
  - SSD life-left % (`physicalDiskRemainingRatedWriteEndurance` .49) → returns
    `255` (N/A) for every drive incl. the Samsung SSD. **Redfish today reports
    `0`** on the one drive that has it, and the SSD-wear alerts guard on `> 0`,
    so they **already never fire** → no functional loss.
  - SEL event log (`5.5.2`) → `NoSuchObject`. The `idrac_events_log_entry`
    metric is **already empty in Prometheus** today → no loss.
  - Indicator LED (`5.1.4`) → absent. Cosmetic ("Off") panel.
  - NIC link-speed Mbps → no OID (health + up/down preserved). Cosmetic.
  - Average watts → no native OID; reconstruct via PromQL `avg_over_time()`.

Conclusion: **every metric with real, used data today has an SNMP equivalent.**

## Naming / enum strategy

`snmp_exporter` names metrics after MIB objects (`temperatureProbeReading`,
`coolingDeviceReading`, `globalSystemStatus`, …) → after the `r730_idrac_`
relabel they are `r730_idrac_<mibName>`, different from today's
`r730_idrac_idrac_*` / `r730_idrac_redfish_*`. **Re-point consumers** (not
alias): aliasing via `metric_relabel_configs` only renames `__name__` and
cannot fix the label-set mismatch (Redfish `member_id`/`name` vs SNMP numeric
indexes) nor the **enum-value mismatch** (DellStatus `3=OK` vs Redfish `1`;
`systemPowerState 4=on` vs Redfish `2`). Alert exprs must change regardless, so
re-pointing is the honest path. The module adds `lookups:` so SNMP series carry
human labels (probe/fan location, disk display name) like today.

## Consumed-metric → SNMP mapping (DIRECT / REGEN / remnant)

REGEN = OID returns data but must be added to the module walk.

| Consumed (today) | Source after migration |
|---|---|
| fan health | REGEN `coolingDeviceStatus` .700.12.1.5 |
| consumed watts | DIRECT `amperageProbeReading` (System Board Pwr Consumption) |
| system health rollup | DIRECT `globalSystemStatus` .5.2.1 |
| PSU health | DIRECT `powerSupplyStatus`/`powerSupplySensorState` |
| memory health | DIRECT `systemStateMemoryDeviceStatusCombined` .200.10.1.27 |
| storage drive health | DIRECT `physicalDiskComponentStatus` .5.5.1.20.130.4.1.24 |
| **SSD life %** | **remnant** (SNMP=255 N/A; already inert) |
| system power state | DIRECT `systemPowerState` .5.2.4 (enum 4=on) |
| PSU input voltage | DIRECT `powerSupplyCurrentInputVoltage` .600.12.1.16 |
| system health (absent-probe) | DIRECT `globalSystemStatus` |
| **fan speed RPM (HA)** | DIRECT via remnant (HA reads exporter directly); SNMP REGEN `coolingDeviceReading` for Grafana |
| temperature | DIRECT `temperatureProbeReading` .700.20.1.6 (÷10) |
| avg watts | PromQL `avg_over_time(amperageProbeReading)` |
| **SEL log** | **remnant** (already empty) |
| machine/bios info | REGEN model/svctag .5.1.3, BIOS .300.50.1.8 |
| memory size / cpu count | DIRECT `memoryDeviceSize` (sum) / `processorDeviceStatus` (count) |
| **indicator LED** | **remnant** (cosmetic) |
| storage drive info/health/capacity | DIRECT `physicalDisk*` |
| memory module info/health/cap/speed | DIRECT(size) + REGEN(status/type/speed .1100.50.1.{5,7,8,15}) |
| network port health/link / **Mbps** | REGEN `networkDevice*` (.1100.90); **Mbps → remnant/drop** |
| PSU output/input/capacity watts | DIRECT `powerSupplyOutputWatts`/`RatedInputWattage` |

## Remnant role

The Redfish exporter stays alive (so the external ha-sofia
`sensor.r730_fan_speed` REST poll is **unchanged** — no ha-sofia edit, no
collision). It is trimmed to `sensors,system,network,storage,events` and its
Prometheus scrape slows to 10 m, keeping **only** the gap metrics (indicator
LED, NIC Mbps, SSD-life, SEL) via `metric_relabel_configs` to avoid duplicate
series with SNMP.
