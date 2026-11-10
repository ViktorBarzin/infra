# ADR-0038: OPNsense replaces pfSense as the edge firewall

- Status: accepted
- Date: 2026-11-03
- Related: `docs/plans/2026-11-03-opnsense-migration.md`, `docs/research/2026-11-03-network-ids-options.md`, `docs/architecture/networking.md`, `docs/architecture/compute.md` (VMs and Terraform)

## Context

The edge firewall is pfSense CE 2.7.2, a VM on the Proxmox host. Three things changed in November 2026:

- 2.7.2 is out of support; Netgate's supported CE releases are 2.8.1 and 2.9.0 ([versions](https://docs.netgate.com/pfsense/en/latest/releases/versions.html)).
- Netgate announced that from 26.10 CE and Plus become one edition: features and security fixes free, moving to a new version free by reinstalling or paid as an online upgrade, and the PHP GUI to be removed once the new GUI replaces it ([pfSense at 20](https://www.netgate.com/blog/pfsense-at-20)).
- We wanted a maintained IDS feeding CrowdSec. The pfSense Suricata package on 2.7.2 runs engine 7.0.8, whose branch is end of life since 2026-07-07 ([Suricata EOL policy](https://suricata.io/our-story/eol-policy/)).

Our pfSense configuration is automated by playbooks that run PHP against pfSense's internal configuration code. Those would need rewriting once the PHP layer goes, whichever firewall we run.

## Decision

OPNsense 26.7 replaces pfSense. It is built next to pfSense on spare addresses and swapped in later as a VM swap, with pfSense kept stopped for two weeks as the rollback.

- The VM is declared in Terraform with the `bpg/proxmox` provider in its own stack. This is the first VM back in Terraform since the 2026-05-26 decision to keep VMs out (telmate provider bugs, `compute.md`); that decision named `bpg/proxmox` as the path back, and a new VM involves no import of existing ones.
- OPNsense's configuration is declared in the repo as YAML and applied by Ansible over OPNsense's REST API, with a small bootstrap `config.xml` for what the API does not cover.
- Suricata 8 runs in IDS mode and feeds CrowdSec through the `os-crowdsec` plugin, which also enforces CrowdSec decisions at the edge.

## Consequences

- One cutover with a short outage, and a rebuild of everything pfSense does today, done once against a documented API.
- Free online upgrades twice a year; the IDS engine and rules stay current.
- CrowdSec range bans are enforced at the edge, which also covers mail (the node bouncer stores range decisions as single addresses).
- A second VM in Terraform: the stack holds only this VM and uses `prevent_destroy`, so a provider bug cannot reach the others.
- Dropped in the move: FRR BGP (configured, not running), FreeRADIUS (test user only), UPnP (enabled, not running), Netgate cloud backup.

## Alternatives considered

- Upgrade pfSense CE to 2.9 and then 26.10: keeps today's automation working until the PHP layer is removed, then needs the same rewrite against an API not yet published. Version moves after 26.10 are free only by reinstalling.
- A separate Suricata sensor VM fed by host-side mirroring: keeps the IDS out of the firewall's failure path, but adds a VM and host networking to maintain; with OPNsense the firewall's own Suricata is current.

## Amendment, 2026-11-10: carried out

The cutover ran on 2026-11-10 as a VM swap with pfSense's MACs and a dead-man revert (`scripts/opnsense-cutover`, runbook `docs/runbooks/opnsense.md`). Two changes to the decision as written: the CrowdSec bouncer blocks inbound on WAN and the HE tunnel only and takes CAPI, local and manual decisions, not the static ASN lists (the plugin's own rules blocked both directions for every client); and pfSense stays stopped with its NICs link-down until 2026-11-24 as the rollback.

Amendment, 2026-11-10 (later the same day): Viktor chose to keep pfSense as the rollback with no removal date, instead of the two weeks above.
