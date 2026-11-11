#!/usr/bin/env bash
# Tests for scripts/workstation/workstation-creds.sh, which keeps a devvm user's
# hand-made credential files in Vault and puts them back on a new box.
#
# Run: bash scripts/test-workstation-creds.sh
#
# Vault is a stand-in that keeps each KV secret as a JSON file under a temp
# directory and answers the few `vault kv` forms the script uses. runuser is a
# stand-in that runs the command as the caller.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS="$DIR/workstation/workstation-creds.sh"

pass=0 fail=0
eq() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (want [$2] got [$3])"; fi; }
ok() { if "${@:2}"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
no() { if "${@:2}"; then fail=$((fail+1)); echo "FAIL: $1"; else pass=$((pass+1)); fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/kv"
export KV_DIR="$tmp/kv"

cat > "$tmp/bin/vault" <<'EOF'
#!/usr/bin/env bash
# vault stand-in: secrets are $KV_DIR/<path>.json holding the data object.
set -euo pipefail
[[ "$1" == token && "$2" == lookup ]] && { [[ -n "${FAKE_VAULT_DENY:-}" ]] && exit 2; echo '{}'; exit 0; }
[[ "$1" == kv ]] || { echo "stub: unsupported $*" >&2; exit 9; }
verb="$2"; shift 2
fmt="" field=""
while [[ "$1" == -* ]]; do
  case "$1" in -format=*) fmt="${1#-format=}";; -field=*) field="${1#-field=}";; -mount=*) ;; esac; shift
done
p="$1"; shift
f="$KV_DIR/$p.json"
case "$verb" in
  put)
    obj='{}'
    for kvp in "$@"; do
      k="${kvp%%=*}" v="${kvp#*=}"
      [[ "$v" == - ]] && v="$(cat)"
      obj="$(jq --arg k "$k" --arg v "$v" '. + {($k): $v}' <<<"$obj")"
    done
    mkdir -p "$(dirname "$f")"; printf '%s' "$obj" > "$f" ;;
  get)
    [[ -f "$f" ]] || { echo "No value found at $p" >&2; exit 2; }
    if [[ -n "$field" ]]; then jq -j --arg k "$field" '.[$k]' "$f"
    else jq '{data: {data: .}}' "$f"; fi ;;
  list)
    d="$KV_DIR/$p"; d="${d%/}"
    [[ -d "$d" ]] || { echo "No value found at $p" >&2; exit 2; }
    ( cd "$d" && ls -A1 ) | sed 's/\.json$//' | jq -R . | jq -s . ;;
  *) echo "stub: unsupported kv $verb" >&2; exit 9 ;;
esac
EOF
printf '#!/usr/bin/env bash\n[[ "$1" == -u ]] && shift 2\n[[ "$1" == -- ]] && shift\nexec "$@"\n' > "$tmp/bin/runuser"
chmod +x "$tmp/bin/vault" "$tmp/bin/runuser"
export PATH="$tmp/bin:$PATH"

me="$(id -un)"
home="$tmp/home"; mkdir -p "$home/.ssh" "$home/.config/gh" "$home/.gnupg/private-keys-v1.d"
printf 'PRIVATE-SSH-SECRET\n' > "$home/.ssh/id_ed25519"; chmod 600 "$home/.ssh/id_ed25519"
printf 'ssh-ed25519 AAAA pub\n' > "$home/.ssh/id_ed25519.pub"; chmod 644 "$home/.ssh/id_ed25519.pub"
printf 'github.com:\n    oauth_token: GH-SECRET\n' > "$home/.config/gh/hosts.yml"; chmod 600 "$home/.config/gh/hosts.yml"
printf '\x00\x01binary-gpg\xff' > "$home/.gnupg/private-keys-v1.d/ABC.key"; chmod 600 "$home/.gnupg/private-keys-v1.d/ABC.key"

run() { WORKSTATION_CREDS_HOME="$home" bash "$CREDS" "$@"; }

# --- capture ---------------------------------------------------------------
out="$(run capture "$me" .ssh/id_ed25519 .ssh/id_ed25519.pub .config/gh/hosts.yml .gnupg/private-keys-v1.d/ABC.key 2>&1)"
ok "capture succeeds" test $? -eq 0
no "capture never prints a secret" grep -qE 'PRIVATE-SSH-SECRET|GH-SECRET' <<<"$out"
ok "one KV secret per file" test -f "$KV_DIR/secret/workstation/$me/files/.ssh__id_ed25519.json"
eq "the secret records the path" ".ssh/id_ed25519" "$(jq -r .path "$KV_DIR/secret/workstation/$me/files/.ssh__id_ed25519.json")"
eq "the secret records the mode" "0600" "$(jq -r .mode "$KV_DIR/secret/workstation/$me/files/.ssh__id_ed25519.json")"
eq "a public key keeps its mode" "0644" "$(jq -r .mode "$KV_DIR/secret/workstation/$me/files/.ssh__id_ed25519.pub.json")"
no "capture of a missing file fails" run capture "$me" .ssh/nope
no "capture refuses a path outside the home" run capture "$me" ../etc/passwd
no "capture refuses an absolute path" run capture "$me" /etc/passwd

# --- capture-ref: a file another secret already holds ----------------------
mkdir -p "$KV_DIR/secret"
printf '{"backup_key":"-----BEGIN KEY-----\\nREF-SECRET\\n-----END KEY-----"}' > "$KV_DIR/secret/viktor.json"
printf 'x\n' > "$home/.ssh/backup"; chmod 600 "$home/.ssh/backup"
ok "capture-ref succeeds" run capture-ref "$me" .ssh/backup 'secret/viktor#backup_key'
eq "a ref secret holds no content" "null" "$(jq -r .content_b64 "$KV_DIR/secret/workstation/$me/files/.ssh__backup.json")"
eq "a ref secret names its source" "secret/viktor#backup_key" "$(jq -r .ref "$KV_DIR/secret/workstation/$me/files/.ssh__backup.json")"
no "capture-ref refuses a malformed ref" run capture-ref "$me" .ssh/backup 'secret/viktor'

# --- list ------------------------------------------------------------------
out="$(run list "$me")"
ok "list shows each path with its mode" grep -qx '0600 .ssh/id_ed25519' <<<"$out"
ok "list shows a ref as a ref" grep -q '^0600 .ssh/backup (ref secret/viktor#backup_key)$' <<<"$out"
no "list never prints a secret" grep -qE 'PRIVATE-SSH-SECRET|GH-SECRET|REF-SECRET' <<<"$out"

# --- restore into an empty directory ---------------------------------------
dst="$tmp/restored"
out="$(run restore "$me" --into "$dst" 2>&1)"
ok "restore succeeds" test $? -eq 0
no "restore never prints a secret" grep -qE 'PRIVATE-SSH-SECRET|GH-SECRET|REF-SECRET' <<<"$out"
ok "restored text file is byte-identical" cmp -s "$home/.ssh/id_ed25519" "$dst/.ssh/id_ed25519"
ok "restored binary file is byte-identical" cmp -s "$home/.gnupg/private-keys-v1.d/ABC.key" "$dst/.gnupg/private-keys-v1.d/ABC.key"
eq "restored private key mode" "600" "$(stat -c %a "$dst/.ssh/id_ed25519")"
eq "restored public key mode" "644" "$(stat -c %a "$dst/.ssh/id_ed25519.pub")"
eq "a directory it creates is private" "700" "$(stat -c %a "$dst/.gnupg/private-keys-v1.d")"
eq "a ref restores the referenced field with a final newline" \
  "$(printf -- '-----BEGIN KEY-----\nREF-SECRET\n-----END KEY-----\nx')" "$(cat "$dst/.ssh/backup"; printf x)"
ok "restore reports what it wrote" grep -q 'restored 5' <<<"$out"

# --- restore never replaces what is there ----------------------------------
printf 'NEWER\n' > "$dst/.config/gh/hosts.yml"
out="$(run restore "$me" --into "$dst" 2>&1)"
eq "an existing file is kept" "NEWER" "$(cat "$dst/.config/gh/hosts.yml")"
ok "a second restore writes nothing" grep -q 'restored 0, kept 5' <<<"$out"
ln -s /nonexistent "$dst/dangling"
printf '{"path":"dangling","mode":"0600","content_b64":"eA=="}' > "$KV_DIR/secret/workstation/$me/files/dangling.json"
run restore "$me" --into "$dst" >/dev/null 2>&1
ok "a symlink in the way is left alone" test -L "$dst/dangling"
rm "$KV_DIR/secret/workstation/$me/files/dangling.json"

# --- a hostile entry in Vault is skipped, never written outside the home ---
printf '{"path":"../escape","mode":"0600","content_b64":"eA=="}' > "$KV_DIR/secret/workstation/$me/files/evil.json"
printf '{"path":"/tmp/abs-escape","mode":"0600","content_b64":"eA=="}' > "$KV_DIR/secret/workstation/$me/files/evil2.json"
printf '{"path":".ok-but-bad-mode","mode":"4755","content_b64":"eA=="}' > "$KV_DIR/secret/workstation/$me/files/evil3.json"
dst2="$tmp/r2/home"; mkdir -p "$dst2"
out="$(run restore "$me" --into "$dst2" 2>&1)"
no "a .. path is not written" test -e "$tmp/r2/escape"
no "an absolute path is not written" test -e /tmp/abs-escape
no "a setuid mode is not written" test -e "$dst2/.ok-but-bad-mode"
ok "the skips are reported" grep -q 'skipped 3' <<<"$out"
rm "$KV_DIR/secret/workstation/$me/files/evil"*.json

# --- no Vault access: restore says so and fails, so a caller can tell -----
no "restore without Vault access fails" env FAKE_VAULT_DENY=1 WORKSTATION_CREDS_HOME="$home" bash "$CREDS" restore "$me" --into "$tmp/r3"
# --- a user with nothing in Vault restores nothing, successfully ----------
out="$(run restore nobody-here --into "$tmp/r4" 2>&1)"
ok "nothing stored is not an error" grep -q 'nothing stored' <<<"$out"

echo "workstation-creds: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
