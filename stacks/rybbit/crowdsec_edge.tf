# =============================================================================
# CrowdSec edge enforcement for Cloudflare-PROXIED hosts — RETIRED 2026-08-18
# =============================================================================
# Enforcement for proxied hosts is now IN-CLUSTER, at the Traefik `websecure`
# entrypoint: `stacks/traefik/modules/traefik/crowdsec-bouncer-plugin` plus the
# `crowdsec` Middleware in that module's middleware.tf. Everything this file used
# to own — the account IP List, the least-privilege API token, the sync CronJob
# and its script — is gone.
#
# WHY THE EDGE CHANNEL COULD NOT BE KEPT. The Cloudflare Lists API holds a hard
# ~72h floor between successful item writes. From the account audit log
# (resource.type=iplists, complete history since the list was created
# 2026-06-20; 22 events, 16 intervals): 8 of 16 intervals fall in
# [72h, 72h+120s), three land on exactly 259,200s, and no interval anywhere sits
# between 4.5h and 72h. Rejected attempts do not consume the budget
# (08-01 01:12:03 -> 08-04 01:12:03 is exactly 72h 0s with ~1,900 refusals in
# between), but every window in which drift existed was fully consumed: the edge
# list disagreed with CrowdSec for 107 of 216 observed hours over 30 days.
#
# The failure that ended it: on 2026-08-16 a hand-written ban on our own London
# WAN egress (137.220.71.46 — a legitimate Nextcloud desktop client) reached the
# edge two days later and blocked every proxied host. The LAPI decision was
# deleted the same morning, but the list could not be corrected for days, so a
# temporary `ip.src ne 137.220.71.46` clause in the WAF rule was what kept access
# working. Deleting the list removed both that clause's reason and the stale
# entry, and needed no Lists write.
#
# In-cluster, the same unban now takes effect in ~33s (measured 2026-08-18).
#
# Cloudflare's managed DDoS L7 protection and Bot Fight Mode are independent of
# all this and were never touched.
#
# WHAT IS DELIBERATELY NOT DESTROYED. `cloudflare_ruleset.crowdsec` held the
# zone's `default` http_request_firewall_custom PHASE ENTRYPOINT (id
# 106a1342bc88454ea59c47ad3431fe0e), which also carries an unrelated, disabled
# `skip` rule that predates us. Deleting the resource would have planned a DELETE
# on that ruleset — wiping the zone's entire custom-rules phase, or failing the
# apply and blocking every later change to this stack. So it was first edited
# down to just the preserved skip rule (applied separately), and is detached from
# state here rather than destroyed.
#
# This `removed` block can be deleted once it has applied; it is inert afterwards.
# =============================================================================

removed {
  from = cloudflare_ruleset.crowdsec

  lifecycle {
    destroy = false
  }
}
