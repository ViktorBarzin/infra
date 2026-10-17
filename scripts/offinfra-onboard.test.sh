#!/bin/bash
# Tests for scripts/offinfra-onboard. Fakes for vault, gh and curl on PATH
# record every call; the clone's Forgejo remote is a local bare repo whose
# path contains the Forgejo host name, so fetch and push stay on disk.
# Run: bash scripts/offinfra-onboard.test.sh   (needs bash, git, jq, python3; no network)
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/offinfra-onboard"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

mkdir -p "$WORK/bin"
cat >"$WORK/bin/vault" <<'EOF'
#!/bin/bash
echo "vault-value"
EOF
# gh: the GitHub repo does not exist yet; everything else succeeds.
cat >"$WORK/bin/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >>"$CALLS"
case "$*" in
  "api repos/ViktorBarzin/demo --jq {archived,private}") exit 1 ;;
  "api repos/ViktorBarzin/demo --jq .id") echo 4242 ;;
  "api repos/ViktorBarzin/demo --jq .default_branch") echo master ;;
esac
exit 0
EOF
# curl: Forgejo answers no mirrors, Woodpecker knows no repos and registers id 77.
cat >"$WORK/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >>"$CALLS"
case "$*" in
  *forge_remote_id=*) echo '{"id":77}' ;;
  *"repos?perPage=100"*) echo '[]' ;;
  *push_mirrors*) echo '[]' ;;
  *) echo '{}' ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/"*

# new_clone <dir>: a clone of a fresh Forgejo stand-in, with the template's own
# workflow files committed.
new_clone() {
  local remote="$WORK/$1/forgejo.viktorbarzin.me/viktor/demo.git"
  mkdir -p "$(dirname "$remote")"
  git init -q --bare -b master "$remote"
  git init -q -b master "$WORK/$1/clone"
  (
    cd "$WORK/$1/clone" || exit 1
    git config user.email t@example.com && git config user.name t
    mkdir -p .github/workflows .woodpecker
    echo "# the template's build" >.github/workflows/build.yml
    echo "# the template's deploy" >.woodpecker/deploy.yml
    git add -A && git commit -qm init
    git remote add forgejo "$remote"
    git push -q forgejo master
  )
  echo "$WORK/$1/clone"
}

run_onboard() { # <clone> <args...> -> sets OUT, RC
  local clone=$1; shift
  : >"$CALLS"
  OUT=$(cd "$WORK" && HOME="$WORK/home" PATH="$WORK/bin:$PATH" \
    bash "$SCRIPT" demo --clone "$clone" --visibility public --namespace demo "$@" 2>&1)
  RC=$?
}

mkdir -p "$WORK/home"
echo "https://viktor:fj-token@forgejo.viktorbarzin.me" >"$WORK/home/.git-credentials"
export CALLS="$WORK/calls"

# --keep-workflows: the template's files stay, the variable is set.
clone=$(new_clone keep)
run_onboard "$clone" --deploy "demo=migrate,demo" --keep-workflows
[ "$RC" = 0 ] && pass "--keep-workflows runs" || { fail "--keep-workflows exits $RC"; echo "$OUT"; }
[ "$(cat "$clone/.github/workflows/build.yml")" = "# the template's build" ] \
  && pass "--keep-workflows keeps build.yml" || fail "--keep-workflows replaced build.yml"
[ "$(cat "$clone/.woodpecker/deploy.yml")" = "# the template's deploy" ] \
  && pass "--keep-workflows keeps deploy.yml" || fail "--keep-workflows replaced deploy.yml"
grep -qx "gh variable set WOODPECKER_REPO_ID -R ViktorBarzin/demo --body 77" "$CALLS" \
  && pass "sets the WOODPECKER_REPO_ID repo variable" || { fail "WOODPECKER_REPO_ID not set"; cat "$CALLS"; }

# Without the flag the generic workflows are rendered, as before.
clone=$(new_clone render)
run_onboard "$clone" --deploy "demo=demo"
[ "$RC" = 0 ] && pass "default run" || { fail "default run exits $RC"; echo "$OUT"; }
grep -q "ghcr.io/viktorbarzin/demo" "$clone/.github/workflows/build.yml" \
  && pass "default run renders build.yml" || fail "default run did not render build.yml"
grep -q "kubectl -n demo set image deployment/demo" "$clone/.woodpecker/deploy.yml" \
  && pass "default run renders deploy.yml" || fail "default run did not render deploy.yml"
grep -qx "gh variable set WOODPECKER_REPO_ID -R ViktorBarzin/demo --body 77" "$CALLS" \
  && pass "default run sets WOODPECKER_REPO_ID" || fail "default run did not set WOODPECKER_REPO_ID"

# --no-deploy registers nothing in Woodpecker, so there is no id to set.
clone=$(new_clone nodeploy)
run_onboard "$clone" --no-deploy --keep-workflows
[ "$RC" = 0 ] && pass "--no-deploy runs" || { fail "--no-deploy exits $RC"; echo "$OUT"; }
grep -q "variable set WOODPECKER_REPO_ID" "$CALLS" \
  && fail "--no-deploy set WOODPECKER_REPO_ID" || pass "--no-deploy sets no repo variable"

# Dry run: says what it would do, changes nothing.
clone=$(new_clone dry)
run_onboard "$clone" --deploy "demo=demo" --keep-workflows --dry-run
[ "$RC" = 0 ] && pass "dry run" || { fail "dry run exits $RC"; echo "$OUT"; }
grep -q "DRY: gh variable set WOODPECKER_REPO_ID" <<<"$OUT" \
  && pass "dry run reports the variable" || { fail "dry run does not report the variable"; echo "$OUT"; }
grep -q "variable set" "$CALLS" && fail "dry run called gh variable set" || pass "dry run sets nothing"

run_onboard "$clone" --deploy "demo=demo" --no-such-flag
[ "$RC" != 0 ] && grep -q "unknown flag: --no-such-flag" <<<"$OUT" \
  && pass "an unknown flag is refused" || fail "an unknown flag was accepted"

echo
[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
