# Agent Task Tracking

## Overview

All Claude Code sessions share a centralized task database powered by [Beads](https://github.com/steveyegge/beads) (`bd` CLI) backed by a Dolt SQL server running in the Kubernetes cluster. This prevents agents from duplicating work across sessions and provides persistent cross-session task tracking.

## Architecture

```
                     ┌─────────────────────────┐
                     │  Dolt SQL Server (k8s)   │
                     │  beads-server namespace   │
                     │  10.0.20.200:3306         │
                     │  proxmox-lvm PVC (2Gi)    │
                     └────────┬──────────────────┘
                              │ MySQL protocol
               ┌──────────────┼──────────────────┐
               │              │                   │
    ┌──────────▼──┐  ┌───────▼────────┐  ┌──────▼──────────┐
    │ wizard      │  │ emo            │  │ future agents   │
    │ session 1   │  │ session 1      │  │ (any machine    │
    │ session 2   │  │ session 2      │  │  with network   │
    │ session N   │  │                │  │  access)        │
    └─────────────┘  └────────────────┘  └─────────────────┘
```

### Components

| Component | Location | Purpose |
|-----------|----------|---------|
| Dolt server | `beads-server` namespace, `10.0.20.200:3306` | Centralized MySQL-compatible database |
| Root `.beads/` | `/home/wizard/code/.beads/` | Client config (server mode, prefix `code`) |
| Task context hook | `/home/wizard/.claude/hooks/beads-task-context.sh` | Injects in-progress tasks into every prompt |
| Task blocker hook | `/home/wizard/.claude/hooks/beads-block-builtin-tasks.py` | Blocks TaskCreate/TodoWrite, redirects to `bd` |
| Project settings | `/home/wizard/code/.claude/settings.json` | Shared hooks (inherited by all users) |
| Terraform stack | `stacks/beads-server/` | Deployment, Service (MetalLB LB), PVC |

### Settings Hierarchy

```
Project-level (.claude/settings.json)     ← Shared: beads hooks + TaskCreate blocker
  └─ User-level (~/.claude/settings.json) ← Per-user: memory plugin, model, statusline
```

Both `wizard` and `emo` inherit project-level settings automatically. User-specific hooks (e.g., wizard's memory plugin) stay in the user-level settings.

## Agent Session Lifecycle

### 1. Session Start (automatic)

The `UserPromptSubmit` hook fires on every prompt:
- Queries `bd list --status in_progress` from the centralized DB
- Queries `bd list --status open | head -10` for available work
- Injects results into the agent's context as `additionalContext`

The agent sees what's currently being worked on before processing any request.

### 2. Before Starting Work

```bash
bd list --status in_progress    # What others are working on
bd ready                        # Unblocked tasks available
bd create "Task description"    # Register your work
bd update <id> --claim          # Set status to in_progress
```

### 3. During Work

```bash
bd note <id> "progress update"  # Log progress
bd link <child> <parent>        # Add dependencies
```

### 4. After Completing Work

```bash
bd close <id>                   # Mark complete
bd create "Follow-up task"      # File remaining work for next session
```

### 5. Enforcement

Two layers prevent agents from using built-in task tools:

1. **CLAUDE.md instruction** (soft): "Do NOT use TaskCreate, TaskUpdate, TodoWrite"
2. **PermissionRequest hook** (hard): Blocks the tool call with a deny decision and redirect message

## Infrastructure

### Dolt Server

- **Image**: `dolthub/dolt-sql-server:latest`
- **Storage**: `proxmox-lvm` PVC, 2Gi initial, auto-resize to 10Gi
- **Service**: LoadBalancer via MetalLB on shared IP `10.0.20.200`
  - `metallb.io/allow-shared-ip: shared`
  - `externalTrafficPolicy: Cluster`
- **Port**: 3306 (MySQL protocol)
- **Users**: `root@%` and `beads@%` (no password, internal network)
- **Init**: `/docker-entrypoint-initdb.d/` via ConfigMap, `DOLT_ROOT_HOST=%`
- **Terraform**: `stacks/beads-server/main.tf`

### Client Configuration

The root `.beads/metadata.json`:
```json
{
  "backend": "dolt",
  "dolt_mode": "server",
  "dolt_server_host": "10.0.20.200",
  "dolt_server_port": 3306,
  "dolt_server_user": "beads",
  "dolt_database": "code"
}
```

### Multi-User Access

- Directory permissions: `2770 wizard:code-shared` (setgid)
- Both `wizard` and `emo` are in the `code-shared` group
- `bd` binary: `/home/wizard/.local/bin/bd` (symlinked for emo at `/home/emo/.local/bin/bd`)

## Known Issues

### Subdirectory Shadow

Per-project `.beads/` directories exist in 7 subdirectories (finance, infra, Website, etc.). When an agent `cd`s into one of these, `bd` auto-discovers the **local** `.beads/` instead of the centralized one.

**Fix**: Always use `bd --db /home/wizard/code/.beads` when working from a subdirectory. The hook and CLAUDE.md instructions document this.

### Hook Network Failure

The task context hook suppresses errors (`2>/dev/null`). If the Dolt server is unreachable, the hook silently exits without injecting context. Agents won't see current tasks but won't be blocked either.

### Permissions Warning

`bd` warns about `.beads` directory permissions (`0770 vs recommended 0700`). This is expected — we use `0770` for group access. The warning is harmless.

## Verification

Run the E2E test:
```bash
bash /home/wizard/code/test-beads-e2e.sh
```

This tests all 11 phases: hook injection, task CRUD, cross-user visibility, subdirectory shadowing, and multi-agent coordination. Expects 11/11 PASS.

## Related

- `CLAUDE.md` (root) — Mandatory task protocol section
- Per-project `CLAUDE.md` files — Beads integration block
- `stacks/beads-server/main.tf` — Terraform deployment
