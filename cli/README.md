# homelab

`homelab` is the unified, agent-facing CLI for operating this homelab — one
composable, JSON-capable surface for the operations agents run over and over,
discovered progressively at runtime. It is grown **in place** from this
directory (the former `infra-cli`), and the legacy webhook use-cases still work
(see below).

It encodes *actions*, never *judgment*: methodology (debugging, TDD, review) and
third-party/owned MCP servers (e.g. phpIPAM) are deliberately out of scope.

## Usage

```
homelab <command> [args]
homelab manifest [--json]    # list every verb + its read/write tier (discovery entrypoint)
homelab version
```

### v0.1 verbs — the infra inner-loop

| Command | Tier | What it does |
|---|---|---|
| `claim <kind>:<name> --purpose "…"` | write | claim a shared resource on the presence board (wraps `scripts/presence`) |
| `release <kind>:<name>` | write | release a presence claim |
| `tf plan <stack>` | read | `scripts/tg plan` for a stack (resolved from cwd) |
| `tf validate <stack>` | read | `scripts/tg validate` |
| `tf fmt <stack>` | read | `terraform fmt -recursive` on the stack |
| `tf force-unlock <stack> <lock-id>` | write | release a stuck state lock |
| `tf apply <stack>` | write | `scripts/tg apply` — auto-claims `stack:<name>`, always releases, warns it's out-of-band |
| `work start <topic>` | write | create `.worktrees/<topic>` on `<user>/<topic>` off `<remote>/master`; enter with native `EnterWorktree` |
| `work land [--verify-cmd "…"] [--no-verify]` | write | merge master in → verify → push `HEAD:master` (non-ff retry; PR fallback) |
| `work clean <topic>` | write | remove a task's worktree + branch (run from the main checkout) |

### v0.2 verbs — Kubernetes

Built on an **app→namespace→pod resolver**: `<app>` defaults to the namespace
(most namespaces hold one app); the target defaults to `deploy/<app>` and lets
kubectl resolve the pod. Override with `-n`/`--pod`/`-c`/`-l`/`--tty`. Uses the
ambient kubeconfig.

| Command | Tier | What it does |
|---|---|---|
| `k8s status [ns]` | read | pods (wide) + recent non-Normal events (`-A` if no ns) |
| `k8s get <ns> <resource> […]` | read | `kubectl -n <ns> get …` passthrough |
| `k8s logs <app>` | read | logs for `deploy/<app>` (`--tail` default 200; `-c`/`--previous`/`--since`/`-l`) |
| `k8s describe <app> [resource]` | read | describe the deployment (or an explicit resource) |
| `k8s debug <app>` | read | one-shot triage: pods + workloads + describe + recent logs + events |
| `k8s pf <app> <local:remote> [target]` | read | port-forward to `svc/<app>` (or an explicit target) |
| `k8s rollout-status <app>` | read | `rollout status deploy/<app>` |
| `k8s db <app> [--mysql] [--db N] -- "<SQL>"` | write | exec into the dbaas DB (PG `pg-cluster-rw`, or MySQL with env-password wrapper) |
| `k8s exec <app> [--tty] -- <cmd>` | write | exec in the app's pod |
| `k8s restart <app>` | write | `rollout restart deploy/<app>` then wait for status |
| `k8s rm-pod <name> -n <ns> [--job] [--force]` | write | delete a stuck **pod/job only** |

Config-mutation verbs (`apply`/`edit`/`patch`/`scale`/`create`) are intentionally
**not** exposed — they stay raw `kubectl`, per the Terraform-only policy.

`tf` resolves the stack dir by walking up from cwd to the infra root and
delegates to `scripts/tg` (which owns state decrypt/encrypt, the Vault lock, and
the ingress auth-comment check). git-crypt filter flags are auto-injected on git
operations in the encrypted infra repo.

**`work land` refuses to push when it cannot verify** (no `--verify-cmd` and no
auto-detected suite) unless you pass `--no-verify` — landing to master unverified
must be deliberate. It does not yet block on CI to green (that arrives with the
ci/deploy watch verbs); it reminds you to follow the pipeline.

Tiers are recorded per verb so a future PreToolUse classifier can auto-allow
reads / prompt writes; v0.1 allows everything and relies on existing gates
(permission mode, presence claims, plan approval).

### v0.3 verbs — memory

A thin HTTP client over the **claude-memory** service (the same backend the
memory MCP wraps), authed with `CLAUDE_MEMORY_API_KEY` against
`CLAUDE_MEMORY_API_URL` (the env the hooks already set; defaults to the
ingress). Because it hits the HTTP API directly, it **works even when the MCP
frontend is down**.

| Command | Tier | What it does |
|---|---|---|
| `memory recall "<context>" [--query --category --sort --limit]` | read | semantic search (server-side ranking) — the navigate workhorse |
| `memory list [--category --tag --limit]` | read | recent memories |
| `memory categories` / `memory tags` / `memory stats` | read | enumerate the store |
| `memory secret <id>` | read | reveal a sensitive memory's content |
| `memory store "<content>" [--category --tags --keywords --importance --sensitive]` | write | store a memory |
| `memory update <id> [--content --tags --importance]` | write | edit a memory |
| `memory delete <id>` | write | delete a memory |

All read/write paths are validated against the live API (incl. a
store→recall→delete round-trip). This gives full data-plane parity with the MCP;
the eventual deprecation (rewiring the per-prompt auto-recall + auto-learn hooks
to the CLI, then uninstalling the MCP) is a **separate, deliberate follow-up** —
see `docs/adr/0008`.

## Build / install

Built from source to `/usr/local/bin/homelab` during devvm provisioning
(`scripts/workstation/setup-devvm.sh`, the `t3-dispatch` pattern); version is
stamped from `cli/VERSION` via ldflags. Manual build:

```
cd cli && go build -ldflags "-X main.version=$(cat VERSION)" -o /usr/local/bin/homelab .
go test ./...
```

## Legacy webhook use-cases (preserved)

This binary is also the in-cluster `infra-cli` image. Invocations starting with
`-use-case=<vpn|setup-openwrt-dns|add-email-alias|...>` fall through to the
original flag-based path unchanged, so the webhook handler is unaffected.

## Design

See `infra/docs/adr/0004`–`0008` for the architecture decisions.
