# OpenClaw devvm access + async task pattern — design

**Date:** 2026-05-22
**Stack:** `infra/stacks/openclaw`
**Status:** Approved (in-session, see chat history 2026-05-22)

## Goal

Give the OpenClaw pod (running in K8s) two new capabilities:

1. **Host-tools bundle** — common Linux CLIs the upstream OpenClaw image
   doesn't ship (`ssh`, `scp`, `vault`, `dig`, `jq`, `yq`, `ripgrep`, `fd`,
   `gnupg`, `tmux`, etc.). OpenClaw can't `apt install` because the
   container runs as non-root `node` (uid 1000).
2. **devvm async task pattern** — OpenClaw spawns long-running work as
   `tmux` sessions on devvm, sends prompts via `tmux send-keys`, captures
   progress via `tmux capture-pane`. Sessions live on devvm, so they
   survive OpenClaw pod restarts.

OpenClaw uses this combination as a **trusted fallback** for tasks too
expensive, sensitive, or stateful for in-pod execution: Vault lookups,
multi-step `claude-code` work, anything needing wizard's full home-lab
access.

## Why now

- The in-pod sandbox is `security=full` but the container is minimal —
  no `ssh`, no `vault`, no `dig`, no `tmux`.
- The user wants OpenClaw to be a first-line agent that delegates heavy
  work to the dev VM rather than duplicate that work in a constrained pod.
- Long-running work (multi-minute `claude-code` sessions) shouldn't be
  tied to a single synchronous `claude -p` invocation — needs persistence
  and pollability.

## Architecture decision: stay on K8s

Discussed migrating OpenClaw to run directly on devvm (would obviate the
host-tools bundle + most of the SSH setup). Decision: **stay on K8s**.

Reasons:
- Keeps HA (5-node cluster vs single devvm reboot)
- Keeps ingress/Authentik/Telegram entry chain intact
- Keeps Prometheus scrape + exporter sidecar
- Keeps PVC backup pipeline (LVM snapshots + Synology offsite)
- Resource isolation — a runaway LLM session can't stress wizard's daily-driver VM
- Migration cost is several days; this design is ~150 LoC + an 80-line wrapper

The mental model — "OpenClaw is sandboxed, delegates to wizard@devvm for
trusted heavy lifting" — is a clean security boundary. Worth preserving.

## Architecture

### Pod side (`infra/stacks/openclaw/main.tf`)

Two new init containers added to the OpenClaw Deployment, after the
existing four:

#### Init 5 — `install-host-tools`

- Image: `debian:bookworm-slim` (matches main container base for glibc compat)
- Idempotent: skips if `/tools/host-tools/.installed-v1` exists
- `apt-get install --download-only --no-install-recommends` for:
  `openssh-client dnsutils iputils-ping wget gnupg jq ripgrep fd-find ncdu htop strace tcpdump tmux unzip`
- Iterates `.deb` files in `/var/cache/apt/archives/`, `dpkg-deb -x` each
  into `/tools/host-tools/root/` (preserves `usr/bin`, `usr/sbin`,
  `usr/lib` layout)
- Downloads static binaries to `/tools/host-tools/bin/`:
  - `vault` (HashiCorp releases, pinned version)
  - `yq` (mikefarah/yq GitHub releases, pinned version)
- Smoke test: invokes `--version` on each bundled binary; fails init if
  any won't load (catches glibc / shared-lib drift at deploy time, not
  runtime)
- Writes marker file with version

#### Init 6 — `setup-ssh-config`

- Image: uses the just-installed host-tools (debian:bookworm-slim base
  with `/tools/host-tools/root/usr/bin` on PATH so `ssh-keyscan` works)
- Runs after `install-host-tools`
- Idempotent: skips if `/home/node/.openclaw/.ssh/.configured-v1` exists
- Creates `/home/node/.openclaw/.ssh/` (uid 1000)
- Copies `/ssh/id_rsa` (tmpfs secret mount) → `~/.ssh/id_rsa` with 0600
  (the secret tmpfs mount has wider perms that openssh rejects)
- Writes `~/.ssh/config`:

  ```ssh-config
  Host devvm
    HostName 10.0.10.10
    User wizard
    IdentityFile ~/.ssh/id_rsa
    UserKnownHostsFile ~/.ssh/known_hosts
    StrictHostKeyChecking yes
  ```

  PATH handling on the remote side: devvm's sshd uses the default
  non-interactive PATH (`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin`)
  and does NOT load `~/.profile` or `~/.bashrc` (memory id=740). Client-side
  `SetEnv PATH=…` doesn't help because sshd's `AcceptEnv` is `LANG LC_*` only.
  Solution: install the binaries openclaw cares about into `/usr/local/bin/`
  on devvm (see "Devvm side" below).

- Pre-seeds `~/.ssh/known_hosts` via `ssh-keyscan -H 10.0.10.10`
- Writes marker file

#### Main container

- `PATH` env updated: prepend
  `/tools/host-tools/root/usr/bin:/tools/host-tools/root/usr/sbin:/tools/host-tools/bin`
- No other changes to the startup command

### Devvm side

#### `/usr/local/bin/openclaw-task` wrapper

Canonical source: `infra/stacks/openclaw/files/openclaw-task.sh`.
Installed to devvm at `/usr/local/bin/openclaw-task` (`sudo cp`, `sudo
chmod +x`) so non-interactive SSH finds it on the default PATH without
needing `~/.profile`. Updates: re-run the install steps from the
canonical source.

Also: `sudo ln -s /home/wizard/.local/bin/claude /usr/local/bin/claude`
so `ssh devvm claude …` works in non-interactive mode. `vault` and `tmux`
are already at `/usr/bin/` (system packages) so no symlink needed for
those.

POSIX shell script. Subcommands:

| Subcommand | Behavior |
|---|---|
| `new <id> <cmd...>` | Spawns detached tmux session `openclaw-task-<id>`, pipes pane output to `~/openclaw-tasks/<id>.log` |
| `claude <id> <prompt>` | Convenience: spawns interactive `claude` in a tmux session, send-keys the prompt + Enter |
| `send <id> <keys...>` | `tmux send-keys -t openclaw-task-<id> "$@"` — caller supplies `Enter` literal if needed |
| `capture <id> [lines]` | `tmux capture-pane -t … -p -S -<lines>` (default last 1000) |
| `log <id>` | `cat ~/openclaw-tasks/<id>.log` |
| `tail <id>` | `tail -n 100 -f ~/openclaw-tasks/<id>.log` (mainly for human ops) |
| `list` | tmux session list filtered to `openclaw-task-*`, one id per line |
| `status <id>` | `running` if tmux session alive, `ended` otherwise |
| `kill <id>` | `tmux kill-session -t openclaw-task-<id>` (log file is kept) |
| `purge <id>` | `kill` + `rm -f ~/openclaw-tasks/<id>.log` |

Task state lives entirely on devvm:

- tmux sessions persist across SSH disconnects and OpenClaw pod restarts
- `~/openclaw-tasks/<id>.log` is the durable transcript even after a
  session is killed
- No central database — `tmux list-sessions` is the source of truth for
  "what's running"

Naming convention: tmux sessions are prefixed `openclaw-task-` so they
don't collide with wizard's own tmux work (`0`, `Openclaw`, `read-only`).

### Memory note

File at `/workspace/memory/projects/openclaw-runtime/devvm-fallback.md`
teaching OpenClaw the pattern. Indexed by the existing daily
`memory-sync` CronJob (or via manual `node openclaw.mjs memory index
--force` for the initial seed).

Content (verbatim):

```markdown
# Using devvm as a fallback

When in-pod tools/permissions block you, SSH to devvm and use it. The
devvm runs as wizard with full home-lab access (Vault, kubectl, git
repos, Cloudflare, etc.) and has Claude Code v2+ installed.

## One-shot lookup
    ssh devvm 'vault kv get -field=brave_api_key secret/openclaw'
    ssh devvm 'claude -p "investigate why frigate is restarting"'

## Long-running async work — USE THIS for anything > ~2 min
Spawn in a tmux session on devvm. Sessions survive OpenClaw pod restarts.

    # spawn
    ssh devvm openclaw-task new my-task "claude -p --dangerously-skip-permissions 'do the thing'"

    # poll progress (last 1000 lines of pane)
    ssh devvm openclaw-task capture my-task

    # interactive claude (send follow-up prompts)
    ssh devvm openclaw-task claude my-task "initial prompt"
    ssh devvm openclaw-task send my-task "follow-up prompt" Enter

    # housekeeping
    ssh devvm openclaw-task list
    ssh devvm openclaw-task status my-task
    ssh devvm openclaw-task kill my-task

Logs persist at ~/openclaw-tasks/<id>.log on devvm even after a session
is killed. Use `ssh devvm openclaw-task log <id>` to retrieve them.
```

## Devvm: no infra changes

Pre-existing state verified 2026-05-22:

- pubkey from `/ssh/id_rsa` (Vault `secret/openclaw → ssh_key`) matches the
  `ssh-ed25519 AAAA…lug node@openclaw-58cd9f7987-884bv` line in
  `~/.ssh/authorized_keys` (the comment is a stale pod name; the key
  itself is stable from Vault)
- sshd listens on 0.0.0.0:22 ✓
- `claude` v2.1.126 at `/home/wizard/.local/bin/claude` ✓
- `tmux` 3.4 installed, server already running with existing user sessions ✓

Only changes (one-time, done in the same session via `sudo`):
- Install `openclaw-task` wrapper to `/usr/local/bin/openclaw-task`
- Symlink `/home/wizard/.local/bin/claude` → `/usr/local/bin/claude`

## Tradeoffs / risks

- **Bundle size on NFS**: ~30MB extracted. Acceptable on
  `/srv/nfs/openclaw/tools`.
- **Library version drift**: bundled binaries link against bookworm libs.
  Smoke test in `install-host-tools` catches breakage on the next pod
  restart if upstream OpenClaw image rebases.
- **Full-shell SSH**: explicit user choice. Blast radius if openclaw is
  prompt-injected = full wizard access. Mitigation: keep OpenClaw's
  plugin allowlist tight (current allow list: `memory-core, recruiter-api,
  telegram, openrouter, brave, openai, codex`).
- **tmux server lifecycle on devvm**: if wizard's tmux server dies (rare —
  usually only on devvm reboot), in-flight openclaw tasks are killed.
  Acceptable for home lab. Task logs persist regardless.
- **Task log unbounded growth**: `~/openclaw-tasks/*.log` grows forever.
  Out of scope here. User can add a `find -mtime +N -delete` cron later.
- **Init container order**: `setup-ssh-config` depends on
  `install-host-tools` finishing first. K8s init containers run
  sequentially in declaration order — natural ordering, no explicit
  dependency mechanism needed.

## Testing — E2E flows required by user

1. **Tools present**:
   `kubectl -n openclaw exec <pod> -c openclaw -- ssh -V` returns version,
   same for `dig`, `vault`, `jq`, `yq`, `tmux`, `rg`.
2. **SSH happy path**:
   `kubectl -n openclaw exec <pod> -c openclaw -- ssh devvm 'hostname'`
   returns `devvm`.
3. **Claude one-shot**:
   `kubectl -n openclaw exec <pod> -c openclaw -- ssh devvm 'claude -p "what is 1+1"'`
   returns `2`.
4. **Async task lifecycle**:
   - `ssh devvm openclaw-task new test-1 "sleep 30; echo done"`
   - `ssh devvm openclaw-task list` contains `test-1`
   - `ssh devvm openclaw-task status test-1` returns `running`
   - wait 35s
   - `ssh devvm openclaw-task log test-1` contains `done`
   - `ssh devvm openclaw-task status test-1` returns `ended`
5. **Persistence test** (the key requirement):
   - Spawn long task: `ssh devvm openclaw-task new persist-1 "sleep 120; echo survived > /tmp/persist-1.proof"`
   - `kubectl -n openclaw delete pod <openclaw-pod>` — pod recreated
   - Wait for new pod ready (init containers run, skip via marker, fast)
   - `kubectl -n openclaw exec <new-pod> -c openclaw -- ssh devvm openclaw-task list`
     contains `persist-1`
   - Wait for original sleep to finish; verify `/tmp/persist-1.proof`
     contains `survived` from new pod
6. **Memory note lookup**:
   `kubectl -n openclaw exec <pod> -c openclaw -- node openclaw.mjs memory search 'devvm fallback'`
   returns the note.

## Docs to update with the change

- `infra/docs/plans/2026-05-22-openclaw-devvm-access-design.md` (this doc)
- `infra/docs/plans/2026-05-22-openclaw-devvm-access-plan.md` (implementation plan)
- `infra/.claude/reference/service-catalog.md` (one-line addition under
  OpenClaw: "Has SSH to devvm with host-tools bundle; long-running async
  tasks via `openclaw-task` wrapper on devvm")
- `infra/.claude/CLAUDE.md` "Known Issues" section is left alone — none of
  the existing OpenClaw caveats change.
