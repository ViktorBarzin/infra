# session-reflection — measure how often we reach past our own tooling

Built 2026-08-31 to answer "why does Claude keep reaching past the homelab".
Findings are published at `pages.viktorbarzin.me/2026-08-31-session-reflection.html`.
Moved here from the `~/code` monorepo root (`docs/agents/session-reflection/`) on
2026-11-03, so `homelab reflect` and its history sit in the repo that ships the CLI.

Made re-runnable 2026-09-01, because Viktor wants it run periodically to keep
improving the tooling. **The point of a repeat run is the trend,
not the number.** One run says we hand-roll 1,789 `sleep` calls; two say whether
the reword worked.

## Run it

```sh
homelab reflect                    # store pass for the last 7 days: record, push, print the delta
homelab reflect run --days 30      # a longer window
homelab reflect run --with-transcripts   # also the original transcript detectors
homelab reflect history            # every recorded run
homelab reflect diff               # last two runs, side by side
homelab reflect diff --from 2026-09-01 --to 2026-10-01
```

Since 2026-11-09 a run reads the claude-sessions ClickHouse store (ADR-0039)
instead of transcript files: the queries in `store_metrics.json`, run through
`homelab claude-sessions sql`, take about 15 seconds and spend no model tokens.
Admins only, like the store. Each `run`:

1. runs every query in `store_metrics.json` for the window (`--days`, default 7,
   ending now) and user (`--user`, default you),
2. with `--with-transcripts`, also classifies transcripts and applies the four
   original detectors. That reads the whole corpus from the disk etcd shares,
   so it is opt-in,
3. writes a snapshot to `history/` next to `reflect.py`, in the infra checkout
   the CLI found. Commit it to infra master: the before/after is a git diff,
4. pushes the numbers to Pushgateway as `session_reflection_*` and
   `session_reflection_store_*` (Prometheus, 26-week retention),
5. stores one memory so a future session recalls the trend without running
   anything,
6. prints the delta against the previous run.

`--no-push`, `--no-memory`, `--no-record` and `--json` all exist.

### Checking whether a change helped

Run `homelab reflect` before the change, use the change for a few days, run it
again, and read `homelab reflect diff`. Compare windows of the same length, and
expect noise: a week holds roughly 200 to 400 sessions and 100 to 1,000 typed
prompts, so a small shift in a small count (11 grilling overrides, 3 interrupts)
can be chance.

### What the store pass measures

`store_metrics.json` is the list, one named SQL query each:

| Key | What it counts |
|---|---|
| `sessions`, `human_prompts`, `api_requests`, `output_tokens_m` | volume |
| `spend_usd`, `spend_by_model` | Claude Code's own cost, sessions started in the window; lags for a running session |
| `cache_rewrite_usd_est` | estimated cost of re-writing big contexts to cache after an idle hour |
| `tool_calls`, `tool_failures`, `failures_by_tool` | tool use and errors (errors include a grep that finds nothing) |
| `tool_choice` | `kubectl` edits, `sleep`, manual `git push HEAD:master` and worktrees, `kubectl logs`, `journalctl`, beside `work land`, `work start`, `homelab logs query`, `deploy wait`/`ci watch` |
| `blocked` | scan-guard, rm-guard, zsh-guard, worktree isolation, unknown skill, permission denied |
| `questions` | questions answered, share where the recommended option won, hours sessions waited |
| `friction` | interrupts, correction-like prompts, status check-ins |
| `grilling` | grilling sessions, questions, answers that overrode the recommendation |
| `skill_uses` | Skill tool calls per skill |

Adding or changing a query changes `store_fingerprint`, and `diff` warns, as
for `patterns.json`. Tests: `python3 -I test_store.py`.

## The expensive half, on demand

`workflow.js` is the 36-agent pass that JUDGES what the detectors locate:
per-theme finders, a synthesis, three adversarial agents briefed to disprove,
and a completeness critic. Measured 2026-08-31 at 6.8M tokens and ~105 minutes,
which is why it is deliberately not part of `reflect run`.

It earns that cost. On the first run the adversarial agents refuted **4 of 10**
themes, corrected the headline cost figure from 510 to ~148 minutes, and found
an off-by-one in this tooling that had already produced a wrong timeline.
Detectors locate; only the judging pass decides.

```sh
homelab reflect run --work-dir /tmp/sr --no-record   # leave detector output in /tmp/sr
python3 workflow_args.py /tmp/sr > /tmp/sr/wf_args.json
```

then invoke the Workflow tool with `scriptPath` = `workflow.js` and `args` =
that JSON. **Update the dates and ground-truth numbers in the brief before
re-running** — it asserts facts verified on 2026-08-31, and a stale fact in a
brief is worse than none, because agents trust it.

## Adding a detector pattern

`patterns.json`, not code. The 2026-08-31 study found D2 under-counts **by
construction** — 159 `kubectl exec … psql` calls were found by hand, outside
every detector — and that should never have needed a code change. Four such
patterns are now first-class (`k8s db`, the waiting verbs, `ci status --repo`,
`how`) and together they surface 227 anomalies the original run could not see.

Every snapshot records a `patterns_fingerprint`. `diff` warns when two runs were
measured with different patterns, because a jump may then be a new detector
rather than a regression.

## What the detectors are

| # | detector | method |
|---|---|---|
| D1 | correction language | tiered lexicon over human turns; `mine_vocab.py` re-derives it |
| D2 | tool-sequence anomaly | one rule per (built-in, homelab verb) pair |
| D3 | memory-recall efficacy | which memories the hook injected per turn, with relevance |
| D4 | wins control | turns where a homelab verb was reached for unprompted |

Read one window:

```sh
python3 window.py --session <session-id> <turn> --before 2 --after 3 --tools 40
```

## Comparability

A number must mean the same thing next time. **When you change what a detector
counts, add a new key rather than redefining an old one** — otherwise the trend
silently lies. Adding patterns does change counts, which is what the fingerprint
is for.

## Four extraction facts, each learned the hard way

Getting these wrong produced confidently wrong numbers.

1. **Synthetic QA probes are about half the corpus.** 163 of 340 transcripts are
   terminal-lobby/t3 harness sessions ("Reply with exactly the word PONG").
2. **Harness-injected user turns are not turns the user typed.** Skill bodies,
   compaction summaries and teammate messages arrive as `role: user`; counting
   them inflated the first pass from 1,381 to 1,861 turns.
3. **Memory injections are not messages.** They are `type: "attachment"` entries
   whose `attachment.type == "hook_additional_context"`. A pass over `"message"`
   lines alone reports zero recall corpus-wide.
4. **The injection attachment is written AFTER the user message it belongs to**
   (verified: session 48a6e6d8, prompt at line 2981, memories at line 2984, two
   seconds later). Attaching it forward shifts every attribution one turn late.
   An adversarial reviewer caught this after the wrong timeline had been stated.

## Limits

- D2 is a pattern list. It under-counts by construction; when you find a miss by
  hand, add it to `patterns.json` in the same session.
- Subagent tool choices appear in no transcript, so ~137 delegating turns are
  invisible here. That blind spot is unfixed.
- The corpus is one user's sessions; widening needs `sudo`.
- `sessions_real` counts sessions that produced at least one detector hit, not
  every session examined.
