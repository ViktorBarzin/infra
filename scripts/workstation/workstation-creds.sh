#!/usr/bin/env bash
# workstation-creds: keep a devvm user's hand-made credential files in Vault and
# put them back on a new box (docs/plans/2026-11-11-disposable-devvm.md).
#
# One KV secret per file, at secret/workstation/<user>/files/<slug>:
#   path         the file, relative to the home: .ssh/id_ed25519
#   mode         its octal mode: 0600
#   content_b64  the file itself, base64
#   ref          instead of content_b64: <kv-path>#<field> of a secret that
#                already holds this file, such as secret/opnsense#ssh_private_key.
#                Restored as that field plus a final newline, so a rotation in
#                the canonical place reaches the next restore.
# The slug is the path with / as __ and spaces as _; only path says where the
# file goes.
#
#   workstation-creds capture <user> <path>...            store live files (sudo)
#   workstation-creds capture-ref <user> <path> <kv>#<f>  store a pointer
#   workstation-creds list <user>                         paths and modes, no values
#   workstation-creds restore <user> [--into DIR]
#
# restore writes only files that are absent, never replacing one that is there,
# and runs every write as the user (runuser), so a link the user planted reaches
# only what they could reach. With --into it writes under DIR as the caller
# instead, which is how a drill checks a restore without touching a home.
# Needs a Vault token that can read the user's path (an admin's); nothing run
# as the user ever sees it. Values are never printed. Called by t3-provision-users.sh (restore_user_credentials).
set -uo pipefail
export VAULT_ADDR="${VAULT_ADDR:-https://vault.viktorbarzin.me}"

wc_die() { echo "workstation-creds: $*" >&2; exit 1; }
wc_base() { printf 'secret/workstation/%s/files' "$1"; }

wc_safe_path() {  # 0 when $1 is a plain relative path inside the home
  case "$1" in
    ""|/*|..|../*|*/..|*/../*|.|./*) return 1 ;;
  esac
  [[ "$1" != *$'\n'* ]]
}
wc_safe_mode() { [[ "$1" =~ ^0?[0-7]{3}$ ]]; }
wc_slug() {  # path -> KV key name
  local s="${1//\//__}"; s="${s// /_}"
  [[ "$s" =~ ^[A-Za-z0-9._@+-]+$ ]] || return 1
  printf '%s' "$s"
}
wc_home() {
  if [[ -n "${WORKSTATION_CREDS_HOME:-}" ]]; then printf '%s' "$WORKSTATION_CREDS_HOME"; return; fi
  getent passwd "$1" | cut -d: -f6
}
wc_mode_of() { printf '0%s' "$(stat -c %a "$1")" | sed -E 's/^0([0-7]{4})$/\1/'; }

wc_capture() {
  local user="$1" home rel f slug mode; shift
  home="$(wc_home "$user")"; [[ -n "$home" ]] || wc_die "no home for $user"
  (($#)) || wc_die "capture: name at least one path"
  for rel in "$@"; do
    wc_safe_path "$rel" || wc_die "refusing path $rel: must be relative to the home"
    slug="$(wc_slug "$rel")" || wc_die "refusing path $rel: characters a KV key cannot carry"
    f="$home/$rel"
    [[ -f "$f" && ! -L "$f" ]] || wc_die "$f is not a regular file"
    mode="$(wc_mode_of "$f")"
    base64 -w0 "$f" | vault kv put "$(wc_base "$user")/$slug" path="$rel" mode="$mode" content_b64=- >/dev/null \
      || wc_die "vault write failed for $rel"
    echo "stored $rel ($mode) -> $(wc_base "$user")/$slug"
  done
}

wc_capture_ref() {
  local user="$1" rel="$2" ref="$3" home f slug mode=0600
  [[ "$ref" =~ ^secret/[A-Za-z0-9._/-]+#[A-Za-z0-9._-]+$ ]] || wc_die "ref must be secret/<path>#<field>, got $ref"
  wc_safe_path "$rel" || wc_die "refusing path $rel: must be relative to the home"
  slug="$(wc_slug "$rel")" || wc_die "refusing path $rel: characters a KV key cannot carry"
  vault kv get -field="${ref#*#}" "${ref%%#*}" >/dev/null 2>&1 || wc_die "cannot read $ref"
  home="$(wc_home "$user")"; f="$home/$rel"
  [[ -f "$f" ]] && mode="$(wc_mode_of "$f")"
  vault kv put "$(wc_base "$user")/$slug" path="$rel" mode="$mode" ref="$ref" >/dev/null \
    || wc_die "vault write failed for $rel"
  echo "stored $rel ($mode) -> $(wc_base "$user")/$slug, pointing at $ref"
}

wc_slugs() {  # the user's stored slugs, one per line; nothing when none
  vault kv list -format=json "$(wc_base "$1")" 2>/dev/null | jq -r '.[] | select(endswith("/") | not)' 2>/dev/null
}

wc_list() {
  local user="$1" slug
  while IFS= read -r slug; do
    vault kv get -format=json "$(wc_base "$user")/$slug" 2>/dev/null |
      jq -r '.data.data | "\(.mode) \(.path)" + (if .ref then " (ref \(.ref))" else "" end)'
  done < <(wc_slugs "$user")
}

wc_restore() {
  local user="$1" into="" root slug data rel mode ref b64 dst
  local restored=0 kept=0 skipped=0
  shift
  if [[ "${1:-}" == --into ]]; then into="${2:?--into needs a directory}"; fi
  vault token lookup >/dev/null 2>&1 || wc_die "no Vault access (needs a token that can read $(wc_base "$user"))"
  if [[ -n "$into" ]]; then
    mkdir -p "$into"; root="$into"
    as() { "$@"; }
  else
    root="$(wc_home "$user")"
    [[ -n "$root" && -d "$root" ]] || wc_die "no home for $user"
    # runuser hands on the caller's environment, and a user can read the
    # environment of any process running as them, so the admin token that
    # reads Vault here is taken out before runuser starts.
    as() { env -u VAULT_TOKEN runuser -u "$user" -- "$@"; }
  fi
  local slugs; slugs="$(wc_slugs "$user")"
  if [[ -z "$slugs" ]]; then echo "workstation-creds: nothing stored for $user"; return 0; fi
  while IFS= read -r slug; do
    data="$(vault kv get -format=json "$(wc_base "$user")/$slug" 2>/dev/null | jq -c '.data.data')" || data=""
    rel="$(jq -r '.path // ""' <<<"$data" 2>/dev/null)"
    mode="$(jq -r '.mode // ""' <<<"$data" 2>/dev/null)"
    ref="$(jq -r '.ref // ""' <<<"$data" 2>/dev/null)"
    if ! wc_safe_path "$rel" || ! wc_safe_mode "$mode"; then
      echo "skipped $slug: unsafe path or mode in Vault"; skipped=$((skipped + 1)); continue
    fi
    dst="$root/$rel"
    if [[ -e "$dst" || -L "$dst" ]]; then kept=$((kept + 1)); continue; fi
    if [[ -n "$ref" ]]; then
      b64="$(v="$(vault kv get -field="${ref#*#}" "${ref%%#*}" 2>/dev/null)" && [[ -n "$v" ]] && printf '%s\n' "$v" | base64 -w0)" || b64=""
    else
      b64="$(jq -r '.content_b64 // ""' <<<"$data")"
    fi
    if [[ -z "$b64" ]]; then echo "skipped $rel: no content (ref unreadable?)"; skipped=$((skipped + 1)); continue; fi
    # umask 077 makes every directory mkdir -p creates 0700, like ~/.ssh and ~/.gnupg want.
    if printf '%s' "$b64" | as sh -c 'umask 077; mkdir -p "$(dirname "$1")" || exit 1; t="$1.tmp.$$"
         if base64 -d > "$t" && chmod "$2" "$t" && mv -f "$t" "$1"; then exit 0; fi
         rm -f "$t"; exit 1' _ "$dst" "$mode"; then
      echo "restored $rel ($mode)"; restored=$((restored + 1))
    else
      echo "skipped $rel: write failed"; skipped=$((skipped + 1))
    fi
  done <<<"$slugs"
  echo "workstation-creds: $user restored $restored, kept $kept, skipped $skipped"
}

wc_main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    capture)     [[ $# -ge 2 ]] || wc_die "usage: capture <user> <path>..."; wc_capture "$@" ;;
    capture-ref) [[ $# -eq 3 ]] || wc_die "usage: capture-ref <user> <path> <kv-path>#<field>"; wc_capture_ref "$@" ;;
    list)        [[ $# -eq 1 ]] || wc_die "usage: list <user>"; wc_list "$1" ;;
    restore)     [[ $# -ge 1 ]] || wc_die "usage: restore <user> [--into DIR]"; wc_restore "$@" ;;
    *) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; [[ -z "$cmd" || "$cmd" == -h || "$cmd" == --help ]] ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  wc_main "$@"
fi
