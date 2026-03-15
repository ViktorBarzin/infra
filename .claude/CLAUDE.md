# Claude Code — Project Configuration

> **Shared knowledge**: Read `AGENTS.md` at repo root for architecture, patterns, rules, and operations. This file adds Claude-specific features on top.

## Claude-Specific Resources
- **Skills**: `.claude/skills/` (7 active). Archived runbooks: `.claude/skills/archived/`
- **Agents**: `.claude/agents/cluster-health-checker` (haiku, autonomous health checks)
- **Reference**: `.claude/reference/` — patterns.md, service-catalog.md, proxmox-inventory.md, github-api.md, authentik-state.md
- **GitHub API**: `curl` with tokens from tfvars (`gh` CLI blocked by sandbox)

## Instructions
- **"remember X"**: Use `memory-tool store "content" --category facts --tags "tag1,tag2"` (via exec) for persistent cross-session memory. Also update this file + `AGENTS.md` (if shared knowledge), commit with `[ci skip]`. To recall: `memory-tool recall "query"`. To list: `memory-tool list`. To delete: `memory-tool delete <id>`. The native `memory_search` and `memory_get` tools are also available for searching indexed memory files. For **storing** new memories, always use the `memory-tool` CLI via exec.
- **Apply with SOPS**: Use `scripts/tg` wrapper instead of raw `terragrunt` — auto-decrypts secrets
- **New services need CI/CD** (Woodpecker) and **monitoring** (Prometheus/Uptime Kuma)
- **New service**: Use `setup-project` skill for full workflow
- **Ingress**: `ingress_factory` module. Auth: `protected = true`. Anti-AI: on by default.
- **Docker images**: Always build for `linux/amd64` (`docker buildx build --platform linux/amd64`). Pull-through cache serves stale :latest — use versioned tags.
- **LinuxServer.io containers**: `DOCKER_MODS` runs apt-get on every start — bake slow mods into a custom image (`RUN /docker-mods || true` then `ENV DOCKER_MODS=`). Set `NO_CHOWN=true` to skip recursive chown that hangs on NFS mounts.
- **Node memory changes**: When changing VM memory on any k8s node, update kubelet `systemReserved`, `kubeReserved`, and eviction thresholds accordingly. Config: `/var/lib/kubelet/config.yaml`. Template: `stacks/infra/main.tf`. Current values: systemReserved=512Mi, kubeReserved=512Mi, evictionHard=500Mi, evictionSoft=1Gi.
- **Sealed Secrets**: User-managed secrets go in `sealed-*.yaml` files in the stack directory. Stacks pick them up via `kubernetes_manifest` + `fileset(path.module, "sealed-*.yaml")`. See AGENTS.md for full workflow.

## Secrets Management — Vault KV
- **All secrets migrated from SOPS to Vault KV v2** (2026-03-15). 43 stacks read from `data "vault_kv_secret_v2" "secrets"` at `secret/<stack-name>`.
- **Vault stack** (`stacks/vault/main.tf`) is the bridge: reads secrets from SOPS `-var-file`, writes them to Vault KV via 43 `vault_kv_secret_v2` resources.
- **Bootstrap secrets stay in SOPS permanently**: `vault_root_token`, `vault_authentik_client_id`, `vault_authentik_client_secret`.
- **Platform cannot depend on vault** (circular — vault depends on platform). Apply order: vault first, then platform.
- **Complex types** (maps/lists like `homepage_credentials`, `k8s_users`) stored as JSON strings in KV, decoded with `jsondecode()` in consuming stack `locals` blocks.
- **New stacks**: Add a `vault_kv_secret_v2` resource in vault/main.tf, then use `data "vault_kv_secret_v2" "secrets"` + `dependency "vault"` in the new stack.

## Resource Management Patterns
- **CPU**: All CPU limits removed cluster-wide (CFS throttling). Only set CPU requests based on actual usage.
- **Memory**: Set explicit `requests=limits` based on Prometheus 7-day max. Overcommit ratio ~2x max.
- **VPA (Goldilocks)**: Must be `Initial` mode (not `Auto`) — Auto conflicts with Terraform's declarative resource management.
- **LimitRange**: Tier-based defaults silently apply to pods with `resources: {}`. Always set explicit resources on containers needing more than 256Mi (edge/aux default).
- **Pin database versions**: Disable Diun (image update monitoring) for MySQL, PostgreSQL, Redis.

## Networking & Resilience
- **Critical path services scaled to 3**: Traefik, Authentik, CrowdSec LAPI, PgBouncer, Cloudflared.
- **PDBs**: minAvailable=2 on Traefik and Authentik.
- **Fallback proxies**: basicAuth when Authentik is down, fail-open when poison-fountain is down.
- **CrowdSec bouncer**: graceful degradation mode (fail-open on error).
- **Rate limiting**: Return 429 (not 503). Per-service tuning: Immich/Nextcloud need higher limits.
- **Retry middleware**: 2 attempts, 100ms — in default ingress chain.
- **HTTP/3 (QUIC)**: Enabled cluster-wide via Traefik.

## Service-Specific Notes
| Service | Key Operational Knowledge |
|---------|--------------------------|
| Nextcloud | MaxRequestWorkers=150, needs 4Gi memory, very generous startup probe |
| Immich | ML on SSD, disable ModSecurity (breaks streaming), CUDA for ML, frequent upgrades |
| CrowdSec | Pin version, disable Metabase when not needed (CPU hog), LAPI scaled to 3 |
| Frigate | GPU stall detection in liveness probe (inference speed check), high CPU |
| Authentik | 3 replicas, PgBouncer in front of PostgreSQL, strip auth headers before forwarding |
| Kyverno | failurePolicy=Ignore to prevent blocking cluster, pin chart version |
| MySQL InnoDB | Enable auto-recovery, anti-affinity excludes node2 (SIGBUS), 4.4Gi req but ~1Gi used |

## Monitoring & Alerting
- Alert cascade inhibitions: if node is down, suppress pod alerts on that node.
- Exclude completed CronJob pods from "pod not ready" alerts.
- Every new service gets Prometheus scrape config + Uptime Kuma monitor.
- Key alerts: OOMKill, pod replica mismatch, 4xx/5xx error rates, UPS battery, CPU temp, SSD writes, NFS responsiveness.

## Known Issues
- **CrowdSec Helm upgrade times out**: `terragrunt apply` on platform stack causes CrowdSec Helm release to get stuck in `pending-upgrade`. Workaround: `helm rollback crowdsec <rev> -n crowdsec`. Root cause: likely ResourceQuota CPU at 302% preventing pods from passing readiness probes. Needs investigation.
- **OpenClaw config is writable**: OpenClaw writes to `openclaw.json` at runtime (doctor --fix, plugin auto-enable). Never use subPath ConfigMap mounts for it — use an init container to copy into a writable volume. Needs 2Gi memory + `NODE_OPTIONS=--max-old-space-size=1536`.
- **Goldilocks VPA sets limits**: When increasing memory requests, always set explicit `limits` too — Goldilocks may have added a limit that blocks the change.

## User Preferences
- **Calendar**: Nextcloud at `nextcloud.viktorbarzin.me`
- **Home Assistant**: ha-london (default), ha-sofia. "ha"/"HA" = ha-london
- **Frontend**: Svelte for all new web apps
- **Tools**: Docker containers only — never `brew install` locally
- **Pod monitoring**: Never use `sleep` — spawn background subagent with `kubectl get pods -w`
