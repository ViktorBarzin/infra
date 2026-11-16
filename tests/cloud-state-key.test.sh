#!/usr/bin/env bash
# Checks who may read Cloud's OpenTofu state key, Vault
# secret/cloud/state-key (cloud repo backlog B09), against a dev Vault.
#
# The policy text comes from the repo, unchanged: the cloud-reconciler and
# cloud-project locals in stacks/vault/cloud_policies.tf, and every
# vault_policy in stacks/vault/main.tf that grants read on secret/data/*
# (ci, eso-reader, openclaw-k8s, terraform-state). The test checks that:
#   the cloud-reconciler policy reads the key and cannot write, patch,
#     soft-delete or destroy it;
#   a Project token (cloud-project, rendered for p-demo) cannot read it;
#   every broad secret/data/* reader is refused the key and its metadata,
#     and still reads another path (secret/cloud/system), so the deny is
#     narrow;
#   no broad reader is left out: the list of secret/data/* policies in
#     main.tf is exactly the four above.
#
# Needs vault and python3. Runs in seconds; no cluster. HOME is a temp
# directory, so ~/.vault-token is never touched.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
VPORT="${VPORT:-$((18200 + RANDOM % 500))}"
export HOME="$TMP/home" VAULT_ADDR="http://127.0.0.1:$VPORT" VAULT_TOKEN="root-state-key-test"
mkdir -p "$HOME"
VPID=""
cleanup() { [ -n "$VPID" ] && kill "$VPID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "BAD  $1"; FAILS=$((FAILS + 1)); }

BROAD="ci eso-reader openclaw-k8s terraform-state"

python3 - "$HERE" "$TMP" <<'PY'
import re, sys, pathlib
here, tmp = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
locals_tf = (here / "stacks/vault/cloud_policies.tf").read_text()
def local(name):
    m = re.search(name + r' = <<-EOT\n(.*?)\n\s*EOT', locals_tf, re.S)
    return m.group(1)
(tmp / "cloud-reconciler.hcl").write_text(local("cloud_reconciler_policy"))
(tmp / "cloud-project.hcl").write_text(
    re.sub(r"\{\{identity\.entity\.aliases\.[^}]+\}\}", "p-demo", local("cloud_project_policy_template")))
main = (here / "stacks/vault/main.tf").read_text()
broad = []
# Each vault_policy resource: its name, then its first heredoc.
for chunk in main.split('resource "vault_policy" ')[1:]:
    name = re.search(r'\n\s*name\s*=\s*"([^"]+)"', chunk).group(1)
    body = re.search(r'policy = <<-EOT\n(.*?)\n\s*EOT', chunk, re.S)
    if body is None:
        continue
    text = body.group(1)
    if 'path "secret/data/*"' in text:
        (tmp / f"{name}.hcl").write_text(text)
        broad.append(name)
(tmp / "broad.txt").write_text(" ".join(sorted(broad)))
PY

found="$(cat "$TMP/broad.txt")"
want="$(tr ' ' '\n' <<<"$BROAD" | sort | tr '\n' ' ' | sed 's/ $//')"
[ "$found" = "$want" ] && ok "the secret/data/* readers in main.tf are: $found" || bad "secret/data/* readers in main.tf are '$found', the test knows '$want'"

vault server -dev -dev-no-store-token -dev-root-token-id="$VAULT_TOKEN" -dev-listen-address="127.0.0.1:$VPORT" >"$TMP/vault.log" 2>&1 &
VPID=$!
for _ in $(seq 1 30); do vault status >/dev/null 2>&1 && break; sleep 1; done
vault status >/dev/null 2>&1 || { echo "FAIL: dev vault did not start"; tail "$TMP/vault.log"; exit 1; }

for p in cloud-reconciler cloud-project $BROAD; do vault policy write "$p" "$TMP/$p.hcl" >/dev/null; done
vault kv put secret/cloud/state-key passphrase=state-key-for-the-test-0123456789abcdef >/dev/null
vault kv put secret/cloud/system ghcr_pull_token=g >/dev/null

token() { vault token create -policy="$1" -field=token; }
as() { local t="$1"; shift; VAULT_TOKEN="$t" "$@" >/dev/null 2>&1; }
can() { if as "$2" "${@:3}"; then ok "$1"; else bad "$1"; fi; }
cannot() { if as "$2" "${@:3}"; then bad "$1"; else ok "$1"; fi; }

RT="$(token cloud-reconciler)"
can    "cloud-reconciler reads the state key" "$RT" vault kv get -field=passphrase secret/cloud/state-key
cannot "cloud-reconciler cannot write it" "$RT" vault kv put secret/cloud/state-key passphrase=x
cannot "cloud-reconciler cannot patch it" "$RT" vault kv patch -method=patch secret/cloud/state-key passphrase=x
cannot "cloud-reconciler cannot soft-delete it" "$RT" vault kv delete secret/cloud/state-key
cannot "cloud-reconciler cannot destroy it" "$RT" vault kv metadata delete secret/cloud/state-key

PT="$(token cloud-project)"
cannot "a Project token cannot read the state key" "$PT" vault kv get secret/cloud/state-key

for p in $BROAD; do
  T="$(token "$p")"
  cannot "$p cannot read the state key" "$T" vault kv get secret/cloud/state-key
  cannot "$p cannot read the state key's metadata" "$T" vault kv metadata get secret/cloud/state-key
  can    "$p still reads secret/cloud/system" "$T" vault kv get secret/cloud/system
done

[ "$(VAULT_TOKEN="$VAULT_TOKEN" vault kv get -field=passphrase secret/cloud/state-key)" = "state-key-for-the-test-0123456789abcdef" ] \
  && ok "the key is unchanged after every refused write" || bad "the key changed"

echo
if [ "$FAILS" -eq 0 ]; then echo "PASS: only cloud-reconciler reads secret/cloud/state-key"; else echo "FAIL: $FAILS check(s)"; exit 1; fi
