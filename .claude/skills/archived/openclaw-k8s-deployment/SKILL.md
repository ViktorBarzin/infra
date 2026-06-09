---
name: openclaw-k8s-deployment
description: |
  Deploy and troubleshoot OpenClaw gateway on Kubernetes. Use when:
  (1) OpenClaw gateway won't start or shows "Telegram configured, not enabled yet",
  (2) exec fails with "requires a paired node (none available)",
  (3) gateway shows "Config invalid" for exec.host or exec.security values,
  (4) OpenClaw can't write files (EACCES on workspace or home),
  (5) gateway takes 5+ minutes to start (CPU throttling by VPA/LimitRange),
  (6) 502 Bad Gateway from Traefik after pod restart,
  (7) setting up Telegram bot channel,
  (8) configuring modelrelay sidecar for free model routing.
  Covers all non-obvious deployment gotchas discovered through trial and error.
author: Claude Code
version: 1.0.0
date: 2026-03-01
---

# OpenClaw Kubernetes Deployment

## Problem
Deploying OpenClaw as a Kubernetes pod involves many non-obvious configuration
requirements. The gateway process, Telegram integration, exec permissions, and
file ownership all have specific constraints not documented together.

## Context / Trigger Conditions
- Deploying OpenClaw from `ghcr.io/openclaw/openclaw` container image
- Running in Kubernetes with NFS volumes, Traefik ingress, Goldilocks/VPA
- Want Telegram bot integration, tool execution, and persistent state

## Solution

### 1. Gateway Configuration (openclaw.json)

**Required fields that aren't obvious:**

```json
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "controlUi": {
      "dangerouslyDisableDeviceAuth": true,
      "dangerouslyAllowHostHeaderOriginFallback": true
    }
  },
  "wizard": {
    "lastRunAt": "2026-03-01T00:00:00.000Z",
    "lastRunVersion": "2026.2.26",
    "lastRunCommand": "configure",
    "lastRunMode": "local"
  }
}
```

- `gateway.mode = "local"` — **required** or gateway refuses to start
- `dangerouslyAllowHostHeaderOriginFallback = true` — required in v2026.2.26+
  for non-loopback Control UI (error: "non-loopback Control UI requires
  gateway.controlUi.allowedOrigins")
- `wizard` block — **required** for Telegram to start. Without it, gateway logs
  "Telegram configured, not enabled yet" on every startup. The wizard block
  signals that initial setup was completed.

### 2. Exec Configuration

Valid values for `tools.exec`:

| Field | Valid Values | Notes |
|-------|-------------|-------|
| `host` | `sandbox`, `gateway`, `node` | NOT "local" — that's invalid |
| `security` | `deny`, `allowlist`, `full` | NOT "off" — that's invalid |
| `ask` | `"off"` | Disables confirmation prompts |

- `host = "gateway"` — runs commands on the container host directly
- `host = "node"` — requires a "paired node" companion app (doesn't work in containers)
- `host = "sandbox"` — requires Docker-in-Docker
- `security = "full"` — most permissive valid option

### 3. Sandbox Mode

```json
{
  "agents": {
    "defaults": {
      "sandbox": { "mode": "off" },
      "workspace": "/workspace/infra"
    }
  }
}
```

- `sandbox.mode = "off"` disables Docker sandboxing
- `workspace` must be set explicitly — defaults to `~/.openclaw/workspace`

### 4. File Permissions

The init container runs as root but the main container runs as `node` (UID 1000).

**Must chown in init container:**
```sh
chown -R 1000:1000 /workspace/infra
chown -R 1000:1000 /openclaw-home
chmod 700 /openclaw-home
```

**Must create directories:**
```sh
mkdir -p /openclaw-home/agents/main/sessions \
         /openclaw-home/credentials \
         /openclaw-home/canvas \
         /openclaw-home/devices \
         /openclaw-home/cron
```

Without these: `EACCES: permission denied` errors for AGENTS.md, canvas,
cron/jobs.json, devices, and other runtime files.

### 5. Startup Command

```sh
node openclaw.mjs doctor --fix 2>/dev/null; exec node openclaw.mjs gateway --allow-unconfigured --bind lan
```

Run `doctor --fix` before the gateway to auto-enable Telegram and fix
config issues. Without this, Telegram stays "not enabled yet".

### 6. Resource Requirements

- **CPU limit: 2 cores minimum** — the Node.js gateway startup is CPU-intensive.
  With 150-300m CPU, startup takes 5+ minutes.
- **Memory limit: 2Gi minimum** — the gateway OOM-kills at 1Gi during startup
  (V8 heap exhaustion).
- **Goldilocks VPA will override these** — see "VPA Override" section below.

### 7. Readiness Probe

```hcl
readiness_probe {
  tcp_socket { port = 18789 }
  initial_delay_seconds = 30
  period_seconds        = 10
}
```

Do NOT use a startup probe — the gateway can take 2-3 minutes to start listening
and a startup probe will kill it. Use readiness-only to prevent 502s from Traefik
during startup without killing the container.

### 8. Telegram Integration

```json
{
  "channels": {
    "telegram": {
      "enabled": true,
      "botToken": "...",
      "dmPolicy": "allowlist",
      "allowFrom": ["tg:USER_ID"],
      "groupPolicy": "allowlist",
      "streamMode": "partial"
    }
  }
}
```

Telegram won't start without:
1. The `wizard` block in config (signals setup was run)
2. `doctor --fix` at startup (auto-enables the channel)
3. Both `groupPolicy` and `streamMode` fields

### 9. NFS Volume Strategy

| Volume | Purpose | Type |
|--------|---------|------|
| `/home/node/.openclaw` | Persistent state (SOUL.md, sessions, memory, telegram) | NFS |
| `/tools` | Cached binaries (kubectl, terraform, terragrunt, python libs) | NFS |
| `/workspace` | Infra repo clone | NFS |
| `/data` | General data | NFS |

Using NFS for tools cache reduces restart time from ~2.5min to ~38s by skipping
binary downloads and pip installs on subsequent starts.

### 10. ModelRelay Sidecar

Deploy as a sidecar container for automatic free model routing:

```hcl
container {
  name  = "modelrelay"
  image = "node:22-alpine"
  command = ["sh", "-c", "npm install -g modelrelay; exec modelrelay --port 7352"]
  env { name = "NVIDIA_API_KEY"; value = "..." }
  env { name = "OPENROUTER_API_KEY"; value = "..." }
}
```

Configure as provider: `baseUrl = "http://127.0.0.1:7352/v1"`, model `auto-fastest`.

## Verification
1. `kubectl logs -c openclaw` should show `[gateway] listening on ws://0.0.0.0:18789`
2. No "Telegram configured, not enabled yet" message
3. No `EACCES` permission errors
4. `kubectl exec ... -- cat /proc/net/tcp` shows listening sockets
5. Telegram bot responds to `/start`

## Notes
- ConfigMap changes require pod restart (init container copies config at start)
- ConfigMap taint+reinit sometimes needed when Terraform state gets out of sync
- Goldilocks VPA recreates itself from namespace labels — must delete VPA on
  every pod recreation if namespace has `goldilocks.fairwinds.com/vpa-update-mode`
- The `--allow-unconfigured` flag is needed for the gateway command
- v2026.2.26 introduced breaking change requiring `dangerouslyAllowHostHeaderOriginFallback`

## See also
- `openclaw-custom-model-provider` — basic model provider configuration
- `k8s-limitrange-oom-silent-kill` — LimitRange causing OOM (related but different)
