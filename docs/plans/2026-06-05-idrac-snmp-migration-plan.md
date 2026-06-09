# iDRAC Redfish → SNMP migration (plan)

Companion to `2026-06-05-idrac-snmp-migration-design.md`. Execute in order;
applies are staged so the safe/additive work lands and is verified before any
consumer re-pointing.

Files:
- `stacks/monitoring/modules/monitoring/ups_snmp_values.yaml` (merge target)
- `stacks/monitoring/modules/monitoring/prometheus_snmp_chart_values.yaml` (dell_idrac source, ~79–1628)
- `stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl` (scrape jobs ~3150/3170, alerts ~811–1186)
- `stacks/monitoring/modules/monitoring/idrac.tf` (Redfish exporter / remnant)
- `stacks/monitoring/modules/monitoring/dashboards/idrac.json`, `cluster_health.json`

## Phase A — additive SNMP source (low risk)

- [ ] A1. Extract `dell_idrac` (lines 79–1628) from `prometheus_snmp_chart_values.yaml`; **strip its embedded `auth:`/`version:`** (the merge target uses the split `auths:` format) and append the module under `modules:` in `ups_snmp_values.yaml`.
- [ ] A2. Hand-add to dell_idrac `walk:` + `metrics:` (with `lookups:` for labels):
  - `coolingDeviceReading` .4.700.12.1.6 (fan RPM, gauge, idx chassis+device, lookup `coolingDeviceLocationName` .8)
  - `coolingDeviceStatus` .4.700.12.1.5 (fan health, enum)
  - `networkDeviceStatus` / `networkDeviceConnectionStatus` (.1100.90.1.{3,17})
  - `systemBIOSVersionName` .300.50.1.8; system model .5.1.3.12 + service-tag .5.1.3.2
  - DIMM `.1100.50.1.{5 status, 7 type, 8 location, 15 speed}`
  - `physicalDiskRemainingRatedWriteEndurance` .5.5.1.20.130.4.1.49 (so remnant isn't needed for SSD if it ever populates; harmless 255 today)
- [ ] A3. `snmp-idrac` job (`prometheus_chart_values.tpl` ~3150): add `params: { module: [dell_idrac], auth: [public_v2] }`, `scrape_interval: 1m`, `scrape_timeout: 30s`. Keep the `r730_idrac_` relabel.
- [ ] A4. **Validate before any repoint:** apply monitoring stack; `curl 'http://snmp-exporter.monitoring.svc:9116/snmp?module=dell_idrac&auth=public_v2&target=192.168.1.4:161'` returns all REGEN/DIRECT metrics with readable labels; `scrape_duration_seconds{job="snmp-idrac"}` < 5 s; confirm exact emitted metric names + label keys (feeds B/C).

## Phase B — re-point consumers to verified SNMP names (riskier)

- [ ] B1. Rewrite ~12 alert exprs (`prometheus_chart_values.tpl` 811–1186) to SNMP names + **SNMP enums** (`3=OK` not `1`; power `4=on` not `2`). Re-target absent-probes: `iDRACRedfishMetricsMissing`→`absent(r730_idrac_powerSupplyCurrentInputVoltage)`; `iDRACSNMPMetricsMissing`→`absent(r730_idrac_globalSystemStatus)` (also fixes the misnomer).
- [ ] B2. Re-point ~26 panels in `idrac.json` + `cluster_health.json` to SNMP names/labels; avg-watts → `avg_over_time(...amperageProbeReading...[$__interval])`.
- [ ] B3. Add any new SNMP metric names to the Prometheus keep-rules whitelist if present (grep `prometheus-server` configmap / `prometheus_chart_values.tpl` keep rules) so they aren't silently dropped.
- [ ] B4. Apply; verify each re-pointed alert has data (no spurious `absent` firing) and panels render.

## Phase C — thin Redfish remnant

- [ ] C1. `idrac.tf` config map: `metrics: all: false` + enable only `sensors, system, network, storage, events` (drop power/memory/processors/manager/extra — now SNMP). (HA reads `sensors` directly — unchanged.)
- [ ] C2. `redfish-idrac` job: `scrape_interval: 10m`; add `metric_relabel_configs` to **keep only** the gap series (indicator LED, NIC Mbps, SSD-life, SEL) → avoids duplicate series with SNMP.
- [ ] C3. Apply; verify HA `sensor.r730_fan_speed` still updates, gap panels render, fan-control daemon unaffected (it uses IPMI, not this exporter — should be untouched).

## Phase D — docs + ship

- [ ] D1. Update `docs/architecture/monitoring.md` (iDRAC now SNMP-primary; remnant role), note the fixed alert misnomer, any runbook.
- [ ] D2. Update this plan's checkboxes; commit (named files) + push; wait for CI/deploy.

## Rollback

All Terraform-managed. Revert the monitoring-stack commit + `scripts/tg apply`
restores the Redfish-primary state. Phase A is additive (safe to leave even if
B/C are reverted).

## Presence

Claim `stack:monitoring` + `service:idrac-redfish-exporter` before each apply.
