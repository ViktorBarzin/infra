# ADR-0032: phpIPAM is an auto-filled address inventory, fed by one importer

- Status: accepted
- Date: 2026-10-13
- Related: `docs/plans/2026-10-13-phpipam-inventory.md` (design and rollout), `docs/architecture/dns.md` ("London devices", "DHCP → DNS Auto-Registration")

## Context

Viktor asked for phpIPAM to keep track of every IP address in the network. On
2026-10-13 it did not:

- Two of its three jobs had written nothing since 2026-04-10.
  `phpipam-pfsense-import` and the old `phpipam-remote-import` used Alpine's
  MariaDB client, which cannot log in to the dbaas MySQL 8.4, and discarded the
  error. Both logged "Import complete" every hour.
- Only the London subnets were current, after `phpipam-remote-import` was
  rewritten earlier the same day (`stacks/phpipam/files/london_import.py`).
- Three networks with live addresses had no subnet: Sofia CCTV
  (`10.0.30.0/24`), Mladost 3 (`192.168.3.0/24`) and Headscale
  (`100.64.0.0/10`).
- phpIPAM's own scan agent was configured on every subnet and had not run since
  April; the web pod runs no cron.
- `phpipam-dns-sync` pushed every named row to Technitium every 15 minutes, so
  phpIPAM was also acting as a DNS source for Sofia, alongside Kea DDNS.

Most existing rows are hand rows that Viktor wrote: about 60 of the 70, each
with a human description ("SONY TV", "Paradox IP150+ Alarm").

## Decision

phpIPAM is an inventory. It shows every IPv4 address in use, filled
automatically. Kea, Terraform and the site routers stay authoritative for
configuration; nothing reads phpIPAM to assign an address.

1. **One importer.** `phpipam-import` runs every 5 minutes. It has one reader
   per source and one engine for rows, names, expiry and DNS. A source that
   fails is reported and fails the run; the other sources are still applied,
   and the failed source's rows are left untouched.
2. **Scope.** Sofia home LAN, mgmt, k8s and CCTV VLANs; London LAN and guest;
   Valchedrym; Mladost 3; the WireGuard tunnel network; Headscale. IPv4 only.
   Pod and Service ranges are out of scope.
3. **Ownership by description.** A row the importer writes has a description
   starting with `-- `. Any other description makes it a hand row, which the
   importer never changes, renames or expires. Changing a row's description in
   the UI is how a person takes a row over.
4. **Two kinds of automation row.** A dynamic row (DHCP lease or ARP entry) is
   keyed by MAC, follows its device to a new address, and is deleted 24 hours
   after its device was last seen. A declared row (k8s node, MetalLB address,
   Kea reservation, WireGuard peer, Headscale node) is keyed by IP and stays as
   long as its source lists it.
5. **Names.** Precedence: hand row, then reservation name, then the hostname in
   the lease, then the existing DNS name, then none.
6. **DNS.** Names flow into phpIPAM from DHCP and DNS. The importer publishes to
   `viktorbarzin.lan` only (a) leases at the OpenWrt sites (London,
   Valchedrym, Mladost 3), which have no DDNS, with the London naming rules
   and a `-<site>` suffix on a clash, and (b) hand rows. It never overwrites a
   record it does not own; a hand row whose name is held elsewhere is logged
   and left unpublished. Headscale names stay in phpIPAM.
   `phpipam-dns-sync` is retired.
7. **Sofia home LAN.** Its DHCP server is the TP-Link router, which has no
   readable API. pfSense ping-sweeps `192.168.1.0/24` before each read so its
   ARP table lists every device that is up.
8. **Layout.** Locations for the four sites, VLANs 10, 20 and 30, the two demo
   VLANs removed, and phpIPAM's own scan flags off. The importer sets these
   idempotently.
9. **Alerting.** The existing `JobFailed` alert, plus `PhpipamImportStale` when
   the import has not succeeded for 30 minutes.

## Consequences

- One writer for London, Valchedrym and Mladost 3 names, and for hand-row
  names. Kea DDNS keeps writing the Kea networks' names; the ingress sync keeps
  writing ingress names.
- The importer needs the pfSense SSH key it already uses, a Technitium token, a
  Headscale API key (`secret/platform` `phpipam_headscale_api_key`) and a
  ServiceAccount that can list nodes and Services.
- Records the importer owns outside the site ranges carry the Technitium record
  comment `phpipam`, so it can remove them when a hand row is renamed or
  deleted. Records `phpipam-dns-sync` wrote in the past have no comment and are
  adopted when a hand row claims the same name and address.
- Rows of departed phones disappear after a day, so phpIPAM answers "what is on
  the network now", not "what was on .57 last month".
- An ARP-only device on the Sofia LAN has no hostname unless DNS or a hand row
  names it.

## Open questions

- Whether a ping sweep every 5 minutes disturbs any of the Sofia LAN's IoT
  devices. None is known to; the sweep is one ICMP echo per address.
- Whether some Sofia LAN devices answer neither ARP nor ping while idle (some
  battery devices sleep), and so drop out of phpIPAM after 24 hours. A hand row
  keeps any device that matters.
