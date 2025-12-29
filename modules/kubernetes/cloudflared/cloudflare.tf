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
    dynamic "ingress_rule" {
      for_each = toset(var.cloudflare_proxied_names)
      content {
        hostname = ingress_rule.value == "viktorbarzin.me" ? ingress_rule.value : "${ingress_rule.value}.viktorbarzin.me"
        path     = "/"
        service  = "https://10.0.20.202:443"
        origin_request {
          no_tls_verify = true
        }
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


resource "cloudflare_record" "mail" {
  content  = "mail.viktorbarzin.me"
  name     = "viktorbarzin.me"
  proxied  = false
  ttl      = 1
  type     = "MX"
  priority = 1
  zone_id  = var.cloudflare_zone_id
}

resource "cloudflare_record" "mail_domainkey" {
  content  = "\"k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDIDLB8mhAHNqs1s6GeZMQHOxWweoNKIrqo5tqRM3yFilgfPUX34aTIXNZg9xAmlK+2S/xXO1ymt127ZGMjnoFKOEP8/uZ54iHTCnioHaPZWMfJ7o6TYIXjr+9ShKfoJxZLv7lHJ2wKQK3yOw4lg4cvja5nxQ6fNoGRwo+mQ/mgJQIDAQAB\""
  name     = "s1._domainkey.viktorbarzin.me"
  proxied  = false
  ttl      = 1
  type     = "TXT"
  priority = 1
  zone_id  = var.cloudflare_zone_id
}

resource "cloudflare_record" "mail_spf" {
  content  = "\"v=spf1 include:mailgun.org ~all\""
  name     = "viktorbarzin.me"
  proxied  = false
  ttl      = 1
  type     = "TXT"
  priority = 1
  zone_id  = var.cloudflare_zone_id
}

resource "cloudflare_record" "mail_dmarc" {
  content  = "\"v=DMARC1; p=none; pct=100; fo=1; ri=3600; sp=none; adkim=r; aspf=r; rua=mailto:e21c0ff8@dmarc.mailgun.org,mailto:adb84997@inbox.ondmarc.com; ruf=mailto:e21c0ff8@dmarc.mailgun.org,mailto:adb84997@inbox.ondmarc.com,mailto:postmaster@viktorbarzin.me;\""
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
