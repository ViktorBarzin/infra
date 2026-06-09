# Mail Server Lightweight Hardening Design

**Date**: 2026-02-23
**Scope**: Security, reliability, and hygiene improvements to the docker-mailserver stack
**Status**: Completed. ForwardEmail relay removed 2026-04-12 — MX now direct to mail.viktorbarzin.me on dedicated MetalLB IP with CrowdSec protection.

## Current State

- docker-mailserver 15.0.0 on K8s (single replica, Recreate strategy)
- Roundcubemail webmail (MySQL-backed, debug logging on, unpinned :latest tag)
- Outbound relay via Mailgun, inbound MX via ForwardEmail
- OpenDKIM for DKIM signing, no spam filtering (SpamAssassin/ClamAV/Amavis disabled)
- DMARC policy `none` (monitoring only)
- No brute-force protection, no mailserver-down alert
- Dovecot exporter sidecar (unpinned), stale SendGrid DNS records

## Changes

### 1. Enable Rspamd (replace OpenDKIM as DKIM signer)

Add to `mailserver_env_config`:
- `ENABLE_RSPAMD = "1"` (spam filtering, DKIM verification, phishing detection, Oletools)
- `ENABLE_OPENDKIM = "0"` (Rspamd handles DKIM signing natively)
- `RSPAMD_LEARN = "1"` (learn from Junk folder movements)

Existing OpenDKIM key mounts stay — Rspamd reads them from the same paths.
Resource impact: ~150-200MB additional RAM.

### 2. DMARC DNS enforcement

Update `_dmarc` TXT record: `p=none` -> `p=quarantine`. Can tighten to `p=reject` after validation.

### 3. Postfix rate limiting

Add to `postfix_cf`:
```
smtpd_client_connection_rate_limit = 10
smtpd_client_message_rate_limit = 30
anvil_rate_time_unit = 60s
```

Service already uses `externalTrafficPolicy: Local`, so real client IPs are visible to Postfix.
ForwardEmail IPs on port 25 are subject to same limits but 10 conn/min is generous.

### 4. Prometheus alert

Uncomment the existing mailserver-down alert in `prometheus_chart_values.tpl`.

### 5. Roundcubemail cleanup

- Pin image: `roundcube/roundcubemail:latest` -> `roundcube/roundcubemail:1.6-apache`
- Disable debug: `ROUNDCUBEMAIL_SMTP_DEBUG = "false"`, `ROUNDCUBEMAIL_DEBUG_LEVEL = "1"`

### 6. SendGrid DNS cleanup

Remove stale CNAME records: `em7107`, `s1._domainkey`, `s2._domainkey`.

## Not Changing

- Roundcubemail stays (user preference)
- ForwardEmail/Mailgun relay stays (practical dependency)
- ClamAV stays disabled (Rspamd Oletools covers malicious attachments)
- Single replica (HA email requires significant additional complexity)
