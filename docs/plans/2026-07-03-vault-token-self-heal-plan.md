# Vault Token Renewer Self-Heal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `vault login -method=oidc` harmless on devvm — the nightly renewer re-mints the permanent periodic token from any admin-capable clobber of `~/.vault-token`, unattended.

**Architecture:** Extend the drift branch of `scripts/vault-token-renew.sh` (deployed to `~/.local/bin/vault-token-renew`, driven by an existing systemd user timer). On drift, *attempt* the re-mint with the clobbering token itself and let Vault's 403 be the authority; sanity-check the minted token, replace the file atomically, then revoke stale `token-devvm-wizard` leftovers. Weak clobbers keep today's loud failure. Design: `docs/plans/2026-07-03-vault-token-self-heal-design.md`.

**Tech Stack:** bash + jq + vault CLI; existing test harness `scripts/test-vault-token-renew.sh` (sources the script, `vtr_main` is guarded).

**Working copy:** everything below runs in the worktree
`~/code/infra/.worktrees/vault-token-self-heal` on branch `wizard/vault-token-self-heal`.
Per repo policy, EVERY git command in this git-crypt repo worktree carries:
`-c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false`
(abbreviated as `$GCFLAGS` below; define once per shell:
`GCFLAGS="-c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false"`
and use it unquoted: `git $GCFLAGS <verb> …`).

---

### Task 1: Unit tests for the two new pure functions (RED)

**Files:**
- Modify: `scripts/test-vault-token-renew.sh` (append before the final `printf`/exit lines)

- [ ] **Step 1: Append the failing tests**

Insert this block immediately after the existing "parse + decide end-to-end" section (after the line `no "oidc: parse+decide refused" …`, before the final `printf '\n%d passed…'`):

```bash
# --- vtr_accessor: parse accessor out of lookup JSON ---
LOOKUP_NEW='{"data":{"display_name":"token-devvm-wizard","accessor":"acc-new","policies":["default","sops-admin","vault-admin"],"identity_policies":null}}'
eq "accessor parsed"          "acc-new" "$(vtr_accessor "$LOOKUP_NEW")"
eq "accessor absent -> empty" ""        "$(vtr_accessor '{"data":{"display_name":"x"}}')"

# --- vtr_is_stale_periodic: the heal's revoke filter — ONLY old token-devvm-wizard
# --- tokens are swept; the just-minted token, foreign tokens, and anything with an
# --- unknown accessor are kept. An empty keep-accessor sweeps NOTHING (fail-safe).
STALE_OURS='{"data":{"display_name":"token-devvm-wizard","accessor":"acc-old","policies":["default","sops-admin","vault-admin"]}}'
ok "older periodic token is stale"      vtr_is_stale_periodic "$STALE_OURS" "acc-new"
no "the just-minted token is kept"      vtr_is_stale_periodic "$LOOKUP_NEW" "acc-new"
no "foreign oidc token never swept"     vtr_is_stale_periodic "$LOOKUP_OIDC" "acc-new"
no "woodpecker token never swept"       vtr_is_stale_periodic "$LOOKUP_WP" "acc-new"
no "missing accessor never swept"       vtr_is_stale_periodic '{"data":{"display_name":"token-devvm-wizard"}}' "acc-new"
no "empty keep-accessor sweeps nothing" vtr_is_stale_periodic "$STALE_OURS" ""
```

(`LOOKUP_OIDC` / `LOOKUP_WP` and the `ok`/`no`/`eq` helpers already exist in the file.)

- [ ] **Step 2: Run tests, verify they fail**

Run: `bash scripts/test-vault-token-renew.sh`
Expected: FAILs / `command not found` for `vtr_accessor` and `vtr_is_stale_periodic`; the 17 pre-existing tests stay green.

### Task 2: Implement the pure functions (GREEN)

**Files:**
- Modify: `scripts/vault-token-renew.sh` (insert after `vtr_drift_ok()`, before `vtr_main()`)

- [ ] **Step 1: Add the two functions**

```bash
# vtr_accessor <lookup-json> -> the token accessor (empty if absent).
vtr_accessor() {
  printf '%s' "$1" | jq -r '.data.accessor // ""'
}

# vtr_is_stale_periodic <lookup-json> <keep-accessor> -> 0 if this lookup
# describes one of OUR periodic tokens (display name matches) that is NOT the
# one to keep — i.e. a stale leftover a heal should revoke. 1 otherwise.
# Name-only on purpose (no policy check): anything named token-devvm-wizard
# that isn't the current token is garbage from a previous mint. An empty
# keep-accessor sweeps NOTHING (fail-safe: never revoke when we don't know
# which token is current).
vtr_is_stale_periodic() {
  local dn acc
  [ -n "${2:-}" ] || return 1
  dn=$(vtr_display_name "$1")
  acc=$(vtr_accessor "$1")
  [ "$dn" = "$EXPECTED_DN" ] || return 1
  [ -n "$acc" ] || return 1
  [ "$acc" != "$2" ]
}
```

- [ ] **Step 2: Run tests, verify all pass**

Run: `bash scripts/test-vault-token-renew.sh`
Expected: `25 passed, 0 failed`, exit 0.

- [ ] **Step 3: Commit**

```bash
cd ~/code/infra/.worktrees/vault-token-self-heal
git $GCFLAGS add scripts/vault-token-renew.sh scripts/test-vault-token-renew.sh
git $GCFLAGS commit -m "vault-token-renew: pure helpers for the self-heal revoke filter

vtr_accessor parses the accessor from lookup JSON; vtr_is_stale_periodic
decides which old token-devvm-wizard tokens a heal may revoke (never the
just-minted one, never foreign tokens, nothing when the keeper is unknown).
TDD red-green for the heal branch that lands next."
```

### Task 3: The heal branch (`vtr_heal` + `vtr_main` wiring)

**Files:**
- Modify: `scripts/vault-token-renew.sh`

- [ ] **Step 1: Add `vtr_heal` after `vtr_is_stale_periodic()`, before `vtr_main()`**

```bash
# vtr_heal <foreign-dn> <log-file> -> 0 if ~/.vault-token was re-minted back to
# our periodic admin token using the foreign token's own authority, 1 if the
# heal was denied or failed (caller exits non-zero; the unit goes failed).
#
# Self-heal added 2026-07-03 (docs/plans/2026-07-03-vault-token-self-heal-design.md):
# an OIDC login — which the infra docs prescribe before applies — clobbers
# ~/.vault-token with a 7-day token, and detect-only drift left that unnoticed
# for weeks (the weekly-expiry loop). We ATTEMPT the re-mint with the
# clobbering token itself and let Vault's authz decide — a read-only clobber
# (the 2026-06-05 woodpecker incident) is denied the mint and stays a loud
# failure, because it signals a misbehaving flow that someone should look at.
vtr_heal() {
  local foreign_dn="$1" log="$2"
  local errf new_token new_info new_dn new_pols new_acc tmp
  errf=$(mktemp)
  if ! new_token=$(vault token create -orphan -period=768h \
        -policy=vault-admin -policy=sops-admin -display-name=devvm-wizard \
        -field=token 2>"$errf") || [ -z "$new_token" ]; then
    printf '%s DRIFT: ~/.vault-token is dn=%q — heal denied, foreign token lacks create authority (%s); investigate what wrote it. Manual re-mint: vault login -method=oidc && vault token create -orphan -period=768h -policy=vault-admin -policy=sops-admin -display-name=devvm-wizard -field=token > ~/.vault-token && chmod 600 ~/.vault-token\n' \
      "$(date -Is)" "$foreign_dn" "$(tr '\n' ' ' <"$errf")" >>"$log"
    rm -f "$errf"
    return 1
  fi
  rm -f "$errf"

  # Sanity: the minted token must itself pass the drift guard before it may
  # replace ~/.vault-token.
  if ! new_info=$(VAULT_TOKEN="$new_token" vault token lookup -format=json 2>&1); then
    printf '%s FAIL: heal minted a token but its lookup failed: %s\n' \
      "$(date -Is)" "$new_info" >>"$log"
    return 1
  fi
  new_dn=$(vtr_display_name "$new_info")
  new_pols=$(vtr_policies_csv "$new_info")
  if ! vtr_drift_ok "$new_dn" "$new_pols"; then
    printf '%s FAIL: heal minted an unexpected token (dn=%q policies=%q) — not writing it\n' \
      "$(date -Is)" "$new_dn" "$new_pols" >>"$log"
    return 1
  fi

  # Atomic replace: mktemp files are 0600 from birth; same-filesystem mv.
  tmp=$(mktemp "$HOME/.vault-token.XXXXXX")
  printf '%s' "$new_token" >"$tmp"
  mv "$tmp" "$HOME/.vault-token"

  # Anti-sprawl: revoke previous token-devvm-wizard tokens — each heal would
  # otherwise strand the prior periodic ADMIN token server-side for up to 32d.
  # The clobbering foreign token is deliberately NOT revoked: it may still back
  # the user's live login session, and it ages out on its own (7d for OIDC).
  local sweep="accessor sweep skipped (list denied)" accessors a a_info revoked=0
  new_acc=$(vtr_accessor "$new_info")
  if [ -n "$new_acc" ] && accessors=$(VAULT_TOKEN="$new_token" vault list -format=json auth/token/accessors 2>/dev/null); then
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      a_info=$(VAULT_TOKEN="$new_token" vault token lookup -format=json -accessor "$a" 2>/dev/null) || continue
      if vtr_is_stale_periodic "$a_info" "$new_acc"; then
        VAULT_TOKEN="$new_token" vault token revoke -accessor "$a" >/dev/null 2>&1 && revoked=$((revoked + 1))
      fi
    done < <(printf '%s' "$accessors" | jq -r '.[]')
    sweep="revoked $revoked stale periodic token(s)"
  fi

  printf '%s HEALED: re-minted periodic token from foreign dn=%q (%s)\n' \
    "$(date -Is)" "$foreign_dn" "$sweep" >>"$log"
}
```

- [ ] **Step 2: Rewire the drift branch in `vtr_main`**

Replace this exact block (comment + if):

```bash
  # Drift guard (added 2026-06-07): the renewer must NOT keep a FOREIGN token alive.
  # On 2026-06-05 a stray `vault login -method=kubernetes` overwrote ~/.vault-token
  # with a read-only woodpecker token, and this script then silently renewed THAT
  # for two days — masking the loss of write access. So before renewing, confirm
  # the token is our periodic admin token; if it has drifted, fail loudly (systemd
  # marks the unit failed) instead of keeping someone else's token alive.
  if ! vtr_drift_ok "$dn" "$pols"; then
    printf '%s DRIFT: ~/.vault-token is dn=%q policies=%q (expected dn=%q with %q). Refusing to renew a foreign token. Re-mint: vault login -method=oidc && vault token create -orphan -period=768h -policy=vault-admin -policy=sops-admin -display-name=devvm-wizard -field=token > ~/.vault-token && chmod 600 ~/.vault-token\n' \
      "$(date -Is)" "$dn" "$pols" "$EXPECTED_DN" "$REQUIRED_POLICY" >>"$log"
    exit 1
  fi
```

with:

```bash
  # Drift guard (2026-06-07) + self-heal (2026-07-03): the renewer must not
  # keep a FOREIGN token alive (on 2026-06-05 a stray kubernetes login was
  # silently renewed for two days, masking lost write access). But detect-only
  # drift proved worse in practice: an OIDC login — which the infra docs
  # prescribe before applies — clobbers this file too, and the resulting DRIFT
  # failures went unnoticed for weeks while access degraded to a 7-day token
  # (the weekly-expiry loop). On drift we now ATTEMPT to heal (see vtr_heal):
  # re-mint the periodic token with the clobbering token's own authority.
  # Vault's authz keeps the old guarantee — a token that couldn't legitimately
  # hold vault-admin is denied the mint, and we still fail loud.
  if ! vtr_drift_ok "$dn" "$pols"; then
    vtr_heal "$dn" "$log" || exit 1
    exit 0
  fi
```

- [ ] **Step 3: Syntax + lint + regression check**

Run: `bash -n scripts/vault-token-renew.sh && bash scripts/test-vault-token-renew.sh; command -v shellcheck >/dev/null && shellcheck scripts/vault-token-renew.sh`
Expected: syntax OK, `25 passed, 0 failed`; shellcheck (if installed) reports nothing new.

- [ ] **Step 4: Commit**

```bash
git $GCFLAGS add scripts/vault-token-renew.sh
git $GCFLAGS commit -m "vault-token-renew: self-heal the periodic token on admin-capable clobber

Viktor asked for 'vault login -method=oidc' to work seamlessly: the OIDC
login the docs prescribe kept clobbering ~/.vault-token with a 7-day token,
and detect-only DRIFT failures went unnoticed for weeks (weekly-expiry
loop, twice in June). On drift the renewer now re-mints the periodic token
with the clobbering token's own authority (Vault's 403 is the judge — no
policy guessing), sanity-checks it, replaces the file atomically, and
revokes stale token-devvm-wizard leftovers. Weak/read-only clobbers still
fail loudly on purpose. Design: docs/plans/2026-07-03-vault-token-self-heal-design.md"
```

### Task 4: Docs — runbook + test-file header

**Files:**
- Modify: `docs/runbooks/vault-token-renew-devvm.md` (the `## Drift guard & recovery` section + the healthy-log-line note + `## Tests`)
- Modify: `scripts/test-vault-token-renew.sh` (header comment only)

- [ ] **Step 1: Replace the runbook's `## Drift guard & recovery` section with:**

```markdown
## Drift guard & self-heal

`~/.vault-token` is the Vault CLI's default token sink, so **any** `vault login`
overwrites it. Two confirmed clobber vectors:

1. `vault login -method=oidc` → replaces it with a 7-day OIDC token (the renewer
   can't push past the OIDC role's 7-day `token_max_ttl`). The infra docs
   prescribe this login before applies, so it recurs — it went unnoticed for
   weeks twice (2026-06-18→26, 2026-06-29→07-03) and read as "Vault expires
   weekly".
2. A stray `vault login -method=kubernetes` (e.g. a headless agent flow) →
   writes a read-only `kubernetes-woodpecker-default` token (can read Vault but
   **cannot** write `secret/*`). Happened 2026-06-05, unnoticed for two days.

Since 2026-07-03 the renewer **self-heals**
(`docs/plans/2026-07-03-vault-token-self-heal-design.md`). On a foreign token
it attempts the re-mint **with the clobbering token's own authority** and lets
Vault's authz decide:

- **Admin-capable clobber (OIDC login)** → re-mints the periodic token,
  sanity-checks it against the drift guard, atomically replaces
  `~/.vault-token`, revokes stale `token-devvm-wizard` leftovers
  (anti-sprawl), logs
  `HEALED: re-minted periodic token from foreign dn=… (revoked N stale periodic token(s))`
  and exits 0. The clobbering token is NOT revoked — it may still back a live
  login session; it ages out on its own.
- **Weak clobber (read-only k8s token)** → the mint is denied; logs
  `DRIFT: … heal denied, foreign token lacks create authority …; investigate what wrote it`
  and exits non-zero (unit `failed`). Deliberately loud: this signals a
  misbehaving agent flow — exactly the 2026-06-05 case.

**Manual recovery** is only needed for the weak-clobber case (the DRIFT log
line still contains the exact command) — run the
[mint/re-mint](#mint--re-mint-the-token) block.
```

- [ ] **Step 2: In the runbook's `## Health check` section**, after the "A healthy log line looks like…" sentence, add:

```markdown
After an OIDC login you'll instead see, at the next nightly run:
`<ts> HEALED: re-minted periodic token from foreign dn="oidc-…" (revoked N stale periodic token(s))` — that's the self-heal working as designed.
```

- [ ] **Step 3: In the runbook's `## Tests` section**, replace the first sentence with:

```markdown
`infra/scripts/test-vault-token-renew.sh` unit-tests the drift-guard decision,
the lookup-JSON parsers (including the exact 2026-06-05 woodpecker-clobber
case), and the self-heal's revoke filter (which stale periodic tokens a heal
may sweep).
```

- [ ] **Step 4: Update the test file's header comment** (lines 2–7) to:

```bash
# Unit tests for the pure functions in vault-token-renew.sh.
# Sources the script (vtr_main is guarded) and exercises (a) the drift-guard
# decision — is ~/.vault-token OUR periodic admin token (renew) or a foreign
# clobber (heal / fail loud)? — whose ABSENCE let the 2026-06-05 woodpecker
# clobber be silently renewed for two days, and (b) the self-heal's revoke
# filter — which stale token-devvm-wizard tokens a heal may sweep.
# Run: bash infra/scripts/test-vault-token-renew.sh
```

- [ ] **Step 5: Run tests once more, then commit**

Run: `bash scripts/test-vault-token-renew.sh`
Expected: `25 passed, 0 failed`.

```bash
git $GCFLAGS add docs/runbooks/vault-token-renew-devvm.md scripts/test-vault-token-renew.sh
git $GCFLAGS commit -m "vault-token-renew runbook: document the self-heal behavior

Drift guard section rewritten: admin-capable clobbers now self-heal at the
nightly run (HEALED log line); weak clobbers keep the loud DRIFT failure;
manual re-mint is only the weak-clobber recovery now."
```

### Task 5: Deploy + live verification (on devvm, as wizard)

**Files:** none (host deploy + live checks)

- [ ] **Step 1: Install from the worktree**

```bash
install -m 0755 ~/code/infra/.worktrees/vault-token-self-heal/scripts/vault-token-renew.sh ~/.local/bin/vault-token-renew
```

(Units unchanged — no `daemon-reload` needed.)

- [ ] **Step 2: Live case 1 — admin-capable clobber heals**

```bash
export VAULT_ADDR=https://vault.viktorbarzin.me
export XDG_RUNTIME_DIR=/run/user/$(id -u)
FAKE_ADMIN=$(vault token create -ttl=1h -policy=vault-admin -policy=sops-admin -display-name=fake-oidc -field=token)
printf '%s' "$FAKE_ADMIN" > ~/.vault-token
systemctl --user start vault-token-renew.service; echo "exit=$?"
tail -1 ~/.local/state/vault-token-renew.log
vault token lookup | grep -E 'display_name|period'
```

Expected: `exit=0`; log line `HEALED: re-minted periodic token from foreign dn="token-fake-oidc" (revoked N stale periodic token(s))` with N ≥ 1 (the pre-clobber periodic token is itself swept as stale — by design — along with any strays from the June 26 / July 3 manual re-mints); lookup shows `display_name token-devvm-wizard`, `period 768h`. Note: `FAKE_ADMIN` is a child of the swept old token, so the cascade revokes it too — no cleanup needed.

- [ ] **Step 3: Verify exactly ONE periodic token remains server-side**

```bash
for a in $(vault list -format=json auth/token/accessors | jq -r '.[]'); do
  vault token lookup -format=json -accessor "$a" 2>/dev/null \
    | jq -r 'select(.data.display_name=="token-devvm-wizard") | .data.accessor'
done
```

Expected: exactly one line, matching `vault token lookup -format=json | jq -r .data.accessor`.

- [ ] **Step 4: Live case 2 — weak clobber stays a loud failure**

```bash
GOOD=$(cat ~/.vault-token)
FAKE_WEAK=$(vault token create -ttl=10m -policy=default -display-name=fake-weak -field=token)
printf '%s' "$FAKE_WEAK" > ~/.vault-token
systemctl --user start vault-token-renew.service; echo "exit=$?"
systemctl --user is-failed vault-token-renew.service
tail -1 ~/.local/state/vault-token-renew.log
printf '%s' "$GOOD" > ~/.vault-token && chmod 600 ~/.vault-token
vault token revoke "$FAKE_WEAK" >/dev/null
```

Expected: `exit=1` (start reports the oneshot failure), `is-failed` prints `failed`, log line `DRIFT: ~/.vault-token is dn="token-fake-weak" — heal denied, foreign token lacks create authority (… permission denied …); investigate what wrote it. Manual re-mint: …`.

- [ ] **Step 5: Happy path still green**

```bash
systemctl --user start vault-token-renew.service; echo "exit=$?"
tail -1 ~/.local/state/vault-token-renew.log
```

Expected: `exit=0`, log `OK renewed (dn=token-devvm-wizard ttl=2764800s)`.

### Task 6: Land on master + cleanup

- [ ] **Step 1: Merge latest master into the branch, re-verify, push**

```bash
cd ~/code/infra/.worktrees/vault-token-self-heal
git $GCFLAGS fetch forgejo
git $GCFLAGS merge forgejo/master
bash scripts/test-vault-token-renew.sh
git $GCFLAGS push forgejo HEAD:master
```

Expected: clean merge (or already up to date), `25 passed, 0 failed`, push accepted. Non-fast-forward → fetch, merge, push again.

- [ ] **Step 2: Watch CI to completion**

The push fires the infra Woodpecker `default.yml` (terragrunt apply for changed stacks). This change touches only `scripts/` + `docs/` → expect a fast success / no-op apply. Check (Forgejo-forge infra repo = Woodpecker repo id 82):

```bash
export VAULT_ADDR=https://vault.viktorbarzin.me
vault kv get -format=json secret/ci/global | jq -r '.data.data | keys[]'   # find the woodpecker admin token key
WP_TOKEN=$(vault kv get -field=<that-key> secret/ci/global)
curl -s -H "Authorization: Bearer $WP_TOKEN" 'https://ci.viktorbarzin.me/api/repos/82/pipelines?perPage=1' | jq '.[0] | {number, status, commit: .commit[0:8]}'
```

Expected: the pipeline for the pushed commit reaches `status: "success"` (poll until terminal). If it fails, fix before proceeding.

- [ ] **Step 3: Remove worktree + branch, reconcile main checkout**

```bash
git -C ~/code/infra $GCFLAGS worktree remove .worktrees/vault-token-self-heal
git -C ~/code/infra $GCFLAGS branch -d wizard/vault-token-self-heal
git -C ~/code/infra status --porcelain   # expect clean before pulling
git -C ~/code/infra $GCFLAGS pull --ff-only forgejo master
```

Expected: worktree gone, branch deleted (already merged), main checkout fast-forwards to the landed commit.

### Task 7: Memory + wrap-up

- [ ] **Step 1: Update the stale memories** (they say the drift guard is detect-only / recovery is manual):

```bash
homelab memory recall "vault periodic token renewer drift"   # confirm ids 4204, 4211, 7121 still say detect-only
homelab memory update 4211 "<original gotcha content, amended: since 2026-07-03 the renewer SELF-HEALS admin-capable clobbers at its nightly run (re-mints the periodic token with the clobbering token's authority + revokes stale token-devvm-wizard leftovers; weak clobbers still fail loudly). An OIDC login on devvm is now harmless. Design: infra docs/plans/2026-07-03-vault-token-self-heal-design.md>"
homelab memory update 7121 "<original content, amended: PLAYBOOK OBSOLETE for admin clobbers — self-heal shipped 2026-07-03; manual re-mint only needed for weak/read-only clobbers>"
```

(Fetch each memory's current text first and preserve it — amend, don't replace wholesale.)

- [ ] **Step 2: End-of-task extraction** — dispatch the standard M.3 memory-mining subagent per `~/.claude/rules/execution.md`, then give the final summary.

---

## Plan self-review (done at write time)

- **Spec coverage**: heal-on-admin-clobber (T3), loud-fail-on-weak (T3 + live T5.4), no-revoke-foreign (T3 comment + design decision 4), anti-sprawl sweep + fail-safe filter (T2/T3, live T5.3), minted-token sanity + atomic write (T3), unit tests (T1/T2), runbook (T4), deploy + live sim (T5), memory updates (T7). ✓
- **Placeholders**: `<that-key>` in T6.2 is a deliberate discovery step (key name verified live from Vault, not invented). No other TBDs. ✓
- **Name consistency**: `vtr_accessor`, `vtr_is_stale_periodic`, `vtr_heal`, `EXPECTED_DN` match across tasks; test count 17→25 consistent (8 new cases). ✓
