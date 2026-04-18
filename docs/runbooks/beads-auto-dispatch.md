# Beads Auto-Dispatch Runbook

Users can hand work to the headless `beads-task-runner` agent by assigning a
bead to the sentinel user `agent`. Two CronJobs in the `beads-server`
namespace drive the pipeline:

- **`beads-dispatcher`** — every 2 min: picks up the highest-priority
  `assignee=agent`/`status=open` bead with non-empty acceptance criteria,
  claims it by flipping to `in_progress`, and POSTs it to BeadBoard's
  `/api/agent-dispatch`. BeadBoard forwards to `claude-agent-service` with
  the existing bearer-token flow.
- **`beads-reaper`** — every 10 min: flips any `assignee=agent` +
  `status=in_progress` bead whose `updated_at` is older than 30 min to
  `status=blocked` with an explanatory note. Catches pod crashes mid-run.

The manual BeadBoard Dispatch button continues to work in parallel.

## Flow diagram

```
  user: bd assign <id> agent
         │
         ▼
  Dolt @ dolt.beads-server.svc:3306  ◄──── every 2 min ────┐
         │                                                  │
         ▼                                                  │
  CronJob: beads-dispatcher                                 │
    1. GET beadboard/api/agent-status  (busy?)              │
    2. bd query 'assignee=agent AND status=open'            │
    3. bd update -s in_progress   (claim)                   │
    4. POST beadboard/api/agent-dispatch                    │
    5. bd note "dispatched: job=…"                          │
         │                                                  │
         ▼                                                  │
  claude-agent-service /execute                             │
    beads-task-runner agent runs; notes/closes bead         │
         │                                                  │
         ▼                                                  │
  done  ──► next tick picks up the next bead ───────────────┘


  CronJob: beads-reaper  (every 10 min)
    for bead (assignee=agent, status=in_progress, updated_at > 30 min):
      bd note   "reaper: no progress for Nm — blocking"
      bd update -s blocked
```

## Usage

### Hand a bead to the agent

```
bd create "Title" \
    -d "Full context — files, services, error messages. Any agent with no prior context must be able to execute this." \
    --acceptance "Concrete, verifiable criteria" \
    -p 2
bd assign <new-id> agent
```

**Acceptance criteria is required.** Beads without it are skipped by the
dispatcher and stay in `open` forever. This is intentional — the
`beads-task-runner` agent expects clear done conditions.

### Take a bead back (unassign)

```
bd assign <id> ""
```

If the bead is already `in_progress`, also reset it:

```
bd update <id> -s open
```

### Pause auto-dispatch

```
cd infra/stacks/beads-server
scripts/tg apply -var=beads_dispatcher_enabled=false
```

This sets `spec.suspend: true` on both CronJobs. Existing running jobs
continue; no new ticks fire. Re-enable by re-applying with
`beads_dispatcher_enabled=true` (the default). Manual BeadBoard Dispatch
remains available while paused.

### Read the logs

```
# Recent dispatcher runs
kubectl -n beads-server get jobs --selector=job-name --sort-by=.metadata.creationTimestamp | grep beads-dispatcher | tail
kubectl -n beads-server logs job/<dispatcher-job-name>

# Tail the underlying agent once a bead dispatches
kubectl -n claude-agent logs -l app=claude-agent-service -f

# Inspect reaper decisions
kubectl -n beads-server get jobs | grep beads-reaper | tail
kubectl -n beads-server logs job/<reaper-job-name>
```

### Inspect a specific bead's dispatch history

```
bd show <id> --json | jq '{status, assignee, notes, updated_at}'
```

Both the dispatcher and reaper write dated notes (`auto-dispatcher claimed
at…`, `dispatched: job=…`, `reaper: no progress for…`) so the audit trail
lives on the bead itself.

## Reaper semantics — when a bead becomes `blocked`

The reaper flips a bead to `blocked` if:
- `assignee = agent`, AND
- `status = in_progress`, AND
- `updated_at` is more than **30 minutes** in the past.

Every `bd note` bumps `updated_at`, so a well-behaved `beads-task-runner`
agent never trips the reaper — it notes progress as it works. A `blocked`
bead is a signal that:
- the agent pod crashed mid-run (`kubectl -n claude-agent delete pod` test),
- the job hit its 15-minute budget timeout inside `claude-agent-service`
  without notes (rare — the agent usually notes failure before exiting),
- `claude-agent-service` was restarted during the run (in-memory job state
  is lost; see [known risks](#known-risks)).

Recovery: read the reaper note, reopen manually if appropriate:

```
bd update <id> -s open
bd assign <id> agent     # re-arm for next dispatcher tick
```

## Design choices

- **Sentinel assignee `agent`** — free-form, no Beads schema change. Any bd
  client can set it (`bd assign <id> agent`).
- **Sequential dispatch** — matches `claude-agent-service`'s single-slot
  `asyncio.Lock`. With a 2-min poll cadence and ~5-min average run,
  throughput is ~12 beads/hour. Parallelism is a separate plan.
- **Fixed agent (`beads-task-runner`)** — read-only rails, matches BeadBoard's
  manual Dispatch button. Broader-privilege agents stay manual.
- **CronJob (not in-service polling, not n8n)** — matches existing infra
  pattern (OpenClaw task-processor, certbot-renewal, backups), TF-managed,
  easy to pause.
- **ConfigMap-mounted `metadata.json`** — declarative TF rather than reusing
  the image-seeded file. The CronJob's init step copies it into `/tmp/.beads/`
  because `bd` may touch the parent directory and ConfigMap mounts are
  read-only.

## Known risks

- **In-memory job state in `claude-agent-service`** — if the pod restarts
  mid-run, the job record is lost. The reaper catches this after 30 min.
  Persistent job store is deferred.
- **Prompt injection via bead fields** — a malicious bead description could
  try to steer the agent. The `beads-task-runner` rails + token budget +
  timeout are the defense. Identical exposure as the manual Dispatch button.
- **Image tag drift** — `claude_agent_service_image_tag` in
  `stacks/beads-server/main.tf` mirrors `local.image_tag` in
  `stacks/claude-agent-service/main.tf`. Bump both when the image rebuilds,
  or the dispatcher/reaper will run on an older layer. (They only need
  `bd`, `curl`, `jq` — stable across rebuilds — so the drift is low-risk.)
- **`bd` JSON schema changes** — the reaper's `jq` reads `.id` and
  `.updated_at`. If a future `bd` upgrade renames these, the reaper breaks
  silently (no reaping, no alert). `BD_VERSION` is pinned in the image
  Dockerfile.

## Verification after change

```
# Both CronJobs exist with the right schedule / SUSPEND state
kubectl -n beads-server get cronjob

# End-to-end smoke test
bd create "auto-dispatch smoke test" \
    -d "Read /etc/hostname inside the agent sandbox and close." \
    --acceptance "bd note includes 'hostname=' and bead is closed."
bd assign <new-id> agent
# within 2 min:
bd show <new-id> --json | jq '.notes'
# → contains 'auto-dispatcher claimed' + 'dispatched: job=<uuid>'
```
