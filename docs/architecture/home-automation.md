# Home automation

<!-- showcase: The family home in Sofia runs on one Home Assistant instance, a VM on the same Dell server as the cluster. It reaches its devices through vendor clouds, Bluetooth, Matter and ESPHome, and a few cluster services feed it. -->

Home Assistant (`ha-sofia`) runs Home Assistant OS as Proxmox VM 103 on the R730,
next to the Kubernetes nodes, at `https://ha-sofia.viktorbarzin.me`. It covers
the family home in Sofia, its garage and a second family property, and the
family shares it. A second, smaller instance (`ha-london`, a Raspberry
Pi 3) runs the London flat and is documented in `london-site.md`.

There is no Zigbee or Z-Wave coordinator. Devices arrive through vendor clouds
(Tuya, Hydrawise, MELCloud and others), Bluetooth (PAX fans, AC Infinity), Matter
(the front door lock) and ESPHome, with MQTT for the alarm interface.

## Where the cluster meets the house

| cluster side | role |
|---|---|
| `stacks/monitoring` | Prometheus scrapes `/api/prometheus`; `HomeAssistantDown` alerts on it |
| `stacks/tuya-bridge` | HTTP bridge to the Tuya cloud; HA sends switch commands through it, and its poller pushes planter sensors in |
| `stacks/frigate` | NVR for the cameras, with a go2rtc endpoint HA uses for live view |
| `stacks/wealthfolio` | pushes net worth into HA for the watch face (ADR-0034) |
| `stacks/openclaw`, the `ha-mcp` add-on | let the AI assistants read and act on HA |
| `stacks/reverse-proxy` | the Traefik route to HA |

## On the Showcase

The Home view of the Showcase (ADR-0037) publishes counts only: devices,
entities, integrations, automations by kind and dashboards. It never shows names
of people, rooms, entities or automations, live states, or the brands of the
alarm, lock and cameras, which appear as one "security" line. Dashboard
screenshots are taken with `homelab showcase shots`, masked, approved by the
repo owner, and committed; they change only when someone reruns that command. The build
reads HA with its own long-lived token named `showcase` (Vault
`secret/showcase`, field `ha_sofia_token`), which can be revoked without
affecting anything else.

The two sections below are quoted on the Showcase. Keep them free of digits, so
nothing in them goes stale against the live numbers beside them.

## Server fans on a PID loop
<!-- showcase-highlight: server-fans -->

The R730's fans are driven by Home Assistant rather than by the server's own
firmware curve. A PID controller in HA reads a five-minute mean of the CPU
temperature and publishes a single fan command. A small daemon on the Proxmox
host applies that number over IPMI and does no maths of its own. If HA goes
quiet, the daemon holds the last command for a few minutes and then hands the
fans back to Dell's automatic control, so a restart of HA never leaves the
server unmanaged. The tuning, setpoint and manual override live on a faceplate
on the IT dashboard.

## Solar first, grid when the battery runs low
<!-- showcase-highlight: solar-ats -->

An automatic transfer switch decides whether the house runs from the solar
inverter's battery or from the grid. HA watches the battery: once it has stayed
well charged for a few minutes, it moves the house onto solar, and when the
charge falls below a lower threshold it moves it back to the grid. The gap
between the two thresholds keeps the switch from flapping. The commands travel
through the Tuya bridge running in the cluster, and a manual mode turns the
automatic switching off entirely. Separately, HA flips the apartment and garage
energy meters between day and night tariffs on the winter and summer schedules,
so the energy dashboard prices each kilowatt-hour at the right rate.

## Further reading

Operational detail: `docs/runbooks/fan-control.md` and
`docs/plans/2026-06-04-pve-fan-control-design.md` for the fans.
