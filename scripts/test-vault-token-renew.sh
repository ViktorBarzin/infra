#!/usr/bin/env bash
# Unit tests for the pure functions in vault-token-renew.sh.
# Sources the script (vtr_main is guarded) and exercises (a) the drift-guard
# decision — is ~/.vault-token OUR periodic admin token (renew) or a foreign
# clobber (heal / fail loud)? — whose ABSENCE let the 2026-06-05 woodpecker
# clobber be silently renewed for two days, and (b) the self-heal's revoke
# filter — which stale token-devvm-wizard tokens a heal may sweep.
# Run: bash infra/scripts/test-vault-token-renew.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/vault-token-renew.sh"

pass=0 fail=0
ok() {  # <description> <cmd...> — expects the command to succeed (renew-OK)
  if "${@:2}"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL: %s — expected OK, got refuse\n' "$1"
  fi
}
no() {  # <description> <cmd...> — expects the command to fail (drift, refuse)
  if "${@:2}"; then
    fail=$((fail + 1)); printf 'FAIL: %s — expected DRIFT, got OK\n' "$1"
  else pass=$((pass + 1)); fi
}
eq() {  # <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL: %s — expected [%s] got [%s]\n' "$1" "$2" "$3"
  fi
}

# --- vtr_drift_ok: ONLY our periodic admin token (right name AND vault-admin) renews ---
ok "our token renews"                vtr_drift_ok token-devvm-wizard "default,sops-admin,vault-admin"
ok "vault-admin anywhere in list"    vtr_drift_ok token-devvm-wizard "default,vault-admin"
ok "policy order irrelevant"         vtr_drift_ok token-devvm-wizard "vault-admin,default"
no "woodpecker clobber refused"      vtr_drift_ok kubernetes-woodpecker-default "ci,default,terraform-state"
no "oidc token (admin but wrong dn)" vtr_drift_ok oidc-vbarzin "default,sops-admin,vault-admin"
no "right name, no vault-admin"      vtr_drift_ok token-devvm-wizard "default,sops-admin"
no "empty display_name"              vtr_drift_ok "" "vault-admin"
no "empty policies"                  vtr_drift_ok token-devvm-wizard ""
no "no substring false-positive"     vtr_drift_ok token-devvm-wizard "default,vault-admin-ro"

# --- vtr_display_name / vtr_policies_csv: parse real `vault token lookup -format=json` ---
LOOKUP_OURS='{"data":{"display_name":"token-devvm-wizard","policies":["default","sops-admin","vault-admin"],"identity_policies":null}}'
LOOKUP_OIDC='{"data":{"display_name":"oidc-vbarzin","policies":["default"],"identity_policies":["sops-admin","vault-admin"]}}'
LOOKUP_WP='{"data":{"display_name":"kubernetes-woodpecker-default","policies":["ci","default","terraform-state"],"identity_policies":[]}}'
eq "dn ours"  "token-devvm-wizard" "$(vtr_display_name "$LOOKUP_OURS")"
eq "dn oidc"  "oidc-vbarzin"       "$(vtr_display_name "$LOOKUP_OIDC")"
eq "pols ours"                       "default,sops-admin,vault-admin" "$(vtr_policies_csv "$LOOKUP_OURS")"
eq "pols oidc merges token+identity" "default,sops-admin,vault-admin" "$(vtr_policies_csv "$LOOKUP_OIDC")"
eq "pols woodpecker"                 "ci,default,terraform-state"     "$(vtr_policies_csv "$LOOKUP_WP")"

# --- parse + decide end-to-end (the real lookup-JSON -> renew/refuse path) ---
ok "ours: parse+decide renews"        vtr_drift_ok "$(vtr_display_name "$LOOKUP_OURS")" "$(vtr_policies_csv "$LOOKUP_OURS")"
no "woodpecker: parse+decide refused" vtr_drift_ok "$(vtr_display_name "$LOOKUP_WP")"   "$(vtr_policies_csv "$LOOKUP_WP")"
no "oidc: parse+decide refused"       vtr_drift_ok "$(vtr_display_name "$LOOKUP_OIDC")" "$(vtr_policies_csv "$LOOKUP_OIDC")"

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
