# Claude Code — Project Configuration

> **Shared knowledge**: Read `AGENTS.md` at repo root for architecture, patterns, rules, and operations. This file adds Claude-specific features on top.

## Claude-Specific Resources
- **Skills**: `.claude/skills/` (7 active). Archived runbooks: `.claude/skills/archived/`
- **Agents**: `.claude/agents/cluster-health-checker` (haiku, autonomous health checks)
- **Reference**: `.claude/reference/` — patterns.md, service-catalog.md, proxmox-inventory.md, github-api.md, authentik-state.md
- **GitHub API**: `curl` with tokens from tfvars (`gh` CLI blocked by sandbox)
- **CI/CD**: Woodpecker CI — pushes to master auto-apply platform stack

## Instructions
- **"remember X"**: Update this file + `AGENTS.md` (if it's shared knowledge), commit with `[ci skip]`
- **New services need CI/CD** (Woodpecker) and **monitoring** (Prometheus/Uptime Kuma)
- **New service**: Use `setup-project` skill for full workflow
- **Ingress**: `ingress_factory` module. Auth: `protected = true`. Anti-AI: on by default.

## User Preferences
- **Calendar**: Nextcloud at `nextcloud.viktorbarzin.me`
- **Home Assistant**: ha-london (default), ha-sofia. "ha"/"HA" = ha-london
- **Frontend**: Svelte for all new web apps
- **Tools**: Docker containers only — never `brew install` locally
- **Pod monitoring**: Never use `sleep` — spawn background subagent with `kubectl get pods -w`
