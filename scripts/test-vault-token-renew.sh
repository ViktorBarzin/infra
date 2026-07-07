#!/usr/bin/env bash
# Unit tests for the pure functions in vault-token-renew.sh.
# Sources the script (vtr_main is guarded) and exercises (a) per-user scope
# resolution (vtr_resolve_config — the multi-user keying), (b) the drift-guard
# decision — is ~/.vault-token OUR periodic token (renew) or a foreign clobber
# (heal / fail loud)? — whose ABSENCE let the 2026-06-05 woodpecker clobber be
# silently renewed for two days, and (c) the self-heal's revoke filter — which
# stale token-devvm-<user> tokens a heal may sweep (and that it never sweeps
# another user's).
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

# --- vtr_resolve_config: per-user token identity + policy scope ---
ok "wizard user maps"                  vtr_resolve_config wizard
eq "wizard EXPECTED_DN"   "token-devvm-wizard"      "$EXPECTED_DN"
eq "wizard REQUIRED_POLICY" "vault-admin"           "$REQUIRED_POLICY"
eq "wizard mint display"  "devvm-wizard"            "$VTR_MINT_DISPLAY_NAME"
eq "wizard mint policies" "vault-admin sops-admin"  "${VTR_MINT_POLICIES[*]}"
ok "emo user maps"                     vtr_resolve_config emo
eq "emo EXPECTED_DN"      "token-devvm-emo"         "$EXPECTED_DN"
eq "emo REQUIRED_POLICY"  "personal-emo"            "$REQUIRED_POLICY"
eq "emo mint display"     "devvm-emo"               "$VTR_MINT_DISPLAY_NAME"
eq "emo mint policies"    "default personal-emo projects-emo" "${VTR_MINT_POLICIES[*]}"
no "unmapped user refused (no mint of unknown scope)" vtr_resolve_config nobody-xyz

# --- vtr_drift_ok (WIZARD context): ONLY our periodic token (right name AND vault-admin) renews ---
vtr_resolve_config wizard
ok "our token renews"                vtr_drift_ok token-devvm-wizard "default,sops-admin,vault-admin"
ok "vault-admin anywhere in list"    vtr_drift_ok token-devvm-wizard "default,vault-admin"
ok "policy order irrelevant"         vtr_drift_ok token-devvm-wizard "vault-admin,default"
no "woodpecker clobber refused"      vtr_drift_ok kubernetes-woodpecker-default "ci,default,terraform-state"
no "oidc token (admin but wrong dn)" vtr_drift_ok oidc-vbarzin "default,sops-admin,vault-admin"
no "right name, no vault-admin"      vtr_drift_ok token-devvm-wizard "default,sops-admin"
no "empty display_name"              vtr_drift_ok "" "vault-admin"
no "empty policies"                  vtr_drift_ok token-devvm-wizard ""
no "no substring false-positive"     vtr_drift_ok token-devvm-wizard "default,vault-admin-ro"

# --- vtr_drift_ok (EMO context): right name AND personal-emo; never another user's ---
vtr_resolve_config emo
ok "emo token renews"                vtr_drift_ok token-devvm-emo "default,personal-emo"
no "emo: oidc clobber (right pols, wrong dn)" vtr_drift_ok oidc-emil.barzin@gmail.com "default,personal-emo"
no "emo: right dn but only default"  vtr_drift_ok token-devvm-emo "default"
no "emo: personal-emo-ro no substring match"  vtr_drift_ok token-devvm-emo "default,personal-emo-ro"
no "emo ctx rejects wizard's token"  vtr_drift_ok token-devvm-wizard "default,sops-admin,vault-admin"

# --- vtr_display_name / vtr_policies_csv: parse real `vault token lookup -format=json` ---
LOOKUP_OURS='{"data":{"display_name":"token-devvm-wizard","policies":["default","sops-admin","vault-admin"],"identity_policies":null}}'
LOOKUP_OIDC='{"data":{"display_name":"oidc-vbarzin","policies":["default"],"identity_policies":["sops-admin","vault-admin"]}}'
LOOKUP_WP='{"data":{"display_name":"kubernetes-woodpecker-default","policies":["ci","default","terraform-state"],"identity_policies":[]}}'
eq "dn ours"  "token-devvm-wizard" "$(vtr_display_name "$LOOKUP_OURS")"
eq "dn oidc"  "oidc-vbarzin"       "$(vtr_display_name "$LOOKUP_OIDC")"
eq "pols ours"                       "default,sops-admin,vault-admin" "$(vtr_policies_csv "$LOOKUP_OURS")"
eq "pols oidc merges token+identity" "default,sops-admin,vault-admin" "$(vtr_policies_csv "$LOOKUP_OIDC")"
eq "pols woodpecker"                 "ci,default,terraform-state"     "$(vtr_policies_csv "$LOOKUP_WP")"

# --- parse + decide end-to-end (wizard context: the real lookup-JSON -> renew/refuse path) ---
vtr_resolve_config wizard
ok "ours: parse+decide renews"        vtr_drift_ok "$(vtr_display_name "$LOOKUP_OURS")" "$(vtr_policies_csv "$LOOKUP_OURS")"
no "woodpecker: parse+decide refused" vtr_drift_ok "$(vtr_display_name "$LOOKUP_WP")"   "$(vtr_policies_csv "$LOOKUP_WP")"
no "oidc: parse+decide refused"       vtr_drift_ok "$(vtr_display_name "$LOOKUP_OIDC")" "$(vtr_policies_csv "$LOOKUP_OIDC")"

# --- vtr_accessor: parse accessor out of lookup JSON ---
LOOKUP_NEW='{"data":{"display_name":"token-devvm-wizard","accessor":"acc-new","policies":["default","sops-admin","vault-admin"],"identity_policies":null}}'
eq "accessor parsed"          "acc-new" "$(vtr_accessor "$LOOKUP_NEW")"
eq "accessor absent -> empty" ""        "$(vtr_accessor '{"data":{"display_name":"x"}}')"

# --- vtr_is_stale_periodic (WIZARD context): the heal's revoke filter — ONLY old
# --- token-devvm-wizard tokens are swept; the just-minted token, foreign tokens,
# --- and anything with an unknown accessor are kept. An empty keep-accessor
# --- sweeps NOTHING (fail-safe).
vtr_resolve_config wizard
STALE_OURS='{"data":{"display_name":"token-devvm-wizard","accessor":"acc-old","policies":["default","sops-admin","vault-admin"]}}'
ok "older periodic token is stale"      vtr_is_stale_periodic "$STALE_OURS" "acc-new"
no "the just-minted token is kept"      vtr_is_stale_periodic "$LOOKUP_NEW" "acc-new"
no "foreign oidc token never swept"     vtr_is_stale_periodic "$LOOKUP_OIDC" "acc-new"
no "woodpecker token never swept"       vtr_is_stale_periodic "$LOOKUP_WP" "acc-new"
no "missing accessor never swept"       vtr_is_stale_periodic '{"data":{"display_name":"token-devvm-wizard"}}' "acc-new"
no "empty keep-accessor sweeps nothing" vtr_is_stale_periodic "$STALE_OURS" ""

# --- vtr_is_stale_periodic (EMO context): sweeps only emo's own; never wizard's ---
vtr_resolve_config emo
STALE_EMO='{"data":{"display_name":"token-devvm-emo","accessor":"acc-old","policies":["default","personal-emo"]}}'
ok "emo older periodic token is stale"  vtr_is_stale_periodic "$STALE_EMO" "acc-new"
no "emo ctx never sweeps wizard token"  vtr_is_stale_periodic "$STALE_OURS" "acc-new"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
