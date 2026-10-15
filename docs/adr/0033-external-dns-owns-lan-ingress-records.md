# ADR-0033: external-dns owns the records for *.viktorbarzin.lan Ingress hosts

- Status: accepted
- Date: 2026-10-14
- Related: `docs/architecture/dns.md` ("Dynamic updates", "Adding a New DNS Record"), `docs/runbooks/pfsense-unbound.md` ("Kea DHCP-DDNS TSIG"), `stacks/technitium/modules/technitium/{external_dns.tf,dynamic_updates.tf}`

## Context

On 2026-10-13 the documented LAN URL for the Android emulator,
`android-emulator.viktorbarzin.lan`, returned NXDOMAIN. Nothing created
`.lan` records for Ingress hosts: the hourly `technitium-ingress-dns-sync`
CronJob handled `viktorbarzin.me` only, and every `.lan` Ingress name that did
resolve (loki, snmp-exporter, prometheus-query and others) had been added by
hand through the Technitium API. `anisette.viktorbarzin.lan` was missing too.

A same-day fix taught the hourly cron to add `.lan` CNAMEs. Viktor then asked
for the records to follow the kube API directly, and for a record to go away
when its Ingress does.

While planning, two more facts came to light:

- The `.lan` zone refused all dynamic updates on all three Technitium
  instances (`update=Deny`, no key policies), although `dns.md` described the
  Kea TSIG setup from 2026-04-19 as live. Zone options and TSIG keys are
  per-instance settings that AXFR does not copy, and they had been set by hand.
- Kea DHCP-DDNS is also off on pfSense: the daemon is not running, and pfSense
  regenerated `kea-dhcp4.conf` on 2026-07-18 without the hand-added DDNS
  settings.

## Decision

1. **external-dns** (kubernetes-sigs, chart 1.22.0, app v0.22.0) runs in the
   `technitium` namespace with the rfc2136 provider. It watches Ingress objects
   only, filters to `viktorbarzin.lan`, and writes to the Technitium primary
   with its own TSIG key. Each host gets an A record (the Ingress status
   address, Traefik's LB IP) and a TXT ownership record `edns-a-<host>`
   (owner `k8s-lan`), TTL 300.
2. **Deletes are limited to owned records.** With `policy=sync` external-dns
   removes a record when its Ingress goes away, but its planner skips any name
   that holds a record it does not own: no create, update or delete. Names
   from DHCP, phpipam-import, `technitium-static-records` and hand records are
   therefore never touched, and a new Ingress whose host collides with one of
   them gets no record.
3. **Scope is `.lan` only.** Internal `viktorbarzin.me` records stay with the
   hourly cron, which also carries the mail-auth, Valia and mx2 records.
4. **A Terraform-managed CronJob, `technitium-dynamic-updates`, owns the update
   settings** on all three instances every hour: the full TSIG key list
   (`external-dns` generated in Terraform, `kea-ddns` from Vault), the update
   ACL, and the key policies on `.lan` and the three Kea reverse zones. Viktor
   chose to restore the Technitium side of Kea DDNS in the same change, so
   Kea's updates are accepted again once pfSense sends them. Re-enabling DDNS
   on pfSense is a separate task.
5. **The existing nine Ingress names were handed over** on 2026-10-14 by adding
   each one's ownership TXT and swapping its CNAME for an A record in two
   back-to-back API calls, so no name went without a record.

## Consequences

- A new `.lan` Ingress host resolves at the primary within seconds (measured:
  5s from Ingress creation to record), and its record and TXT are removed when
  the Ingress is deleted (measured on a throwaway Ingress, 2026-10-14).
  Replicas and pfSense's copy of the zone pick changes up on their own refresh,
  so LAN clients can wait up to about 30 minutes. The primary's NOTIFY goes to
  the NS record, which names a pod, so replicas get no push.
- Records are A records to the Ingress status address rather than CNAMEs to
  `ingress.viktorbarzin.lan`, so a Traefik LB IP change reaches them through
  the Ingress status. The anchor record stays for the hand-made names that
  still point at it.
- A refused or unsigned zone transfer reads as an empty zone to external-dns,
  not as an error. The `ExternalDNSLanZoneEmpty` alert (registry endpoints
  below 20, about 134 normally) covers that case, alongside sync-stale,
  soft-error, and reconciler failed/stale alerts.
- Hosts on a Traefik IngressRoute with no Ingress object are not covered.
  None used a `.lan` host on 2026-10-14; such a name belongs in
  `technitium-static-records`.
- The `.lan` zone allows zone transfers from any address, so the TXT
  ownership records expose namespace and Ingress names to anyone on the
  network who asks for a transfer. That was already true of the zone's
  records; restricting transfers is outside this change.
- TSIG key rotation is now an edit to `dynamic_updates.tf`, because the
  CronJob rewrites the key list and policies every hour.

## Open questions

- How and where to re-enable Kea DDNS on pfSense so that a GUI save of the
  DHCP settings does not remove it again.
- The tertiary instance refuses zone transfers for `.lan`
  (`zoneTransfer=Deny`). It matters only if the LB sends pfSense's transfer to
  that instance's node.
