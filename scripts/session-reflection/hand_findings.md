# Hand-verified findings (found by Viktor's agent directly, not by the workflow)

Recorded while the 36-agent run was in flight, so they survive whatever the agents
miss. Each one verified against the raw transcript or the live box.

## H1. The worktree rule teaches the manual git path and never names the homelab verb
- `~/.claude/rules/20-execution.md:21` teaches
  `git -C <repo> worktree add .worktrees/<topic> -b <os-user>/<topic> <remote>/master`
- line 25 teaches `git push <remote> HEAD:master`; line 26 teaches `git worktree remove`
- `grep -n "homelab work\|work start\|work land\|work clean"` over that file: NO MATCHES
- `homelab work start|land|clean` exist and run (`homelab: usage: homelab work start <topic>`)
- `homelab usage top --since 30d`: **zero** uses of work start / work land / work clean
  across all users, while logs query got 3,037
- D2 flagged 247 turns of manual `git worktree add` and 190 of manual `HEAD:master` push
- ROOT CAUSE: the rule itself is the competitor. Not a memory failure, not a
  discoverability failure. The authoritative doc teaches the path we do not want.
- FIX SHAPE: reword-rule, org-wide (docs/agents/shared -> provisioned copy)

## H2. Viktor's own example, measured end to end
Session `48a6e6d8`, 2026-08-31.
- turn 5 (13:09:53): investigating a **mobile** Firefox bug on Immich, Claude installs
  **desktop** Playwright Firefox locally. 21 tool calls, 9.7 min.
  Memories injected that turn: 5, relevance 0.18-0.23. All irrelevant.
- turn 6 (13:19:37): Viktor asks to reproduce on the cluster Android emulator.
  Claude then executes it competently in the SAME turn: presence claim on
  `service:android-emulator`, scale the deployment up, sideload Fenix 154.0.1.
  Memories injected that turn: 5, relevance 0.21-0.24. All irrelevant.
- So the capability knowledge was present and the execution was fine. What was absent
  was reaching for it unprompted. Nothing in the environment nominated it.
- RECURRENCE: session `a4154a1d` turn 11 (2026-08-13 08:12:36) is the same
  correction, a redirect to the emulator.
  Two instances, 18 days apart => a theme, not a one-off.
- `android-emulator.viktorbarzin.me` is listed in `homelab services` the whole time.

## H3. Detector blind spot found by hand: kubectl exec + psql vs `homelab k8s db`
- 34 turns / **159** Bash calls run `kubectl exec ... psql|mysql` without ever calling
  `homelab k8s db`, across 10 sessions.
- `homelab k8s db <app> -- "<SQL>"` exists for exactly this.
- My own D2 rule list did not include this pattern, so the workflow was never pointed
  at it. Recorded here as evidence that a fixed pattern list under-counts by
  construction, which is the completeness critic's job to generalise.

## H4. Memory recall is architecturally mistimed for capability facts
- The hook (`~/.claude/hooks/homelab-memory-recall.py:336`) runs
  `homelab memory recall <raw user prompt>` at UserPromptSubmit only.
- It injects the top 5 UNSEEN results and writes ids to a per-session seen-file, so an
  id is never re-injected in that session.
- Measured over the corpus: 4,570 injections, median relevance **0.37**, 45% below 0.35,
  and on 12% of turns with recall the BEST hit was below 0.35.
- The decision "how do I reproduce this" happens mid-turn, when nothing re-queries.

## H5. The recall hook can only surface a capability AFTER the conversation names it
> **CORRECTED 2026-09-01.** The first version of this finding claimed the emulator
> memories arrived at t7, "six minutes after the human supplied the same
> information". That was an off-by-one in `window.py`, caught by an adversarial
> reviewer and verified against the raw jsonl: the `hook_additional_context`
> attachment is written ~2s AFTER the user message it was computed for (session
> 48a6e6d8, prompt at line 2981, memories at line 2984), so attributing it
> forward shifted every turn. The tool is fixed. The corrected timeline below is
> a **stronger** result than the wrong one, not a weaker one.

Session `48a6e6d8`, 2026-08-31, timestamps exact:
- 13:09:53 t5 - Claude installs DESKTOP Playwright Firefox to chase a MOBILE Firefox
  bug. Injected: #6773(0.22) #8409(0.22) #6528(0.24) #6863(0.22) #10837(0.21).
  None of them the emulator recipes.
- 13:19:37 t6 - Viktor names the cluster Android emulator.
  Injected, 2 seconds later: #5323(0.48) **#11284(0.55) #9826(0.48)** #11541(0.48)
  #7015(0.54) - exactly the right five, at DOUBLE the relevance of the turn before.

That is the circularity in one measurement: the store held the answer the whole
time, and its relevance doubled the instant the prompt contained the word
"emulator". A prompt-keyed query cannot nominate a capability the prompt does
not already name.
The store was never the problem. Queried directly with the decision Claude actually
faced ("how do I test or reproduce an android app bug") it returns, unprompted:
  #11542 imp 0.80 "RECIPE - driving the TripIt PWA on the cluster Android emulator
                   from the devvm (proven 2026-08-22)"
  #11284 imp 0.75 "Driving the in-cluster Android emulator to reproduce a MOBILE WEB
                   layout bug with a REAL soft keyboard (worked 2026-08-17)"
  #6837  imp 0.78 split-horizon DNS gotcha when reproducing real-user issues
Written 9 and 14 days BEFORE the miss. A prompt-keyed recall is circular by
construction: it can only nominate a capability once the conversation already has.

## H6. Recall silently fails, at a rising rate, and nothing surfaces it
`~/.claude/tmp/memory-recall-errors.log`: **243 `recall failed: TimeoutExpired`** plus
7 CLI errors. Per-day: 1 (Aug 17) rising to 13 (Aug 29), 12 (Aug 30), 6 by mid-day Aug 31.
`RECALL_TIMEOUT_S = 6` (line 51). Measured live latency right now: 0.64-1.14s over five
queries, so these are p99 spikes rather than steady slowness. The hook exits 0 with no
output by design, so a turn that got nothing looks identical to a turn that needed
nothing, and the log is not surfaced anywhere.

## H7. Screenshot turns spend their recall call on image boilerplate
Same session, turns 8-14: seven consecutive turns whose prompt text is
`[Image: original 1080x2400, displayed at 900x2000. Multiply coordinates by 1.20 to map
to original image.]` (106 chars, so it clears `MIN_PROMPT_CHARS = 15`). The semantic
query for each of those turns was that boilerplate. Viktor communicates heavily by
screenshot (clipboard-store paths throughout the corpus), so this is not a rare shape.
