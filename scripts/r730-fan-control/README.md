# r730-fan-control

Cluster-native, HA-controllable fan controller for the Dell R730 PVE host.
Supersedes the host-side `infra/scripts/fan-control.sh` bash daemon — same
power-tuned curves, delivered as a Terraform-managed k8s **CronJob** that drives
the iDRAC over IPMI-over-LAN, is monitored via Prometheus (→ Home Assistant),
and is controlled from HA (mode + manual %, auto-reverting).

## How it works
Not deployed yet: the live fan control is still the host daemon
`scripts/fan-control.sh` (runbook `docs/runbooks/fan-control.md`). There is no
`stacks/r730-fan-control/` stack or image pipeline; this directory is the
controller code for when the CronJob is built. Moved here from the `~/code`
monorepo root (`r730-fan-control/`) on 2026-11-03.

Each minute (planned `stacks/r730-fan-control/` CronJob) `controller.py`:
1. Pulls desired state from ha-sofia: `input_select.r730_fan_mode`
   (auto/cool/quiet/manual) + `input_number.r730_fan_manual_pct`.
2. Reads CPU temp + current fan RPM from the iDRAC (`ipmitool -I lanplus -H 192.168.1.4`).
3. Reads the garage door (presence) when mode=auto.
4. `fan_logic.plan_fan()` → target % (manual slider, or the cool/quiet curve with
   hysteresis; auto picks the curve by garage presence).
5. CPU ≥ `CEILING` (83°C) → hands fans back to Dell auto.
6. Sets fans via IPMI; pushes metrics to the Pushgateway (`job=fan_control`).

**HA owns all control state + the auto-revert TTL** — the CronJob is a stateless
actuator that polls. Hysteresis uses the read-back fan RPM (`rpm_to_pct`).

## Safety (pure-cluster)
No host remnant. If the CronJob stops, fans hold last setting → a Prometheus
staleness alert (`FanControlStale`) fires, and the iDRAC's own 88°C thermal
protection is the hard backstop. CPU ≥ 83°C and IPMI-read failures both fall
back to Dell auto.

## Layout
- `fan_logic.py` — pure decision logic (curves, hysteresis, presence, plan_fan). Unit-tested.
- `controller.py` — the per-run I/O actuator (IPMI + HA + Pushgateway).
- `test_fan_logic.py` — pytest cases (`python3 -m pytest scripts/r730-fan-control`).
- `Dockerfile` — `python:3.12-slim` + `ipmitool`, non-root.

## Config (env)
`IDRAC_HOST/USER/PASS`, `HA_URL/HA_TOKEN`, `MODE_ENTITY`, `MANUAL_ENTITY`,
`GARAGE_ENTITY`, `GARAGE_OPEN_STATE`, `HOLD_SECS` (900), `DEADBAND` (3),
`CEILING` (83), `PUSHGATEWAY_URL`, `DRY_RUN`.

Design + runbook: `infra/docs/plans/2026-06-04-pve-fan-control-design.md`,
`infra/docs/runbooks/fan-control.md`.
