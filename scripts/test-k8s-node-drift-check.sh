#!/usr/bin/env bash
# Checks that scripts/k8s-node-drift-check judges the nodes against what is on
# origin/master, not against the checkout's working tree. The checkout is the
# shared admin one on the devvm, which stopped following master on its own on
# 2026-11-11 (wizard's hourly `git pull` cron was dropped), so a check run from
# its working tree would compare the nodes to a stale playbook.
#
# Run: bash scripts/test-k8s-node-drift-check.sh
#
# Builds a throwaway origin and clone, with stand-ins for ansible-playbook and
# the kubelet check, and runs the script with --no-push.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$DIR/k8s-node-drift-check"

pass=0 fail=0
ok() { if "${@:2}"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
no() { if "${@:2}"; then fail=$((fail+1)); echo "FAIL: $1"; else pass=$((pass+1)); fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.invalid; git config --global user.name t
git config --global init.defaultBranch master

mkdir -p "$tmp/bin"
# ansible-playbook stand-in: prints a converged PLAY RECAP, the part of its
# output the check echoes, naming the playbook version it was given and where
# it ran.
cat > "$tmp/bin/ansible-playbook" <<'EOF'
#!/usr/bin/env bash
echo "PLAY RECAP *****"
echo "PLAYBOOK=$(cat playbooks/k8s-node-tuning.yml) CWD=$PWD"
echo "10.0.20.101 : ok=3 changed=0 unreachable=0 failed=0 skipped=0"
EOF
chmod +x "$tmp/bin/ansible-playbook"
export PATH="$tmp/bin:$PATH"

seed() {  # seed <dir> <version>: write the two files the check reads
  mkdir -p "$1/playbooks" "$1/scripts"
  echo "$2" > "$1/playbooks/k8s-node-tuning.yml"
  : > "$1/playbooks/inventory.ini"
  printf '#!/usr/bin/env bash\necho "kubelet tune %s ok"\n' "$2" > "$1/scripts/check-node-kubelet-tune"
  chmod +x "$1/scripts/check-node-kubelet-tune"
}
git init -q --bare "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/author" 2>/dev/null
seed "$tmp/author" v1
git -C "$tmp/author" add -A && git -C "$tmp/author" commit -qm v1 && git -C "$tmp/author" push -q origin master
git clone -q "$tmp/origin.git" "$tmp/checkout"
seed "$tmp/author" v2
git -C "$tmp/author" commit -qam v2 && git -C "$tmp/author" push -q origin master

# The checkout is at v1 and has not fetched v2; origin has v2.
out="$(K8S_DRIFT_REPO="$tmp/checkout" bash "$CHECK" --no-push 2>&1)"; rc=$?
ok "a converged run exits 0" test "$rc" -eq 0
ok "the playbook comes from origin/master" grep -q 'PLAYBOOK=v2 ' <<<"$out"
ok "the kubelet check comes from origin/master" grep -q 'kubelet tune v2 ok' <<<"$out"
no "the working tree's playbook is not used" grep -q 'PLAYBOOK=v1 ' <<<"$out"
ok "the log names the commit it judged against" grep -q "origin/master $(git -C "$tmp/origin.git" rev-parse --short master)" <<<"$out"
ok "the checkout's working tree is left as it was" grep -qx v1 "$tmp/checkout/playbooks/k8s-node-tuning.yml"
no "it does not run inside the checkout" grep -q "CWD=$tmp/checkout\$" <<<"$out"
leftover="$(grep -o 'CWD=[^ ]*' <<<"$out" | head -1 | cut -d= -f2)"
no "the exported tree is removed afterwards" test -d "${leftover:-/nonexistent}"

# Origin unreachable: the last fetched origin/master is still committed content.
git -C "$tmp/checkout" remote set-url origin "$tmp/gone.git"
out="$(K8S_DRIFT_REPO="$tmp/checkout" bash "$CHECK" --no-push 2>&1)"
ok "a failed fetch is reported" grep -q 'WARN: git fetch' <<<"$out"
ok "and the last fetched origin/master is used" grep -q 'PLAYBOOK=v2 ' <<<"$out"

# No origin/master at all: the working tree, said out loud.
git init -q "$tmp/bare-tree"; seed "$tmp/bare-tree" v0
git -C "$tmp/bare-tree" add -A && git -C "$tmp/bare-tree" commit -qm v0
out="$(K8S_DRIFT_REPO="$tmp/bare-tree" bash "$CHECK" --no-push 2>&1)"
ok "without origin/master it falls back to the working tree" grep -q 'PLAYBOOK=v0 ' <<<"$out"
ok "and says so" grep -q 'running the working tree' <<<"$out"

echo "k8s-node-drift-check: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
