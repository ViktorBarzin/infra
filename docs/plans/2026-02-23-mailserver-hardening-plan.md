# Mail Server Lightweight Hardening Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Harden the mail server with spam filtering (Rspamd), DMARC enforcement, rate limiting, monitoring alerts, and hygiene cleanup.

**Status**: Completed. ForwardEmail references in this plan are historical — relay removed 2026-04-12. MX points directly to mail.viktorbarzin.me.

**Architecture:** All changes are to the existing docker-mailserver 15.0.0 deployment managed by Terraform. Rspamd replaces OpenDKIM for DKIM signing and adds spam filtering. DMARC moves from `none` to `quarantine` in Cloudflare DNS. Postfix gets rate-limiting parameters. Prometheus gets a mailserver-down alert. Roundcubemail debug logging is disabled and image pinned.

**Tech Stack:** Terraform/HCL, docker-mailserver, Rspamd, Cloudflare DNS, Prometheus

---

### Task 1: Enable Rspamd and disable OpenDKIM

**Files:**
- Modify: `stacks/platform/modules/mailserver/main.tf:39-62` (env ConfigMap)

**Step 1: Add Rspamd env vars to the ConfigMap**

In `stacks/platform/modules/mailserver/main.tf`, in the `kubernetes_config_map.mailserver_env_config` resource `data` block, add these entries and modify existing ones:

```hcl
  data = {
    DMS_DEBUG = "0"
    ENABLE_CLAMAV                          = "0"
    ENABLE_AMAVIS                          = "0"
    ENABLE_FAIL2BAN                        = "0"
    ENABLE_FETCHMAIL                       = "0"
    ENABLE_POSTGREY                        = "0"
    ENABLE_SASLAUTHD                       = "0"
    ENABLE_SPAMASSASSIN                    = "0"
    ENABLE_SRS                             = "1"
    ENABLE_RSPAMD                          = "1"
    ENABLE_OPENDKIM                        = "0"
    ENABLE_OPENDMARC                       = "0"
    RSPAMD_LEARN                           = "1"
    FETCHMAIL_POLL                         = "120"
    ONE_DIR                                = "1"
    OVERRIDE_HOSTNAME                      = "mail.viktorbarzin.me"
    POSTFIX_MESSAGE_SIZE_LIMIT             = 1024 * 1024 * 200 # 200 MB
    POSTFIX_REJECT_UNKNOWN_CLIENT_HOSTNAME = "1"
    DEFAULT_RELAY_HOST = "[smtp.eu.mailgun.org]:587"
    SPOOF_PROTECTION   = "1"
    SSL_TYPE           = "manual"
    SSL_CERT_PATH      = "/tmp/ssl/tls.crt"
    SSL_KEY_PATH       = "/tmp/ssl/tls.key"
  }
```

The key additions are: `ENABLE_RSPAMD = "1"`, `ENABLE_OPENDKIM = "0"`, `ENABLE_OPENDMARC = "0"`, `RSPAMD_LEARN = "1"`.

**Note:** The existing OpenDKIM volume mounts (KeyTable, SigningTable, TrustedHosts, opendkim keys) should stay mounted. docker-mailserver's Rspamd integration reads the DKIM key from the same path (`/tmp/docker-mailserver/opendkim/keys/`) to configure Rspamd's DKIM signing module automatically.

**Step 2: Commit**

```bash
git add stacks/platform/modules/mailserver/main.tf
git commit -m "[ci skip] mailserver: enable Rspamd, disable OpenDKIM"
```

---

### Task 2: Add Postfix rate limiting

**Files:**
- Modify: `stacks/platform/modules/mailserver/variables.tf:3-22` (postfix_cf variable)

**Step 1: Add rate limiting parameters to postfix_cf**

In `stacks/platform/modules/mailserver/variables.tf`, append these lines to the `postfix_cf` default value, before the `EOT`:

```
smtpd_client_connection_rate_limit = 10
smtpd_client_message_rate_limit = 30
anvil_rate_time_unit = 60s
```

The full `postfix_cf` variable should become:

```hcl
variable "postfix_cf" {
  default = <<EOT
#relayhost = [smtp.sendgrid.net]:587
relayhost = [smtp.eu.mailgun.org]:587
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl/passwd
smtp_sasl_security_options = noanonymous
smtp_sasl_tls_security_options = noanonymous
smtp_tls_security_level = encrypt
smtpd_tls_cert_file=/tmp/ssl/tls.crt
smtpd_tls_key_file=/tmp/ssl/tls.key
smtpd_use_tls=yes
header_size_limit = 4096000

# Debug mail tls
smtpd_tls_loglevel = 1

# Rate limiting (brute-force protection)
smtpd_client_connection_rate_limit = 10
smtpd_client_message_rate_limit = 30
anvil_rate_time_unit = 60s
EOT
}
```

**Step 2: Commit**

```bash
git add stacks/platform/modules/mailserver/variables.tf
git commit -m "[ci skip] mailserver: add Postfix rate limiting"
```

---

### Task 3: Update DMARC DNS record to quarantine

**Files:**
- Modify: `stacks/platform/modules/cloudflared/cloudflare.tf:132-138` (DMARC record)
- Modify: `terraform.tfvars:85` (bind zone DMARC record)

**Step 1: Update Cloudflare DMARC record**

In `stacks/platform/modules/cloudflared/cloudflare.tf`, change the `cloudflare_record.mail_dmarc` content from `p=none` to `p=quarantine` and `sp=none` to `sp=quarantine`:

```hcl
resource "cloudflare_record" "mail_dmarc" {
  content  = "\"v=DMARC1; p=quarantine; pct=100; fo=1; ri=3600; sp=quarantine; adkim=r; aspf=r; rua=mailto:e21c0ff8@dmarc.mailgun.org,mailto:adb84997@inbox.ondmarc.com; ruf=mailto:e21c0ff8@dmarc.mailgun.org,mailto:adb84997@inbox.ondmarc.com,mailto:postmaster@viktorbarzin.me;\""
  name     = "_dmarc.viktorbarzin.me"
  proxied  = false
  ttl      = 1
  type     = "TXT"
  priority = 1
  zone_id  = var.cloudflare_zone_id
}
```

**Step 2: Update bind zone DMARC record**

In `terraform.tfvars` line 85, update the DMARC record:

```
_dmarc IN TXT "v=DMARC1; p=quarantine; ruf=mailto:postmaster@viktorbarzin.me; adkim=r; aspf=r; pct=100; sp=quarantine"
```

**Step 3: Commit**

```bash
git add stacks/platform/modules/cloudflared/cloudflare.tf terraform.tfvars
git commit -m "[ci skip] mailserver: tighten DMARC policy to quarantine"
```

---

### Task 4: Enable Prometheus mailserver-down alert

**Files:**
- Modify: `stacks/platform/modules/monitoring/prometheus_chart_values.tpl:544-550`

**Step 1: Uncomment the mailserver alert**

In `stacks/platform/modules/monitoring/prometheus_chart_values.tpl`, replace lines 544-550:

From:
```yaml
          # - alert: Mail server has no replicas available
          #   expr: (kube_deployment_status_replicas_available{namespace="mailserver"} or on() vector(0)) < 1
          #   for: 10m
          #   labels:
          #     severity: page
          #   annotations:
          #     summary: Mail server has no available replicas. This means mail may not be received.
```

To:
```yaml
          - alert: Mail server has no replicas available
            expr: (kube_deployment_status_replicas_available{namespace="mailserver"} or on() vector(0)) < 1
            for: 5m
            labels:
              severity: page
            annotations:
              summary: Mail server has no available replicas. This means mail may not be received.
```

Note: reduced `for` from 10m to 5m and fixed indentation to match the surrounding YAML (10 spaces).

**Step 2: Commit**

```bash
git add stacks/platform/modules/monitoring/prometheus_chart_values.tpl
git commit -m "[ci skip] monitoring: enable mailserver-down Prometheus alert"
```

---

### Task 5: Pin Roundcubemail image and disable debug logging

**Files:**
- Modify: `stacks/platform/modules/mailserver/roundcubemail.tf:60,113-119`

**Step 1: Pin the image tag**

In `stacks/platform/modules/mailserver/roundcubemail.tf` line 60, change:

```hcl
          image = "roundcube/roundcubemail:latest"
```

To:

```hcl
          image = "roundcube/roundcubemail:1.6-apache"
```

**Step 2: Disable debug logging**

In the same file, change the debug env vars:

```hcl
          env {
            name  = "ROUNDCUBEMAIL_SMTP_DEBUG"
            value = "false"
          }
          env {
            name  = "ROUNDCUBEMAIL_DEBUG_LEVEL"
            value = "1"
          }
```

**Step 3: Commit**

```bash
git add stacks/platform/modules/mailserver/roundcubemail.tf
git commit -m "[ci skip] roundcubemail: pin to 1.6-apache, disable debug logging"
```

---

### Task 6: Clean up stale SendGrid DNS records

**Files:**
- Modify: `terraform.tfvars:88-90`

**Step 1: Remove SendGrid CNAME records from bind zone**

In `terraform.tfvars`, remove lines 88-90:

```
em7107 IN CNAME u31127144.wl145.sendgrid.net.
s1._domainkey IN CNAME s1.domainkey.u31127144.wl145.sendgrid.net.
s2._domainkey IN CNAME s2.domainkey.u31127144.wl145.sendgrid.net.
```

These are stale remnants from a previous SendGrid relay setup. They are not in the Cloudflare terraform config, so they may also need manual removal from Cloudflare if they were created outside Terraform.

**Step 2: Commit**

```bash
git add terraform.tfvars
git commit -m "[ci skip] dns: remove stale SendGrid CNAME records"
```

---

### Task 7: Apply changes

**Step 1: Apply the platform stack**

```bash
cd stacks/platform && terragrunt apply --non-interactive
```

This deploys: Rspamd enablement, Postfix rate limiting, DMARC DNS update, Prometheus alert, Roundcubemail changes.

**Step 2: Verify the mailserver pod restarts with Rspamd**

```bash
kubectl --kubeconfig $(pwd)/config get pods -n mailserver
```

Wait for the pod to be Running. Then verify Rspamd is active:

```bash
kubectl --kubeconfig $(pwd)/config exec -n mailserver deploy/mailserver -c docker-mailserver -- pgrep -a rspamd
```

Should show rspamd processes running.

**Step 3: Verify Postfix rate limiting is applied**

```bash
kubectl --kubeconfig $(pwd)/config exec -n mailserver deploy/mailserver -c docker-mailserver -- postconf smtpd_client_connection_rate_limit
```

Expected: `smtpd_client_connection_rate_limit = 10`

**Step 4: Verify DKIM signing still works with Rspamd**

Send a test email and check DKIM signature in the headers, or check Rspamd logs:

```bash
kubectl --kubeconfig $(pwd)/config logs -n mailserver deploy/mailserver -c docker-mailserver --tail=50 | grep -i dkim
```

**Step 5: Verify Roundcubemail is running with pinned image**

```bash
kubectl --kubeconfig $(pwd)/config get deploy -n mailserver roundcubemail -o jsonpath='{.spec.template.spec.containers[0].image}'
```

Expected: `roundcube/roundcubemail:1.6-apache`

**Step 6: Verify Prometheus alert is active**

Check in Grafana/Prometheus UI that the "Mail server has no replicas available" alert rule exists and is in `inactive` state (meaning the mailserver is healthy).
