# Contents for cloudflare account
variable "cloudflare_api_key" {}
variable "cloudflare_email" {}
variable "cloudflare_proxied_names" { type = list(string) }
variable "cloudflare_non_proxied_names" { type = list(string) }
variable "cloudflare_zone_id" {
  description = "Zone ID for your domain"
  type        = string
}
variable "cloudflare_account_id" {
  type      = string
  sensitive = true
}
variable "cloudflare_tunnel_id" {
  type      = string
  sensitive = true
}
variable "public_ip" {
  type = string
}
variable "public_ipv6" {
  type        = string
  description = "Public IPv6 address for AAAA records (from HE tunnel broker)"
}


terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5"
    }
  }
}
provider "cloudflare" {
  api_key = var.cloudflare_api_key # I gave up on getting the permissions on the token...
  email   = var.cloudflare_email
}


locals {
  cloudflare_proxied_names_map = {
    for h in var.cloudflare_proxied_names :
    h => h
  }
  cloudflare_non_proxied_names_map = {
    for h in var.cloudflare_non_proxied_names :
    h => h
  }
}

# Zone-level Bot Management. ai_bots_protection was "block" — CF returned
# 403 to declared AI bot UAs at the edge, so the in-cluster x402 gateway
# never got a chance to issue HTTP 402 with a payment offer. Flipped to
# "disabled" so AI bots reach Traefik → x402, which returns 402 with the
# wallet address. Generic Bot Fight Mode + crawler protection stay on.
# (import {} stanza for adoption lives in the root stack — TF restriction.)
resource "cloudflare_bot_management" "zone" {
  zone_id            = var.cloudflare_zone_id
  enable_js          = true
  fight_mode         = true
  ai_bots_protection = "disabled"
  # Provider v5 defaults is_robots_txt_managed to false, so it is pinned to the
  # value the zone already had (true) to keep the v5 move a no-op.
  # crawler_protection keeps whatever the API has (enabled).
  is_robots_txt_managed = true
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "sof" {
  account_id = var.cloudflare_account_id
  tunnel_id  = var.cloudflare_tunnel_id

  # Provider v5 has no config.warp_routing on this resource; the v4 block here
  # was `warp_routing { enabled = true }` and was dropped with the v5 move.
  config = {
    # Wildcard rule routes all subdomains through the tunnel to Traefik,
    # which handles host-based routing via K8s Ingress resources.
    # Origin = in-cluster Traefik Service DNS (NOT a MetalLB LB IP) so the
    # tunnel is decoupled from LB-IP changes. A raw IP here caused a full-site
    # 502 on 2026-06-01 when Traefik moved 10.0.20.200 -> .203; see
    # docs/post-mortems/2026-06-01-cloudflared-stale-traefik-origin.md.
    ingress = [
      {
        hostname = "*.viktorbarzin.me"
        service  = "https://traefik.traefik.svc.cluster.local:443"
        origin_request = {
          no_tls_verify = true
          # cloudflared's own defaults, spelled out because the v5 provider
          # would otherwise plan them to null on every apply.
          connect_timeout          = 30
          disable_chunked_encoding = false
          http2_origin             = false
          keep_alive_connections   = 100
          keep_alive_timeout       = 90
          no_happy_eyeballs        = false
          tcp_keep_alive           = 30
          tls_timeout              = 10
          ca_pool                  = ""
          http_host_header         = ""
          origin_server_name       = ""
          proxy_type               = ""
        }
      },
      {
        hostname = "viktorbarzin.me"
        service  = "https://traefik.traefik.svc.cluster.local:443"
        origin_request = {
          no_tls_verify = true
          # cloudflared's own defaults, spelled out because the v5 provider
          # would otherwise plan them to null on every apply.
          connect_timeout          = 30
          disable_chunked_encoding = false
          http2_origin             = false
          keep_alive_connections   = 100
          keep_alive_timeout       = 90
          no_happy_eyeballs        = false
          tcp_keep_alive           = 30
          tls_timeout              = 10
          ca_pool                  = ""
          http_host_header         = ""
          origin_server_name       = ""
          proxy_type               = ""
        }
      },
      {
        service = "http_status:404"
      },
    ]
    origin_request = {}
  }
}

# Wildcard: ONE proxied CNAME serves every proxied hostname (2026-07-09).
# The tunnel config above already routes *.viktorbarzin.me → Traefik, which
# routes by Host header — per-name CNAMEs added nothing but a DNS answer while
# eating the free-plan 200-records-per-zone cap (hit on 2026-07-04, blocked a
# deploy). DNS wildcard semantics: any name with an explicit record (apex,
# non-proxied A/AAAA, "internal" shadows) wins over the wildcard; only
# recordless names fall through to it. Consequences, accepted deliberately:
#   - unknown/typo'd subdomains resolve and get Traefik's 404 (was NXDOMAIN);
#   - a .me ingress with NO record is now publicly reachable — "dark by
#     missing DNS" is dead; internal-only names MUST use dns_type="internal"
#     (see docs/adr/0021).
# The apex is NOT covered by a wildcard — stacks/blog keeps its explicit "@"
# record via the ingress_factory apex carve-out.
resource "cloudflare_dns_record" "wildcard" {
  # nonsensitive(): the tunnel UUID is already public in every proxied
  # CNAME answer, and marking the content sensitive makes v5 plan an update.
  content = "${nonsensitive(var.cloudflare_tunnel_id)}.cfargotunnel.com"
  name    = "*"
  proxied = true
  ttl     = 1
  type    = "CNAME"
  zone_id = var.cloudflare_zone_id
}

resource "cloudflare_dns_record" "dns_record" {
  # count   = length(var.cloudflare_proxied_names)
  # name    = var.cloudflare_proxied_names[count.index]
  for_each = local.cloudflare_proxied_names_map
  name     = each.key

  content = "${var.cloudflare_tunnel_id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  type    = "CNAME"
  zone_id = var.cloudflare_zone_id
}

resource "cloudflare_dns_record" "non_proxied_dns_record" {
  # count = length(var.cloudflare_non_proxied_names)
  # name    = var.cloudflare_non_proxied_names[count.index]
  for_each = local.cloudflare_non_proxied_names_map
  name     = each.key

  # content = var.non_proxied_names[count.index].ip
  content = var.public_ip
  proxied = false
  ttl     = 1
  type    = "A"
  zone_id = var.cloudflare_zone_id
}


# No AAAA for the central non-proxied names (removed 2026-07-09): they serve
# non-web ports — wireguard 51820/udp, coturn 3478, xray-reality 7443 — that
# the IPv6 ingress bridge (pfSense HAProxy: 443/80 + mail only, see
# docs/architecture/networking.md → "IPv6 Ingress") never carries. Their AAAA
# records pointed v6-preferring clients at closed ports (WireGuard does not
# fall back to A). Web/mail AAAA records come from ingress_factory
# "non-proxied" instances, which stay dual-stack.

resource "cloudflare_dns_record" "mail_mx" {
  content  = "mail.viktorbarzin.me"
  name     = "viktorbarzin.me"
  proxied  = false
  ttl      = 1
  type     = "MX"
  priority = 1
  zone_id  = var.cloudflare_zone_id
}

# Backup MX host (ADR-0019) — the Oracle Always-Free relay. IP is the OCI
# RESERVED public IP (stable across VM stop/start; owned by stacks/backup-mx).
resource "cloudflare_dns_record" "backup_mx_a" {
  content = "92.5.132.215"
  name    = "mx2.viktorbarzin.me"
  proxied = false
  ttl     = 1
  type    = "A"
  zone_id = var.cloudflare_zone_id
}

# dnstt DNS tunnel (VPN OCI PoP-2, vpn.viktorbarzin.me config portal,
# 2026-07-13): delegate t.viktorbarzin.me to mx2, which runs dnstt-server on
# :53/udp. A dnstt client encodes its tunnelled TCP stream into
# <data>.t.viktorbarzin.me query labels sent through ANY recursive/DoH resolver;
# the recursion is referred here and mx2 answers — so the tunnel rides plain DNS
# and works on networks where only DNS/DoH escapes (the transport of last
# resort). Nameserver is mx2.viktorbarzin.me, already A→92.5.132.215
# (backup_mx_a above) so it is in-zone glue. NS records are never proxied.
resource "cloudflare_dns_record" "dnstt_ns" {
  content = "mx2.viktorbarzin.me"
  name    = "t"
  ttl     = 1
  type    = "NS"
  zone_id = var.cloudflare_zone_id
}

# Backup MX at priority 20 — senders fall to it only when the primary (pri 1)
# is unreachable. ARMED now that the drain path works end-to-end (gate O3:
# mx2's WireGuard tunnel IP 10.3.2.10 is whitelisted past the primary's PTR
# check). mx2 queues up to 30 days and drains to the primary on recovery.
resource "cloudflare_dns_record" "backup_mx_mx" {
  content  = "mx2.viktorbarzin.me"
  name     = "viktorbarzin.me"
  proxied  = false
  ttl      = 1
  type     = "MX"
  priority = 20
  zone_id  = var.cloudflare_zone_id
}

# Status page (ADR-0020) — gatus on mx2, the same Oracle Always-Free VM as the
# backup MX (stacks/backup-mx owns the host; same OCI reserved IP as
# backup_mx_a above). MUST stay grey-cloud: the page's whole job is to be up
# when the homelab AND the tunnel are down, so it cannot ride the CF
# proxy→tunnel path; grey also means the outage-failover Worker's subrequest
# to https://status.viktorbarzin.me/error.html goes straight to mx2 and can
# never re-enter a Worker route (routes only see proxied traffic — no
# recursion possible). Do NOT re-add "status" to cloudflare_proxied_names.
resource "cloudflare_dns_record" "status_a" {
  content = "92.5.132.215"
  name    = "status"
  proxied = false
  ttl     = 1
  type    = "A"
  zone_id = var.cloudflare_zone_id
}

# Permanent synthetic origin-unreachable host (ADR-0020) — proxied CNAME to a
# tunnel UUID that does not exist, so Cloudflare answers 530/1033 for it
# forever. Lets us verify the outage-failover Worker end-to-end (see
# worker.tf) without touching real traffic or waiting for a real outage. One
# permanent DNS record + a trickle of Worker requests — negligible cost,
# deliberate.
resource "cloudflare_dns_record" "test_failover" {
  content = "00000000-0000-0000-0000-000000000000.cfargotunnel.com"
  name    = "test-failover"
  proxied = true
  ttl     = 1
  type    = "CNAME"
  zone_id = var.cloudflare_zone_id
}


resource "cloudflare_dns_record" "mail_spf" {
  # Brevo replaced Mailgun as the outbound relay on 2026-04-12 (see docs/architecture/mailserver.md).
  # Soft-fail (~all) is intentional during cutover — revisit once relay delivery is stable.
  content = "\"v=spf1 include:spf.brevo.com ~all\""
  name    = "viktorbarzin.me"
  proxied = false
  ttl     = 1
  type    = "TXT"
  zone_id = var.cloudflare_zone_id
}

resource "cloudflare_dns_record" "mail_domainkey_rspamd" {
  content = "\"v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAs9XHeFBKhUAEJSikXx+P49Q3nEBbnaSpn6h/9TqIhKaZWSVa2uGUGYQieNdon7DEJZ0VFo0Tvm3/UFsy2qF7ZmF+E/+N8EmkcPrMlxgJT281dpk5DxrZ+kbzw/DosfHH71K6vCLB4rSexzxJHaAx0AUddI3bFUJGjMgCXXCMZF+p8YCx+DDGPIX\" \"z2FOTtlJlR7aeZ2xXavwE/lBfI3MLnsq7X+GhPjQEax070nndOdZI0S8HpZkVxdGWl1N2Ec6LukYm2RiUkEMMQHSYX7WF3JBc+CGqUyd706Iy/5oeC3UGwZSM2uLkrp8YBjmw/h1rAeyv/ITt6ZXraP/cIMRiVQIDAQAB\""
  name    = "mail._domainkey.viktorbarzin.me"
  proxied = false
  ttl     = 1
  type    = "TXT"
  zone_id = var.cloudflare_zone_id
}

resource "cloudflare_dns_record" "brevo_domainkey1" {
  content = "b1.viktorbarzin-me.dkim.brevo.com"
  name    = "brevo1._domainkey.viktorbarzin.me"
  proxied = false
  ttl     = 1
  type    = "CNAME"
  zone_id = var.cloudflare_zone_id
}

resource "cloudflare_dns_record" "brevo_domainkey2" {
  content = "b2.viktorbarzin-me.dkim.brevo.com"
  name    = "brevo2._domainkey.viktorbarzin.me"
  proxied = false
  ttl     = 1
  type    = "CNAME"
  zone_id = var.cloudflare_zone_id
}

resource "cloudflare_dns_record" "brevo_code" {
  content = "\"brevo-code:a6ef1dd91b248559900246eb4e7ceebd\""
  name    = "viktorbarzin.me"
  proxied = false
  ttl     = 1
  type    = "TXT"
  zone_id = var.cloudflare_zone_id
}

resource "cloudflare_dns_record" "mail_mta_sts" {
  content = "\"v=STSv1; id=20261031\""
  name    = "_mta-sts.viktorbarzin.me"
  proxied = false
  ttl     = 1
  type    = "TXT"
  zone_id = var.cloudflare_zone_id
}

resource "cloudflare_dns_record" "mail_dmarc" {
  content = "\"v=DMARC1; p=quarantine; pct=100; fo=1; ri=3600; sp=quarantine; adkim=r; aspf=r; rua=mailto:dmarc@viktorbarzin.me,mailto:adb84997@inbox.ondmarc.com; ruf=mailto:dmarc@viktorbarzin.me,mailto:adb84997@inbox.ondmarc.com,mailto:postmaster@viktorbarzin.me;\""
  name    = "_dmarc.viktorbarzin.me"
  proxied = false
  ttl     = 1
  type    = "TXT"
  zone_id = var.cloudflare_zone_id
}

resource "cloudflare_dns_record" "keyserver" {
  content = "130.162.165.220" # Oracle VPS
  name    = "keyserver.viktorbarzin.me"
  proxied = false
  ttl     = 3600
  type    = "A"
  zone_id = var.cloudflare_zone_id
}

# bridge.viktorbarzin.me (Cloudflare Pages, "мост" school site) moved to
# stacks/valia-sites (ADR-0018) — all Valia-site records live there now.
# State handoff was a manual `tg state rm` (2026-07-03): the CI terraform
# (<1.7) rejects removed{} blocks even at the stack root, so declarative
# forget wasn't available. valia-sites imported the live record by id.

# Enable HTTP/3 (QUIC) for Cloudflare-proxied domains.
#
# Briefly switched off on 2026-08-31 while we chased truncated Immich
# downloads. QUIC was not the cause: an 11-agent investigation excluded every
# server-side candidate by measurement, and the truncation is terminated at the
# client end. Turned back on the same day.
#
# Provider v5 (2026-10-16) replaced cloudflare_zone_settings_override with one
# cloudflare_zone_setting per setting. The old resource was dropped from state
# first with a v4 removed{} block (the live setting stayed on), and this one
# was adopted with an import block (applied, then dropped, on 2026-10-16).
resource "cloudflare_zone_setting" "http3" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "http3"
  value      = "on"
}
