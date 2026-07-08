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
      version = "~> 4"

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
  # crawler_protection / is_robots_txt_managed are settable only via newer
  # provider versions; they retain whatever the API currently has
  # (crawler_protection=enabled, is_robots_txt_managed=true).
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "sof" {
  account_id = var.cloudflare_account_id
  tunnel_id  = var.cloudflare_tunnel_id

  config {
    warp_routing {
      enabled = true
    }
    # Wildcard rule routes all subdomains through the tunnel to Traefik,
    # which handles host-based routing via K8s Ingress resources.
    # Origin = in-cluster Traefik Service DNS (NOT a MetalLB LB IP) so the
    # tunnel is decoupled from LB-IP changes. A raw IP here caused a full-site
    # 502 on 2026-06-01 when Traefik moved 10.0.20.200 -> .203; see
    # docs/post-mortems/2026-06-01-cloudflared-stale-traefik-origin.md.
    ingress_rule {
      hostname = "*.viktorbarzin.me"
      service  = "https://traefik.traefik.svc.cluster.local:443"
      origin_request {
        no_tls_verify = true
      }
    }
    ingress_rule {
      hostname = "viktorbarzin.me"
      service  = "https://traefik.traefik.svc.cluster.local:443"
      origin_request {
        no_tls_verify = true
      }
    }
    ingress_rule {
      service = "http_status:404"
    }
  }
}

resource "cloudflare_record" "dns_record" {
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

resource "cloudflare_record" "non_proxied_dns_record" {
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


resource "cloudflare_record" "non_proxied_dns_record_ipv6" {
  for_each = local.cloudflare_non_proxied_names_map
  name     = each.key
  content  = var.public_ipv6
  proxied  = false
  ttl      = 1
  type     = "AAAA"
  zone_id  = var.cloudflare_zone_id
}

resource "cloudflare_record" "mail_mx" {
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
resource "cloudflare_record" "backup_mx_a" {
  content = "92.5.132.215"
  name    = "mx2.viktorbarzin.me"
  proxied = false
  ttl     = 1
  type    = "A"
  zone_id = var.cloudflare_zone_id
}

# Backup MX at priority 20 — senders fall to it only when the primary (pri 1)
# is unreachable. ARMED now that the drain path works end-to-end (gate O3:
# mx2's WireGuard tunnel IP 10.3.2.10 is whitelisted past the primary's PTR
# check). mx2 queues up to 30 days and drains to the primary on recovery.
resource "cloudflare_record" "backup_mx_mx" {
  content  = "mx2.viktorbarzin.me"
  name     = "viktorbarzin.me"
  proxied  = false
  ttl      = 1
  type     = "MX"
  priority = 20
  zone_id  = var.cloudflare_zone_id
}


resource "cloudflare_record" "mail_spf" {
  # Brevo replaced Mailgun as the outbound relay on 2026-04-12 (see docs/architecture/mailserver.md).
  # Soft-fail (~all) is intentional during cutover — revisit once relay delivery is stable.
  content  = "\"v=spf1 include:spf.brevo.com ~all\""
  name     = "viktorbarzin.me"
  proxied  = false
  ttl      = 1
  type     = "TXT"
  priority = 1
  zone_id  = var.cloudflare_zone_id
}

resource "cloudflare_record" "mail_domainkey_rspamd" {
  content = "\"v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAs9XHeFBKhUAEJSikXx+P49Q3nEBbnaSpn6h/9TqIhKaZWSVa2uGUGYQieNdon7DEJZ0VFo0Tvm3/UFsy2qF7ZmF+E/+N8EmkcPrMlxgJT281dpk5DxrZ+kbzw/DosfHH71K6vCLB4rSexzxJHaAx0AUddI3bFUJGjMgCXXCMZF+p8YCx+DDGPIXz2FOTtlJlR7aeZ2xXavwE/lBfI3MLnsq7X+GhPjQEax070nndOdZI0S8HpZkVxdGWl1N2Ec6LukYm2RiUkEMMQHSYX7WF3JBc+CGqUyd706Iy/5oeC3UGwZSM2uLkrp8YBjmw/h1rAeyv/ITt6ZXraP/cIMRiVQIDAQAB\""
  name    = "mail._domainkey.viktorbarzin.me"
  proxied = false
  ttl     = 1
  type    = "TXT"
  zone_id = var.cloudflare_zone_id
}

resource "cloudflare_record" "brevo_domainkey1" {
  content = "b1.viktorbarzin-me.dkim.brevo.com."
  name    = "brevo1._domainkey.viktorbarzin.me"
  proxied = false
  ttl     = 1
  type    = "CNAME"
  zone_id = var.cloudflare_zone_id
}

resource "cloudflare_record" "brevo_domainkey2" {
  content = "b2.viktorbarzin-me.dkim.brevo.com."
  name    = "brevo2._domainkey.viktorbarzin.me"
  proxied = false
  ttl     = 1
  type    = "CNAME"
  zone_id = var.cloudflare_zone_id
}

resource "cloudflare_record" "brevo_code" {
  content = "\"brevo-code:a6ef1dd91b248559900246eb4e7ceebd\""
  name    = "viktorbarzin.me"
  proxied = false
  ttl     = 1
  type    = "TXT"
  zone_id = var.cloudflare_zone_id
}

resource "cloudflare_record" "mail_mta_sts" {
  content = "\"v=STSv1; id=20260412\""
  name    = "_mta-sts.viktorbarzin.me"
  proxied = false
  ttl     = 1
  type    = "TXT"
  zone_id = var.cloudflare_zone_id
}

resource "cloudflare_record" "mail_tlsrpt" {
  content = "\"v=TLSRPTv1; rua=mailto:postmaster@viktorbarzin.me\""
  name    = "_smtp._tls.viktorbarzin.me"
  proxied = false
  ttl     = 1
  type    = "TXT"
  zone_id = var.cloudflare_zone_id
}

resource "cloudflare_record" "mail_dmarc" {
  content  = "\"v=DMARC1; p=quarantine; pct=100; fo=1; ri=3600; sp=quarantine; adkim=r; aspf=r; rua=mailto:dmarc@viktorbarzin.me,mailto:adb84997@inbox.ondmarc.com; ruf=mailto:dmarc@viktorbarzin.me,mailto:adb84997@inbox.ondmarc.com,mailto:postmaster@viktorbarzin.me;\""
  name     = "_dmarc.viktorbarzin.me"
  proxied  = false
  ttl      = 1
  type     = "TXT"
  priority = 1
  zone_id  = var.cloudflare_zone_id
}

resource "cloudflare_record" "keyserver" {
  content  = "130.162.165.220" # Oracle VPS
  name     = "keyserver.viktorbarzin.me"
  proxied  = false
  ttl      = 3600
  type     = "A"
  priority = 1
  zone_id  = var.cloudflare_zone_id
}

# bridge.viktorbarzin.me (Cloudflare Pages, "мост" school site) moved to
# stacks/valia-sites (ADR-0018) — all Valia-site records live there now.
# State handoff was a manual `tg state rm` (2026-07-03): the CI terraform
# (<1.7) rejects removed{} blocks even at the stack root, so declarative
# forget wasn't available. valia-sites imported the live record by id.

# Enable HTTP/3 (QUIC) for Cloudflare-proxied domains
resource "cloudflare_zone_settings_override" "http3" {
  zone_id = var.cloudflare_zone_id

  settings {
    http3 = "on"
  }
}
