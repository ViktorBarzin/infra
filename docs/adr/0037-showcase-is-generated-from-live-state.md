# ADR-0037: The homelab showcase is generated from live state

- Status: accepted
- Date: 2026-10-20
- Related: `docs/plans/2026-10-20-homelab-showcase-design.md`, ADR-0002, ADR-0014, `stacks/learn/`, `stacks/pages-publish/`, `cli/services.go`, `cli/edges.go`

## Context

Viktor wants a public page that shows the homelab to other homelabbers and stays current without hand edits. The facts it needs already live in running systems: ingress annotations (the service catalog), Prometheus and the Proxmox exporter (size and traffic), `goldmane_edges` (service-to-service flows) and the architecture docs. A hand-written page would fall behind within weeks. The `overview.md` doc shows this: it still says "70+ services" while the catalog holds 139.

## Decision

The **Showcase** is rebuilt daily by `homelab showcase build` into one **Snapshot** (`data.json`). Five **Variants** render that Snapshot (the fifth, Home, added 2026-10-21). Nothing on the page is written by hand except two things:

- a `<!-- showcase: ... -->` summary in each mapped architecture doc, which the build requires;
- `showcase/hardware.yaml`, for physical kit no exporter reports;
- the `<!-- showcase-highlight: ... -->` sections of `docs/architecture/home-automation.md`, quoted on the Home view.

None of these may contain numbers, so the prose cannot contradict the live stats beside it.

The Home view's dashboard screenshots are the one exception to "generated daily": `homelab showcase shots` captures and masks them on demand, the repo owner approves each image, and they are committed under `showcase/web/home/`.

The generator is deterministic: no LLM writes any text.

What it publishes:

- The service catalog is published in full. The infra repo and Homepage's public API already expose it.
- Flow data is published only between namespaces that have a visible catalog service. Shared infrastructure is reduced to "uses X" badges.
- No service is labelled "public" or "no login"; the access states are SSO, app login and LAN only.
- The Home view publishes counts from the Sofia Home Assistant only: devices, entities, integrations, automations by kind and dashboards. No names of people, rooms, entities or automations, no live states, and no brands for the alarm, lock and cameras, which are counted on one "security" line. The build reads HA with its own revocable token (`secret/showcase`, `ha_sofia_token`). If HA is unreachable, the build reuses the last published Home section and marks it stale instead of failing.

## Consequences

- A new service appears on the Showcase the day after its ingress lands, unless the ingress or namespace opts out with `showcase.viktorbarzin.me/hidden`.
- Adding or renaming a mapped architecture doc requires a summary comment, or the daily build fails and posts to #alerts.
- The private monorepo receives about one generated commit a day under `pages/showcase/homelab/`.
- Flow data now leaves the cluster in filtered form. Changing the filter is a change to what the public sees, so it goes through review like any other change to this ADR.

## Alternatives considered

- **A curated `showcase.yaml`.** It gives the best prose, but it is only as current as its last edit.
- **LLM-written tour text from the docs**, using the in-cluster llama-cpp. The prose would be fresher, but it can state things that are not true about a system strangers will read about.
- **Publishing every observed edge.** It is the most complete graph, but it amounts to an east-west map of the cluster under an observe-only egress policy. The repo does not contain that map today.
