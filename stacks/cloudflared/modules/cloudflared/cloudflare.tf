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

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "sof" {
  account_id = var.cloudflare_account_id
  tunnel_id  = var.cloudflare_tunnel_id

  config {
    warp_routing {
      enabled = true
    }
    # Wildcard rule routes all subdomains through tunnel to Traefik.
    # Traefik handles host-based routing via K8s Ingress resources.
    ingress_rule {
      hostname = "*.viktorbarzin.me"
      service  = "https://10.0.20.200:443"
      origin_request {
        no_tls_verify = true
      }
    }
    ingress_rule {
      hostname = "viktorbarzin.me"
      service  = "https://10.0.20.200:443"
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


resource "cloudflare_record" "mail_domainkey" {
  content  = "\"v=DKIM1; k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDIDLB8mhAHNqs1s6GeZMQHOxWweoNKIrqo5tqRM3yFilgfPUX34aTIXNZg9xAmlK+2S/xXO1ymt127ZGMjnoFKOEP8/uZ54iHTCnioHaPZWMfJ7o6TYIXjr+9ShKfoJxZLv7lHJ2wKQK3yOw4lg4cvja5nxQ6fNoGRwo+mQ/mgJQIDAQAB\""
  name     = "s1._domainkey.viktorbarzin.me"
  proxied  = false
  ttl      = 1
  type     = "TXT"
  priority = 1
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
  content  = "\"v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAs9XHeFBKhUAEJSikXx+P49Q3nEBbnaSpn6h/9TqIhKaZWSVa2uGUGYQieNdon7DEJZ0VFo0Tvm3/UFsy2qF7ZmF+E/+N8EmkcPrMlxgJT281dpk5DxrZ+kbzw/DosfHH71K6vCLB4rSexzxJHaAx0AUddI3bFUJGjMgCXXCMZF+p8YCx+DDGPIXz2FOTtlJlR7aeZ2xXavwE/lBfI3MLnsq7X+GhPjQEax070nndOdZI0S8HpZkVxdGWl1N2Ec6LukYm2RiUkEMMQHSYX7WF3JBc+CGqUyd706Iy/5oeC3UGwZSM2uLkrp8YBjmw/h1rAeyv/ITt6ZXraP/cIMRiVQIDAQAB\""
  name     = "mail._domainkey.viktorbarzin.me"
  proxied  = false
  ttl      = 1
  type     = "TXT"
  zone_id  = var.cloudflare_zone_id
}

resource "cloudflare_record" "brevo_domainkey1" {
  content  = "b1.viktorbarzin-me.dkim.brevo.com."
  name     = "brevo1._domainkey.viktorbarzin.me"
  proxied  = false
  ttl      = 1
  type     = "CNAME"
  zone_id  = var.cloudflare_zone_id
}

resource "cloudflare_record" "brevo_domainkey2" {
  content  = "b2.viktorbarzin-me.dkim.brevo.com."
  name     = "brevo2._domainkey.viktorbarzin.me"
  proxied  = false
  ttl      = 1
  type     = "CNAME"
  zone_id  = var.cloudflare_zone_id
}

resource "cloudflare_record" "brevo_code" {
  content  = "\"brevo-code:a6ef1dd91b248559900246eb4e7ceebd\""
  name     = "viktorbarzin.me"
  proxied  = false
  ttl      = 1
  type     = "TXT"
  zone_id  = var.cloudflare_zone_id
}

resource "cloudflare_record" "mail_mta_sts" {
  content  = "\"v=STSv1; id=20260412\""
  name     = "_mta-sts.viktorbarzin.me"
  proxied  = false
  ttl      = 1
  type     = "TXT"
  zone_id  = var.cloudflare_zone_id
}

resource "cloudflare_record" "mail_tlsrpt" {
  content  = "\"v=TLSRPTv1; rua=mailto:postmaster@viktorbarzin.me\""
  name     = "_smtp._tls.viktorbarzin.me"
  proxied  = false
  ttl      = 1
  type     = "TXT"
  zone_id  = var.cloudflare_zone_id
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

# Enable HTTP/3 (QUIC) for Cloudflare-proxied domains
resource "cloudflare_zone_settings_override" "http3" {
  zone_id = var.cloudflare_zone_id

  settings {
    http3 = "on"
  }
}
