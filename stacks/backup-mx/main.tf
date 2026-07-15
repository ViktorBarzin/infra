# Backup MX relay on Oracle Cloud Always-Free — ADR-0019.
# Design: docs/plans/2026-07-04-backup-mx-design.md. Runbook: docs/runbooks/backup-mx.md.
#
# Everything here is deliberately cattle: the VM is rebuilt entirely from this
# stack + cloud-init.yaml.tftpl. Rebuild procedure (also in the runbook):
# mint a fresh headscale preauth key (single-use) into Vault
# secret/viktor.backup_mx_headscale_preauth, then taint the instance and apply.

data "vault_kv_secret_v2" "viktor" {
  mount = "secret"
  name  = "viktor"
}

# Shared Alertmanager Slack webhook (same key the monitoring stack reads) —
# gatus's edge sentinels page the same #alerts channel as everything else
# instead of growing a second notification path (ADR-0020).
data "vault_kv_secret_v2" "platform" {
  mount = "secret"
  name  = "platform"
}

locals {
  tenancy_ocid = data.vault_kv_secret_v2.viktor.data["oci_tenancy_ocid"]
  mx_hostname  = "mx2.viktorbarzin.me"
  # 10.99/24 collides with nothing at home (10.0.x VLANs, 10.10/16 pods,
  # 10.96/12 services, 100.64/10 tailnet).
  vcn_cidr = "10.99.0.0/24"
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = local.tenancy_ocid
}

locals {
  # E2.1.Micro Always-Free capacity exists ONLY in AD-3 of this tenancy
  # (verified live 2026-07-08: quota available=2 in AD-3, 0 in AD-1/AD-2).
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[2].name
}

resource "oci_core_vcn" "backup_mx" {
  compartment_id = local.tenancy_ocid
  cidr_blocks    = [local.vcn_cidr]
  display_name   = "backup-mx"
  dns_label      = "backupmx"
}

resource "oci_core_internet_gateway" "backup_mx" {
  compartment_id = local.tenancy_ocid
  vcn_id         = oci_core_vcn.backup_mx.id
  display_name   = "backup-mx-igw"
}

resource "oci_core_default_route_table" "backup_mx" {
  manage_default_resource_id = oci_core_vcn.backup_mx.default_route_table_id
  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.backup_mx.id
  }
}

# Mirrors the VM's own iptables (defense in depth). No SSH from the internet —
# management rides the tailnet (UDP 41641 is outbound-initiated, no ingress
# rule needed; DERP fallback is outbound 443).
resource "oci_core_security_list" "backup_mx" {
  compartment_id = local.tenancy_ocid
  vcn_id         = oci_core_vcn.backup_mx.id
  display_name   = "backup-mx-mail"

  # SMTP — the service.
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 25
      max = 25
    }
  }
  # Permanently open: LE HTTP-01 validation is multi-perspective with no
  # published source IPs; nothing listens outside certbot's renewal seconds.
  # (Since ADR-0020, nginx also serves the ACME webroot + https redirect here.)
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 80
      max = 80
    }
  }
  # Status/error page + failover artifacts over TLS (gatus behind nginx,
  # ADR-0020): status.viktorbarzin.me UI, /error.html for the Cloudflare
  # failover Worker, /myip for the WAN-IP-change detector. ACME stays on 80.
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 443
      max = 443
    }
  }
  # node-exporter, scraped by the homelab Prometheus (egress SNATs to the WAN IP).
  ingress_security_rules {
    protocol = "6"
    source   = "${var.public_ip}/32"
    tcp_options {
      min = 9100
      max = 9100
    }
  }
  # Break-glass SSH, locked to the homelab WAN /32 (NOT public). Design v1 was
  # tailnet-only, but the devvm — where this VM is actually operated from — is
  # not a tailnet node, so tailnet-only management is inoperable in practice
  # (proven during the 2026-07-08 bring-up). Mirrors the PVE :52222 break-glass
  # precedent: source-restricted, key-only. Tailscale still enrolls for the day
  # the devvm joins the tailnet.
  ingress_security_rules {
    protocol = "6"
    source   = "${var.public_ip}/32"
    tcp_options {
      min = 22
      max = 22
    }
  }
  # VPN OCI PoP-2 (vpn.viktorbarzin.me config portal, 2026-07-13): proxy egress
  # paths that are neither the home WAN IP nor Cloudflare — the diversification
  # a censored-network client needs. VLESS-REALITY on :8443 (:443 is taken by
  # gatus/nginx, ADR-0020), Shadowsocks on :8388 (tcp+udp), and the dnstt DNS
  # tunnel on :53 (udp). xray + dnstt-server provisioning lives in cloud-init
  # (the canonical rebuild recipe); the running VM was brought up live over the
  # break-glass SSH to avoid a rebuild. Mirrors the VM's own iptables.
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 8443
      max = 8443
    }
  }
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 8388
      max = 8388
    }
  }
  ingress_security_rules {
    protocol = "17"
    source   = "0.0.0.0/0"
    udp_options {
      min = 8388
      max = 8388
    }
  }
  ingress_security_rules {
    protocol = "17"
    source   = "0.0.0.0/0"
    udp_options {
      min = 53
      max = 53
    }
  }
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

resource "oci_core_subnet" "backup_mx" {
  compartment_id             = local.tenancy_ocid
  vcn_id                     = oci_core_vcn.backup_mx.id
  cidr_block                 = local.vcn_cidr
  display_name               = "backup-mx"
  dns_label                  = "mx"
  route_table_id             = oci_core_vcn.backup_mx.default_route_table_id
  security_list_ids          = [oci_core_security_list.backup_mx.id]
  prohibit_public_ip_on_vnic = false
}

data "oci_core_images" "ubuntu" {
  compartment_id           = local.tenancy_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.E2.1.Micro"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "mx2" {
  availability_domain = local.availability_domain
  compartment_id      = local.tenancy_ocid
  display_name        = "mx2"
  shape               = "VM.Standard.E2.1.Micro"

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu.images[0].id
  }

  create_vnic_details {
    subnet_id      = oci_core_subnet.backup_mx.id
    hostname_label = "mx2"
    # No ephemeral public IP — the reserved one below is attached to the
    # private IP, so the address survives stop/start (four controls are keyed
    # on it: pfSense NAT source, the primary's smtpd/rspamd exemptions, this
    # security list's scrape rule, Prometheus).
    assign_public_ip = false
  }

  metadata = {
    ssh_authorized_keys = data.vault_kv_secret_v2.viktor.data["backup_mx_ssh_public_key"]
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
      ssh_public_key    = data.vault_kv_secret_v2.viktor.data["backup_mx_ssh_public_key"]
      headscale_preauth = data.vault_kv_secret_v2.viktor.data["backup_mx_headscale_preauth"]
      homelab_wan_ip    = var.public_ip
      wg_private_key    = data.vault_kv_secret_v2.viktor.data["backup_mx_wg_private_key"]
      # try(): if the key is ever absent, gatus renders display-only (the
      # template guards every alerting block on non-empty) instead of
      # breaking the plan or the VM.
      alertmanager_slack_api_url = try(data.vault_kv_secret_v2.platform.data["alertmanager_slack_api_url"], "")
      # VPN OCI PoP-2 (vpn.viktorbarzin.me config portal, 2026-07-13): secrets
      # for the xray REALITY/Shadowsocks + dnstt provisioning in the setup
      # script below. Same UUID/SS password as the portal identity so one client
      # config works across the home and OCI PoPs.
      oci_xray_uuid       = data.vault_kv_secret_v2.viktor.data["oci_xray_uuid"]
      oci_xray_ss_password = data.vault_kv_secret_v2.viktor.data["oci_xray_ss_password"]
      oci_reality_privkey = data.vault_kv_secret_v2.viktor.data["oci_reality_privkey"]
      oci_reality_shortid = data.vault_kv_secret_v2.viktor.data["oci_reality_shortid"]
      dnstt_privkey       = data.vault_kv_secret_v2.viktor.data["dnstt_server_privkey"]
    }))
  }

  lifecycle {
    # source_id tracks the NEWEST Ubuntu build — without this, every image
    # release would plan a VM replacement. metadata likewise: the preauth key
    # is single-use and cloud-init only runs on first boot; a changed
    # user_data must never silently replace the instance. Deliberate rebuild =
    # terraform taint (see runbook).
    ignore_changes = [source_details, metadata]
  }
}

data "oci_core_vnic_attachments" "mx2" {
  compartment_id = local.tenancy_ocid
  instance_id    = oci_core_instance.mx2.id
}

data "oci_core_private_ips" "mx2" {
  vnic_id = data.oci_core_vnic_attachments.mx2.vnic_attachments[0].vnic_id
}

# Reserved (not ephemeral) — free of charge, survives instance stop/start.
resource "oci_core_public_ip" "mx2" {
  compartment_id = local.tenancy_ocid
  lifetime       = "RESERVED"
  display_name   = "mx2-reserved"
  private_ip_id  = data.oci_core_private_ips.mx2.private_ips[0].id
}

output "mx2_public_ip" {
  description = "Reserved public IP — goes into the mx2 A record, pfSense NAT source restriction, and the mailserver drain exemptions."
  value       = oci_core_public_ip.mx2.ip_address
}

output "mx2_availability_domain" {
  value = local.availability_domain
}
