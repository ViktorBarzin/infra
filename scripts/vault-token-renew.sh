#!/usr/bin/env bash
# Renew the long-lived PERIODIC Vault/OpenBao token stored in ~/.vault-token.
#
# Background: a devvm user used to hold a 7-day OIDC login token (re-auth weekly
# via `vault login -method=oidc`, whose role caps token_max_ttl at 168h). That
# is replaced with a periodic, orphan token so it never expires. Periodic tokens
# have no max-TTL; they only need renewing within each `period` (768h / 32d
# here). This unit renews daily, so the token stays alive indefinitely with huge
# margin. If the box is ever decommissioned and this stops running, the token
# self-expires within ~32 days (unlike a root token, which would live forever).
#
# MULTI-USER: this one script is deployed per devvm user. Each user's
# ~/.vault-token is a periodic orphan token scoped to THAT user's own Vault
# entitlement — never another user's. The scope is keyed on the OS user in
# vtr_resolve_config below, so the systemd units stay identical across users
# (ExecStart=%h/.local/bin/vault-token-renew). Per-user tokens:
#   wizard: policies vault-admin (path "*" sudo) + sops-admin (SOPS transit) —
#           can self-heal a clobber (see vtr_heal) because it holds create authority.
#   emo:    policies default + personal-emo (own secret tree secret/emo/*) —
#           matches emo's OIDC entitlement; cannot mint orphan tokens, so a
#           clobber can't self-heal and instead fails loud (rare: emo doesn't
#           `vault login`). Re-mint is an admin action (see runbook).
#
# To mint/recreate a user's token (admin, one-time — needs create authority):
#   vault token create -orphan -period=768h \
#     -policy=<p1> -policy=<p2> -display-name=devvm-<user> \
#     -field=token > ~<user>/.vault-token && chmod 600 ~<user>/.vault-token
# (Vault prefixes the display name, so it becomes token-devvm-<user>.)
#
# Source of truth: infra/scripts/vault-token-renew.sh (deployed to
# ~/.local/bin/vault-token-renew). Driven by the systemd USER units
# vault-token-renew.{service,timer}. Deploy + recovery runbook:
# infra/docs/runbooks/vault-token-renew-devvm.md

# vtr_resolve_config [os-user] -> sets, for that user, the globals the renewer
# and drift guard read: EXPECTED_DN (token-devvm-<user>), REQUIRED_POLICY (the
# distinctive policy that marks the token as OURS — never `default`, which every
# token carries), VTR_MINT_POLICIES (array, passed as -policy= flags on mint),
# and VTR_MINT_DISPLAY_NAME. Returns 1 for an unmapped user so the caller aborts
# rather than minting/renewing an unknown scope. Called at runtime from
# vtr_main; the unit test calls it directly per user.
# shellcheck disable=SC2120  # optional arg is intentional: tests pass a user, main uses $(id -un)
vtr_resolve_config() {
  local u="${1:-$(id -un)}"
  case "$u" in
    wizard)
      VTR_MINT_POLICIES=(vault-admin sops-admin)  # path "*" sudo + SOPS transit
      REQUIRED_POLICY="vault-admin"
      ;;
    emo)
      VTR_MINT_POLICIES=(default personal-emo)    # emo's own tree only (secret/emo/*)
      REQUIRED_POLICY="personal-emo"
      ;;
    *)
      return 1
      ;;
  esac
  EXPECTED_DN="token-devvm-${u}"
  VTR_MINT_DISPLAY_NAME="devvm-${u}"
  return 0
}

# vtr_display_name <lookup-json> -> display_name (empty if absent).
vtr_display_name() {
  printf '%s' "$1" | jq -r '.data.display_name // ""'
}

# vtr_policies_csv <lookup-json> -> comma-joined token policies + identity policies.
# Both are merged because a token minted via OIDC carries its extra policies only
# in identity_policies, while .data.policies shows just [default] (misleading on
# its own — see memory id=4211). Our periodic token carries them as token policies.
vtr_policies_csv() {
  printf '%s' "$1" | jq -r '((.data.policies // []) + (.data.identity_policies // [])) | join(",")'
}

# vtr_drift_ok <display_name> <policies-csv> -> 0 if this is OUR periodic token
# (right display name AND this user's REQUIRED_POLICY present), 1 otherwise. The
# comma fencing makes the policy match exact (so "vault-admin-ro" never matches
# a REQUIRED_POLICY of "vault-admin"). Reads EXPECTED_DN / REQUIRED_POLICY.
vtr_drift_ok() {
  local dn="$1" pols="$2"
  [ "$dn" = "$EXPECTED_DN" ] || return 1
  printf ',%s,' "$pols" | grep -q ",$REQUIRED_POLICY," || return 1
}

# vtr_accessor <lookup-json> -> the token accessor (empty if absent).
vtr_accessor() {
  printf '%s' "$1" | jq -r '.data.accessor // ""'
}

# vtr_is_stale_periodic <lookup-json> <keep-accessor> -> 0 if this lookup
# describes one of OUR periodic tokens (display name matches EXPECTED_DN) that is
# NOT the one to keep — i.e. a stale leftover a heal should revoke. 1 otherwise.
# Name-only on purpose (no policy check): anything named EXPECTED_DN that isn't
# the current token is garbage from a previous mint. An empty keep-accessor
# sweeps NOTHING (fail-safe: never revoke when we don't know which token is current).
vtr_is_stale_periodic() {
  local dn acc
  [ -n "${2:-}" ] || return 1
  dn=$(vtr_display_name "$1")
  acc=$(vtr_accessor "$1")
  [ "$dn" = "$EXPECTED_DN" ] || return 1
  [ -n "$acc" ] || return 1
  [ "$acc" != "$2" ]
}

# vtr_heal <foreign-dn> <log-file> -> 0 if ~/.vault-token was re-minted back to
# our periodic token using the foreign token's own authority, 1 if the heal was
# denied or failed (caller exits non-zero; the unit goes failed).
#
# Self-heal added 2026-07-03 (docs/plans/2026-07-03-vault-token-self-heal-design.md):
# an OIDC login — which the infra docs prescribe before applies — clobbers
# ~/.vault-token with a 7-day token, and detect-only drift left that unnoticed
# for weeks (the weekly-expiry loop). We ATTEMPT the re-mint with the
# clobbering token itself and let Vault's authz decide — a read-only clobber
# (the 2026-06-05 woodpecker incident), or any token without orphan-create
# authority (e.g. a non-admin user's OIDC token), is denied the mint and stays a
# loud failure, because it signals a misbehaving flow that someone should look at.
vtr_heal() {
  local foreign_dn="$1" log="$2"
  local errf new_token new_info new_dn new_pols new_acc tmp mint_flags mint_hint
  mint_flags="${VTR_MINT_POLICIES[*]/#/-policy=}"  # "-policy=a -policy=b" (log/hint only)
  mint_hint="vault login -method=oidc && vault token create -orphan -period=768h ${mint_flags} -display-name=${VTR_MINT_DISPLAY_NAME} -field=token > ~/.vault-token && chmod 600 ~/.vault-token"
  errf=$(mktemp)
  if ! new_token=$(vault token create -orphan -period=768h \
        "${VTR_MINT_POLICIES[@]/#/-policy=}" -display-name="$VTR_MINT_DISPLAY_NAME" \
        -field=token 2>"$errf") || [ -z "$new_token" ]; then
    printf '%s DRIFT: ~/.vault-token is dn=%q — heal denied, foreign token lacks create authority (%s); investigate what wrote it. Manual re-mint: %s\n' \
      "$(date -Is)" "$foreign_dn" "$(tr '\n' ' ' <"$errf")" "$mint_hint" >>"$log"
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

  # Anti-sprawl: revoke previous EXPECTED_DN tokens — each heal would otherwise
  # strand the prior periodic token server-side for up to 32d. The clobbering
  # foreign token is deliberately NOT revoked: it may still back the user's live
  # login session, and it ages out on its own (7d for OIDC).
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

vtr_main() {
  set -euo pipefail
  export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"
  export VAULT_ADDR="${VAULT_ADDR:-https://vault.viktorbarzin.me}"

  local log info dn pols out ttl
  log="${XDG_STATE_HOME:-$HOME/.local/state}/vault-token-renew.log"
  mkdir -p "$(dirname "$log")"

  # Resolve this OS user's token identity + policy scope. Unmapped user -> abort
  # loud (never mint/renew an unknown scope).
  if ! vtr_resolve_config; then
    printf '%s FAIL: no policy mapping for OS user %q — add a case to vtr_resolve_config in vault-token-renew.sh\n' \
      "$(date -Is)" "$(id -un)" >>"$log"
    exit 1
  fi

  if ! info=$(vault token lookup -format=json 2>&1); then
    printf '%s FAIL: token lookup: %s\n' "$(date -Is)" "$info" >>"$log"
    exit 1
  fi
  dn=$(vtr_display_name "$info")
  pols=$(vtr_policies_csv "$info")

  # Drift guard (2026-06-07) + self-heal (2026-07-03): the renewer must not
  # keep a FOREIGN token alive (on 2026-06-05 a stray kubernetes login was
  # silently renewed for two days, masking lost write access). But detect-only
  # drift proved worse in practice: an OIDC login — which the infra docs
  # prescribe before applies — clobbers this file too, and the resulting DRIFT
  # failures went unnoticed for weeks while access degraded to a 7-day token
  # (the weekly-expiry loop). On drift we now ATTEMPT to heal (see vtr_heal):
  # re-mint the periodic token with the clobbering token's own authority.
  # Vault's authz keeps the old guarantee — a token that couldn't legitimately
  # hold the required policy is denied the mint, and we still fail loud.
  if ! vtr_drift_ok "$dn" "$pols"; then
    vtr_heal "$dn" "$log" || exit 1
    exit 0
  fi

  # `vault token renew` with no argument renews the calling token (renew-self).
  # On success, log only the new TTL (never the raw JSON — it contains the token).
  if out=$(vault token renew -format=json 2>&1); then
    ttl=$(printf '%s' "$out" | jq -r '.auth.lease_duration' 2>/dev/null || echo '?')
    printf '%s OK renewed (dn=%s ttl=%ss)\n' "$(date -Is)" "$dn" "$ttl" >>"$log"
  else
    printf '%s FAIL: %s\n' "$(date -Is)" "$out" >>"$log"
    exit 1
  fi
}

# Run main only when executed directly, so the test can source the pure functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  vtr_main "$@"
fi
