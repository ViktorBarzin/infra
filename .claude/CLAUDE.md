# Claude Code — Project Configuration

> **Shared knowledge**: Read `AGENTS.md` at repo root for architecture, patterns, rules, and operations. This file adds Claude-specific features on top.

## Claude-Specific Resources
- **Skills**: `.claude/skills/` (7 active). Archived runbooks: `.claude/skills/archived/`
- **Agents**: `.claude/agents/cluster-health-checker` (haiku, autonomous health checks)
- **Reference**: `.claude/reference/` — patterns.md, service-catalog.md, proxmox-inventory.md, github-api.md, authentik-state.md
- **GitHub API**: `curl` with tokens from tfvars (`gh` CLI blocked by sandbox)

## Instructions
- **"remember X"**: Update this file + `AGENTS.md` (if shared knowledge), commit with `[ci skip]`
- **Apply with SOPS**: Use `scripts/tg` wrapper instead of raw `terragrunt` — auto-decrypts secrets
- **New services need CI/CD** (Woodpecker) and **monitoring** (Prometheus/Uptime Kuma)
- **New service**: Use `setup-project` skill for full workflow
- **Ingress**: `ingress_factory` module. Auth: `protected = true`. Anti-AI: on by default.
- **Docker images**: Always build for `linux/amd64` (`docker buildx build --platform linux/amd64`). Pull-through cache serves stale :latest — use versioned tags.

## User Preferences
- **Calendar**: Nextcloud at `nextcloud.viktorbarzin.me`
- **Home Assistant**: ha-london (default), ha-sofia. "ha"/"HA" = ha-london
- **Frontend**: Svelte for all new web apps
- **Tools**: Docker containers only — never `brew install` locally
- **Pod monitoring**: Never use `sleep` — spawn background subagent with `kubectl get pods -w`
