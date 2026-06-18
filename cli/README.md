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

See `infra/docs/adr/0004`–`0006` for the architecture decisions.
