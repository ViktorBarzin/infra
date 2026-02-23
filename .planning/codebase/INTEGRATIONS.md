# External Integrations

**Analysis Date:** 2026-02-23

## APIs & External Services

**Cloudflare:**
- DNS management (public domain `viktorbarzin.me`)
- Tunnel for public HTTPS access
- Account ID: `cloudflare_account_id` in tfvars
- SDK/Client: `cloudflare/cloudflare` Terraform provider v4.52.5
- Auth: API token stored in `cloudflare_api_key`, email in `cloudflare_email`, zone ID in `cloudflare_zone_id`, tunnel ID in `cloudflare_tunnel_id`
- Implementation: `stacks/platform/modules/cloudflared/` deploys Cloudflare tunnel daemon

**GitHub:**
- Git repository hosting and CI/CD webhook source
- Webhook endpoint: `https://webhook.viktorbarzin.me/` (handled by `stacks/webhook_handler/`)
- Auth: Git token in `webhook_handler_git_token` (terraform.tfvars)
- User: `webhook_handler_git_user` (terraform.tfvars)
- SSH key: `webhook_handler_ssh_key` for Git operations (secret in K8s)

**Facebook Messenger:**
- Chatbot integration via webhook
- Webhook endpoint: `https://webhook.viktorbarzin.me/` (receives webhook_handler_fb_*)
- Auth tokens: `webhook_handler_fb_verify_token`, `webhook_handler_fb_page_token`, `webhook_handler_fb_app_secret` (all in tfvars)

**Slack:**
- Alert routing and notifications
- Webhook URL: `alertmanager_slack_api_url` (terraform.tfvars)
- Integration: Alertmanager alerts from `stacks/platform/modules/monitoring/` sent to Slack
- CrowdSec integration: Security events to Slack via `stacks/platform/modules/crowdsec/`

**Hetrix Tools:**
- Uptime monitoring service
- Status page redirects: `https://hetrixtools.com/r/38981b548b5d38b052aca8d01285a3f3/` and `https://hetrixtools.com/r/2ba9d7a5e017794db0fd91f0115a8b3b/`
- Implementation: Traefik middleware redirect in `stacks/platform/modules/monitoring/main.tf`

**Tiny Tuya:**
- Smart device control via tuya-bridge
- Auth: `tiny_tuya_service_secret` (terraform.tfvars)

**Mailgun:**
- SMTP relay for outgoing mail (primary relay host)
- Relay: `[smtp.eu.mailgun.org]:587` (Postfix DEFAULT_RELAY_HOST)
- Auth: SASL credentials in `sasl_passwd` (mailserver config)
- Alternative: SendGrid (commented out, previously used)

**Home Assistant:**
- Home automation integration
- API token: `haos_api_token` (terraform.tfvars)
- Access: `https://ha-london.viktorbarzin.me`, `https://ha-sofia.viktorbarzin.me`

**Proxmox:**
- Virtualization platform for VM provisioning
- Host: `192.168.1.127:8006` (`proxmox_pm_api_url`)
- Auth: API token ID `terraform-prov@pve!terrform-prov`, secret in tfvars
- Provider: `telmate/proxmox` v3.0.2-rc07
- Access: IDRAC credentials for physical server monitoring (`idrac_host`, `idrac_username`, `idrac_password`)

## Data Storage

**Databases:**
- MySQL 9.2.0
  - Connection: `mysql.dbaas.svc.cluster.local:3306` (K8s internal)
  - Client: Direct port access (no ORM in core infrastructure)
  - Root password: `dbaas_root_password` (tfvars)
  - Storage: NFS PV at `/mnt/main/mysql`

- PostgreSQL 16.4-bullseye (with PostGIS + PGVector)
  - Connection: `postgresql.dbaas:5432` (K8s internal)
  - Connection via PgBouncer: `pgbouncer.authentik:6432` (Authentik only)
  - Root password: `dbaas_postgresql_root_password` (tfvars)
  - Root password for pgbouncer: `pgbouncer_root_password` (tfvars)
  - Admin UI: PgAdmin at `pma.viktorbarzin.me`
  - PgAdmin password: `dbaas_pgadmin_password` (tfvars)
  - Storage: NFS PV at `/mnt/main/postgresql`

**File Storage:**
- NFS (Primary)
  - Host: `10.0.10.15` (TrueNAS)
  - Mount path: `/mnt/main/`
  - Subdirectories: per-service (e.g., `/mnt/main/immich/`, `/mnt/main/affine/`, `/mnt/main/mailserver/`, etc.)
  - Configuration: `secrets/nfs_directories.txt` (git-crypt encrypted)
  - Export script: `secrets/nfs_exports.sh` (updates TrueNAS exports)

**Caching:**
- Redis/redis-stack:latest
  - Connection: `redis.redis.svc.cluster.local` (K8s internal, no explicit port in code)
  - Databases: DB 2 (Gramps Web broker), DB 3 (Gramps Web rate limiting)
  - Storage: Persistent volume for data durability
  - Implementation: `stacks/platform/modules/redis/main.tf`

## Authentication & Identity

**Auth Provider:**
- Authentik (self-hosted OIDC/OAuth2 identity provider)
  - URL: `https://authentik.viktorbarzin.me`
  - API: `/api/v3/` endpoint
  - Token: `authentik_api_token` (terraform.tfvars)
  - Database: PostgreSQL via `postgresql.dbaas:5432` (also PgBouncer at `pgbouncer.authentik:6432`)
  - Secret key: `authentik_secret_key` (terraform.tfvars)
  - Postgres password: `authentik_postgres_password` (terraform.tfvars)
  - K8s OIDC: Issuer `https://authentik.viktorbarzin.me/application/o/kubernetes/`, client `kubernetes` (public)
  - Implementation: `stacks/platform/modules/authentik/main.tf` + Helm chart
  - Traefik integration: Forward auth via protected = true in ingress_factory

**RBAC:**
- Kubernetes API auth via Authentik OIDC
- SSH keys: `ssh_private_key` (terraform.tfvars)
- Implementation: `stacks/platform/modules/rbac/` + `stacks/platform/modules/k8s-portal/`

## Monitoring & Observability

**Error Tracking:**
- None detected - alerts routed to Slack instead

**Metrics:**
- Prometheus - Time series database
  - Scrape endpoints: cluster nodes, services, Proxmox IDRAC, Tuya devices, Home Assistant
  - Implementation: `stacks/platform/modules/monitoring/`
  - Health check: CronJob monitors prometheus-server pod and alerts to `https://webhook.viktorbarzin.me/fb/message-viktor` if down

**Logs:**
- Loki 3.6.5 (single binary) + Alloy v1.13.0 (DaemonSet collector)
  - Retention: 7 days
  - Storage: NFS PV at `/mnt/main/loki/loki` (15Gi), WAL on tmpfs (2Gi)
  - Alerting: HighErrorRate, PodCrashLoopBackOff, OOMKilled (ConfigMap `loki-alert-rules`)

**Visualization:**
- Grafana
  - Database: PostgreSQL via dbaas
  - Admin password: `grafana_admin_password` (tfvars)
  - DB password: `grafana_db_password` (tfvars)

**Status Pages:**
- Hetrix Tools (external uptime monitoring)
- Uptime Kuma (self-hosted, `stacks/platform/modules/uptime-kuma/`)

## CI/CD & Deployment

**Hosting:**
- Proxmox 8.x (hypervisor)
- Kubernetes 1.34.2 (application platform)
- Cloudflare Tunnel (public ingress)

**CI Pipeline:**
- Woodpecker CI (self-hosted, `stacks/woodpecker/`)
  - Hosted at: `https://ci.viktorbarzin.me`
  - Config: `.woodpecker/` in repo root
  - Triggers: Git push, scheduled jobs
  - Applies platform stack automatically on merge to master

**GitOps:**
- Webhook-handler service: receives GitHub webhooks, triggers deployments
  - Endpoint: `https://webhook.viktorbarzin.me/`
  - Auth: Secret token `webhook_handler_secret` (tfvars)
  - Can update K8s deployments via RBAC
  - Implementation: `stacks/webhook_handler/main.tf`, image `viktorbarzin/webhook-handler:latest`

## Environment Configuration

**Required env vars (terraform.tfvars - git-crypt encrypted):**
- `cloudflare_api_key`, `cloudflare_email`, `cloudflare_zone_id`, `cloudflare_tunnel_id`, `cloudflare_tunnel_token`
- `dbaas_root_password`, `dbaas_postgresql_root_password`, `dbaas_pgadmin_password`
- `authentik_secret_key`, `authentik_postgres_password`, `authentik_api_token`
- `proxmox_pm_api_url`, `proxmox_pm_api_token_id`, `proxmox_pm_api_token_secret`
- `alertmanager_slack_api_url`, `alertmanager_account_password`
- `webhook_handler_secret`, `webhook_handler_fb_verify_token`, `webhook_handler_fb_page_token`, `webhook_handler_fb_app_secret`, `webhook_handler_git_token`, `webhook_handler_git_user`, `webhook_handler_ssh_key`
- `vaultwarden_smtp_password`, `mailserver_accounts`, `postfix_account_aliases`, `sasl_passwd`
- `crowdsec_enroll_key`, `crowdsec_db_password`, `crowdsec_dash_api_key`, `crowdsec_dash_machine_id`, `crowdsec_dash_machine_password`
- `headscale_config`, `headscale_acl`
- `monitoring_idrac_username`, `monitoring_idrac_password`, `tiny_tuya_service_secret`, `haos_api_token`, `pve_password`, `grafana_admin_password`, `grafana_db_password`
- `k8s_users` (map of SSH keys for K8s RBAC)

**Secrets location:**
- Primary: `terraform.tfvars` (git-crypt encrypted at rest, decrypted during `terragrunt apply`)
- K8s Secrets: Created by Terraform from tfvars into namespaces (see `stacks/platform/modules/*/main.tf`)
- TLS certificates: `secrets/` directory (symlinked into stacks as `secrets/` → `../../secrets`)

## Webhooks & Callbacks

**Incoming (Webhook endpoints):**
- GitHub webhooks: `https://webhook.viktorbarzin.me/` (deployment triggers)
- Facebook Messenger webhooks: `https://webhook.viktorbarzin.me/` (chatbot messages)
- Health alerts: CronJob sends to `https://webhook.viktorbarzin.me/fb/message-viktor` if Prometheus is down

**Outgoing:**
- Alertmanager → Slack webhook: `alertmanager_slack_api_url`
- CrowdSec → Slack webhook: same as alertmanager
- Hetrix Tools status pages: redirect middleware instead of direct integration

## Integration Patterns

**Terraform Secrets Injection:**
- Template pattern: `templatefile("${path.module}/values.yaml", { var1 = var.value1, ... })`
- Direct env injection: K8s ConfigMap/Secret created from tfvars variables
- Example: `stacks/platform/modules/crowdsec/main.tf` renders Helm values with interpolated secrets

**Internal Service Discovery:**
- DNS: Services accessible via `<name>.<namespace>.svc.cluster.local`
- Examples: `mysql.dbaas.svc.cluster.local`, `redis.redis.svc.cluster.local`, `postgresql.dbaas.svc.cluster.local`

**External Service Access:**
- Cloudflare Tunnel: Provides public HTTPS for services (no direct internet access needed)
- Traefik Ingress: Routes external traffic to internal K8s services
- Technitium (internal DNS) for `.lan` domain resolution

---

*Integration audit: 2026-02-23*
