# homelab usage telemetry: evidence-driven verb prioritization, privacy by construction

v0.6 adds `usage top` plus a fire-and-forget emit on every dispatched verb. It
exists to answer the question that drove the whole CLI — *which verbs are worth
adding next* — with data instead of one maintainer's habits (the earlier mining
covered a single user's ~51k commands, so the surface is shaped to that user).

## Decisions

- **Emit on dispatch, in `dispatch()`.** The longest-prefix match already knows
  the verb path; after `Run` returns we emit `{verb, exit}`. Discovery verbs
  don't go through `dispatch()` (`manifest`/`version`/`help` are handled in
  `dispatchTop`), so they don't self-record; `usage *` is skipped explicitly so
  the analytics reader doesn't pollute its own data.
- **Payload is deliberately minimal: verb path + exit code only.** Labels
  `{job=homelab-usage, user, verb}` (all low-cardinality) + line `exit=N ver=X`.
  **No args, paths, flags, hostnames, or secrets** ever leave the process — the
  emit sees only the matched verb name, not the arguments. This is what makes
  cross-user aggregation safe.
- **Shared Loki sink → cross-user analytics WITHOUT reading homes.** Each user's
  CLI writes its own invocations (attributed to its OS user) to the shared Loki
  push API via the Traefik LB (verified: HTTP 204, no auth). `usage top` reads
  back with a LogQL metric query. This is the privacy-preserving resolution to
  "what does everyone (e.g. another user) use" — it never touches anyone's
  `~/.claude`, which the org per-user policy bars (see the per-user red-line in
  managed-settings; reading another user's home is off-limits even for an owner
  in-session — a fresh session under changed MDM policy is the only legitimate
  path, and even then this telemetry is the better answer).
- **Best-effort, never affects the command.** All errors swallowed; an 800ms
  client timeout bounds the cost; opt-out via `HOMELAB_TELEMETRY=0`. Telemetry
  must never slow or break the tool it measures.
- **Loki, not a new datastore.** Zero new infra, and it dogfoods the v0.5 `logs`
  path (same host, same LB dial). Presence MySQL was the alternative (queryable
  SQL) but would add a write dependency and creds; Loki needs neither.
