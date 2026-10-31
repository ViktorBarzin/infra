# MTA-STS policy host (RFC 8461). Sending MTAs that see the _mta-sts TXT record
# (cloudflare.tf, mail_mta_sts) fetch https://mta-sts.viktorbarzin.me/.well-known/mta-sts.txt
# and apply it to deliveries for viktorbarzin.me. The policy is served by its own
# Worker rather than an in-cluster pod, so it answers during a homelab outage, and
# rather than Cloudflare Pages, because Terraform cannot upload Pages content.
#
# DNS: mta-sts is covered by the proxied wildcard CNAME, so it needs no record of
# its own; the route below claims it before the request reaches the tunnel.
#
# Mode is `testing` (Viktor's call, 2026-10-31): senders still deliver when TLS to
# an MX fails. Switching to `enforce` makes Gmail/Outlook refuse delivery to an MX
# with a bad or expired cert, so it wants an expiry alert on mx2's cert first (the
# wildcard cert on mail is covered by TLSCertExpiringSoon; mx2's is not).
#
# Changing the policy: edit it here AND bump the id in mail_mta_sts, or senders
# keep their cached copy for up to max_age.
locals {
  mta_sts_policy = join("\r\n", [
    "version: STSv1",
    "mode: testing",
    "mx: mail.viktorbarzin.me",
    "mx: mx2.viktorbarzin.me",
    "max_age: 86400",
    "",
  ])
}

resource "cloudflare_workers_script" "mta_sts" {
  account_id         = nonsensitive(var.cloudflare_account_id)
  script_name        = "mta-sts"
  content            = <<-EOT
    const POLICY = ${jsonencode(local.mta_sts_policy)};

    export default {
      async fetch(request) {
        const url = new URL(request.url);
        if (url.pathname === "/.well-known/mta-sts.txt") {
          return new Response(POLICY, {
            headers: {
              "content-type": "text/plain; charset=utf-8",
              "cache-control": "max-age=300",
            },
          });
        }
        return new Response("Not Found\n", { status: 404 });
      },
    };
  EOT
  main_module        = "worker.mjs"
  compatibility_date = "2024-01-01"
}

# Run scripts/cf-worker-routes-fail-open after creating or changing this route
# (see the FAIL-OPEN note in worker.tf).
resource "cloudflare_workers_route" "mta_sts" {
  zone_id = var.cloudflare_zone_id
  pattern = "mta-sts.viktorbarzin.me/*"
  script  = cloudflare_workers_script.mta_sts.script_name
}
