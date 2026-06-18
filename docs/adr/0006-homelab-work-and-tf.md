# homelab work/tf behaviour: native worktree entry, gated auto-land, presence-coupled apply

Four behaviours of the infra-loop verbs are surprising enough to record:

1. **`work` owns worktree create/land/clean, but session *entry* delegates to the
   native harness worktree tool.** A CLI is a child process and cannot change the
   agent's working directory; `EnterWorktree` can. So `homelab work start <topic>`
   creates the worktree + branch off `<remote>/master` (git-crypt-aware) and
   prints the path — the agent enters it with native `EnterWorktree({path})`.

2. **`work land` is auto-land, but gated on verification.** It merges master in →
   runs verification → pushes `HEAD:master` (fetch+merge+retry on
   non-fast-forward) → falls back to pushing the feature branch for a PR when the
   direct push is rejected (branch protection). It **refuses to push when it
   cannot verify** (no `--verify-cmd` and no auto-detected suite) unless
   `--no-verify` is passed — added after an accidental smoke-test land pushed
   unverified WIP to master (benign: the infra CI applied 0 stacks because the
   diff was `cli/`-only, but an unverified land must be deliberate, not default).

3. **`tf apply` is first-class despite GitOps, and mandatorily presence-coupled.**
   Local applies are out-of-band (CI applies canonically on push) but happen
   constantly (~763× in the corpus). `tf apply <stack>` auto-claims `stack:<name>`,
   delegates to `scripts/tg apply --non-interactive`, and **always releases on
   exit** (normal, error, or signal via `sync.Once` + handler) — fixing the
   documented ~200-claim leak — and prints an out-of-band reminder.

4. **Known v0.1 limitation:** `work land` does not yet block on CI to green; that
   arrives with the ci/deploy watch verb-group. It prints a reminder to follow
   the pipeline manually.
