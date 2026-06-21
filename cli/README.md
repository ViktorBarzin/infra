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
must be deliberate. After pushing it **watches CI to green** (`ci watch` on the
landed commit) and fails if the pipeline does; pass `--no-ci-watch` to skip.

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

### v0.4 verbs — ci / deploy

Watch what you trigger, without hand-rolling Woodpecker/kubectl polling. `ci`
talks to the Woodpecker API (token from `WOODPECKER_TOKEN` or Vault
`secret/ci/global`) via the internal Traefik LB, resolving the repo from the cwd
remote, with retries that ride Woodpecker's intermittent empty responses.

| Command | Tier | What it does |
|---|---|---|
| `ci status [commit]` | read | pipeline status for HEAD (or a commit) |
| `ci watch [commit]` | read | poll the pipeline to terminal; exit non-zero on failure |
| `deploy wait <ns>/<deploy> [--sha SHA]` | read | wait for the deployment image to match the sha, *then* rollout status (rollout status alone lies on the old ReplicaSet) |

`work land` now calls `ci watch` on the landed commit automatically (skip with
`--no-ci-watch`), closing the v0.1 "doesn't wait for CI" gap. `ci logs` (failing
step) is deferred to v0.4.1 — Woodpecker's per-pipeline detail/log endpoints were
the least reliable; `status`/`watch` use the list endpoint that works.

### v0.5 verbs — net / dns / metrics / logs

Reachability + observability probes. Their value is *endpoint resolution* — the
non-obvious "which host, public or LB, what auth, what URL shape" reasoning you'd
otherwise re-derive every time — not the HTTP call itself. All reach internal
ingresses through the Traefik LB (the Go form of `curl --resolve host:443:10.0.20.203`).

| Command | Tier | What it does |
|---|---|---|
| `net check <host> [path]` | read | probes the host two ways — external (public DNS → Cloudflare) vs internal (Traefik LB) — with status + latency, so you can tell *where* a break is (CF? app? the LB path?) |
| `dns lookup <name> [type]` | read | resolves via Technitium (`10.0.20.201`) and public (`1.1.1.1`), diffed — surfaces split-horizon vs propagation gaps |
| `metrics query "<promql>"` | read | Prometheus instant query (`prometheus-query.viktorbarzin.lan`); prints `value {labels}` or `--json` |
| `metrics alerts` | read | currently-firing alerts (via the synthetic `ALERTS` series — the query frontend has no `/api/v1/alerts`) |
| `logs query "<logql>" [--since 1h] [--limit N]` | read | Loki range query (`loki.viktorbarzin.lan`); prints log lines or `--json` |

Quote the PromQL/LogQL. These hit auth-free internal ingresses — no port-forward,
no kubectl. (In-cluster-only endpoints like Alertmanager stay out of scope; the
firing set is reachable via `ALERTS` instead.)

### v0.6 — usage telemetry (`usage top`)

Makes "which verbs are actually used, by everyone" a query instead of a guess —
so adding the *next* verb is evidence-driven, not shaped by one person's habits.

Every dispatched verb emits one fire-and-forget Loki line: `{job, user, verb}`
labels + `exit=N ver=X` — **only the verb path and exit code, never args, paths,
flags, or secrets.** It's best-effort (tight timeout, errors swallowed, never
affects the command) and opt-out via `HOMELAB_TELEMETRY=0`. Because the sink is
the shared Loki, aggregate usage is queryable **without reading anyone's home** —
the privacy-preserving answer to "what does the team use."

| Command | Tier | What it does |
|---|---|---|
| `usage top [--since 30d] [--user U] [--json]` | read | rank verbs by invocation count across all users (or one), via `sum by (verb) (count_over_time({job="homelab-usage"}[…]))` |

### v0.7 verbs — Home Assistant

Cover exactly the two things the `ha` **MCP server can't**: resolving the
long-lived API token out of the cluster, and SSH to the HA host for host-level
work (config files, docker, add-ons). Entity state and control (`turn_on`,
`get_state`, services) stay with the MCP — *actions an MCP already encodes are
out of scope* (see top of this doc). The value here is the same as `net`/`dns`:
the non-obvious *which secret, which host, which key, which flags* you'd
otherwise re-derive every session — agents were hand-rolling a
`kubectl | base64 | jq` token pipeline and a bespoke `ssh -o …` invocation on
every run because the existing `home-assistant-sofia.py` needs an env var set
and a cwd-relative path, neither of which holds in an arbitrary session.

| Command | Tier | What it does |
|---|---|---|
| `ha token [--instance sofia\|london]` | read | print the long-lived HA API token, resolved live from the dedicated k8s Secret `openclaw/ha-tokens` (key per instance) via the ambient kubeconfig — no pre-set env var. Use as `curl -H "Authorization: Bearer $(homelab ha token)" …`. The secret is a least-privilege carve-out (`stacks/openclaw/ha_tokens.tf`): the `Home Server Admins` group can read *just* it, so non-admin operators get the HA token without the rest of `skill_secrets` (slack webhook, uptime-kuma password) |
| `ha ssh [--instance sofia\|london] [-i KEY] -- <cmd>` | write | run `<cmd>` on the HA host over ssh with deterministic non-interactive flags (explicit key = the invoking user's `~/.ssh/id_ed25519`, no user ssh-config, no known_hosts prompt). sofia (`vbarzin@192.168.1.8`) is reachable from the devvm LAN; london is documented but generally remote |

`--instance` defaults to **sofia** (the devvm shares the Sofia LAN). `ha token`
prints the bare token to stdout so it composes in `$(…)`; it's read-tier like
`memory secret`. `ha ssh` resolves the *invoking user's* key, so it's per-user,
not tied to whoever first wrote the workflow (the user's key must be enrolled on
the HA host).

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

See `infra/docs/adr/0004`–`0012` for the architecture decisions.
