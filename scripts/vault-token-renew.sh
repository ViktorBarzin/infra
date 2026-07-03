#!/usr/bin/env bash
# Renew the long-lived PERIODIC Vault/OpenBao token stored in ~/.vault-token.
#
# Background: wizard@devvm used to hold a 7-day OIDC login token (re-auth weekly
# via `vault login -method=oidc`). On 2026-06-05 that was replaced with a
# periodic, orphan token so it never expires. Periodic tokens have no max-TTL;
# they only need renewing within each `period` (768h / 32d here). This unit
# renews daily, so the token stays alive indefinitely with huge margin. If the
# box is ever decommissioned and this stops running, the token self-expires
# within ~32 days (unlike a root token, which would live forever).
#
# Token was minted with (vault-admin = path "*" sudo; sops-admin = transit for SOPS):
#   vault token create -orphan -period=768h \
#     -policy=vault-admin -policy=sops-admin -display-name=devvm-wizard
# To recreate if ever lost: `vault login -method=oidc`, run the above with
#   `-field=token > ~/.vault-token`, then `chmod 600 ~/.vault-token`.
#
# Source of truth: infra/scripts/vault-token-renew.sh (deployed to
# ~/.local/bin/vault-token-renew). Driven by the systemd USER units
# vault-token-renew.{service,timer}. Deploy + recovery runbook:
# infra/docs/runbooks/vault-token-renew-devvm.md

EXPECTED_DN="token-devvm-wizard"
REQUIRED_POLICY="vault-admin"

# vtr_display_name <lookup-json> -> display_name (empty if absent).
vtr_display_name() {
  printf '%s' "$1" | jq -r '.data.display_name // ""'
}

# vtr_policies_csv <lookup-json> -> comma-joined token policies + identity policies.
# Both are merged because a token minted via OIDC carries vault-admin only in
# identity_policies, while .data.policies shows just [default] (misleading on its
# own — see memory id=4211). Our periodic token carries them as token policies.
vtr_policies_csv() {
  printf '%s' "$1" | jq -r '((.data.policies // []) + (.data.identity_policies // [])) | join(",")'
}

# vtr_drift_ok <display_name> <policies-csv> -> 0 if this is OUR periodic admin
# token (right display name AND vault-admin present), 1 otherwise. The comma
# fencing makes the policy match exact (so "vault-admin-ro" never matches).
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

vtr_main() {
  set -euo pipefail
  export PATH="/usr/local/bin:/usr/bin:/bin:${PATH:-}"
  export VAULT_ADDR="${VAULT_ADDR:-https://vault.viktorbarzin.me}"

  local log info dn pols out ttl
  log="${XDG_STATE_HOME:-$HOME/.local/state}/vault-token-renew.log"
  mkdir -p "$(dirname "$log")"

  if ! info=$(vault token lookup -format=json 2>&1); then
    printf '%s FAIL: token lookup: %s\n' "$(date -Is)" "$info" >>"$log"
    exit 1
  fi
  dn=$(vtr_display_name "$info")
  pols=$(vtr_policies_csv "$info")

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
