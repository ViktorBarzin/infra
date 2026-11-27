#!/usr/bin/env bash
# Checks the tracked git hooks in .githooks (activated per clone with
# core.hooksPath by scripts/t3-provision-users.sh, wire_infra_hooks):
#   - pre-commit refuses a git-crypt file whose staged blob is encrypted twice,
#     the 2c6fb5d23 / cd32e7a06 / 99e38e93a commits, including the real chain:
#     a worktree checked out with the cat bypass, then `git add -A`
#   - pre-commit refuses plaintext staged for a git-crypt path
#   - in a locked clone (no key) it refuses any git-crypt blob that no commit
#     already holds for that path, and passes one taken from history
#   - a normal secret edit and a normal non-secret commit pass
#   - the clone's own .git/hooks/<name> still runs (gitleaks shim, beads
#     post-commit), from the main checkout and from a linked worktree, and
#     its failure still blocks the commit
#
# Run: bash scripts/githooks.test.sh
# Builds throwaway repos with real git-crypt. Needs git and git-crypt.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$(cd "$DIR/../.githooks" 2>/dev/null && pwd)" || { echo "FAIL: no .githooks directory next to scripts/"; exit 1; }

pass=0 fail=0
ok() { if "${@:2}"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1"; fi; }
no() { if "${@:2}"; then fail=$((fail+1)); echo "FAIL: $1"; else pass=$((pass+1)); fi; }
has() { grep -qF -- "$2" "$1"; }

command -v git-crypt >/dev/null || { echo "SKIP: git-crypt not installed"; exit 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
OUT="$tmp/out"

# commit_in DIR ARGS...: git commit with the hooks under test; output in $OUT.
commit_in() { local d="$1"; shift; git -C "$d" commit -q "$@" >"$OUT" 2>&1; }
head_bytes() { head -c 10 | od -An -tx1 | tr -d ' \n'; }
HDR=00474954435259505400   # \0GITCRYPT\0

# --- an unlocked clone: real git-crypt filters with --key-file, as wizard's ---
repo="$tmp/repo"
git init -q -b master "$repo"
(
  cd "$repo" || exit 1
  git-crypt init >/dev/null 2>&1
  printf 'secrets/** filter=git-crypt diff=git-crypt\n*.tfvars filter=git-crypt diff=git-crypt\n' > .gitattributes
  mkdir -p secrets docs
  printf -- '-----BEGIN KEY-----\nabc\n' > secrets/key.pem
  printf 'a = "1"\n' > config.tfvars
  printf 'hello\n' > docs/readme.md
  git add .gitattributes secrets/key.pem config.tfvars docs/readme.md
  git commit -q -m init
) || { echo "FAIL: could not build the test repo"; exit 1; }
key="$repo/.git/git-crypt/keys/default"
git -C "$repo" config filter.git-crypt.smudge "\"git-crypt\" smudge --key-file $key"
git -C "$repo" config filter.git-crypt.clean "\"git-crypt\" clean --key-file $key"
git -C "$repo" config core.hooksPath "$HOOKS"
ok "fixture: HEAD holds the secret encrypted once" \
  test "$(git -C "$repo" cat-file blob HEAD:secrets/key.pem | head_bytes)" = "$HDR"

# 1. a normal non-secret commit passes
printf 'more\n' >> "$repo/docs/readme.md"
git -C "$repo" add docs/readme.md
ok "unlocked: a non-secret commit passes" commit_in "$repo" -m docs

# 2. a normal secret edit passes, and is stored encrypted once
printf 'def\n' >> "$repo/secrets/key.pem"
git -C "$repo" add secrets/key.pem
ok "unlocked: a normal secret edit passes" commit_in "$repo" -m secret
ok "unlocked: the committed secret decrypts to plaintext" \
  test "$(git -C "$repo" cat-file blob HEAD:secrets/key.pem | git-crypt smudge --key-file "$key" | head -c 5)" = "-----"

# 3. a staged blob encrypted twice is refused, with the file and the fix named
good="$(git -C "$repo" rev-parse HEAD:secrets/key.pem)"
bad="$(git -C "$repo" cat-file blob "$good" | git-crypt clean --key-file "$key" | git -C "$repo" hash-object -w --stdin)"
git -C "$repo" update-index --cacheinfo "100644,$bad,secrets/key.pem"
no "unlocked: a double-encrypted blob is refused" commit_in "$repo" -m double
ok "unlocked: the refusal names the file" has "$OUT" "secrets/key.pem"
ok "unlocked: the refusal says it is encrypted twice" has "$OUT" "encrypted twice"
ok "unlocked: the refusal gives the update-index fix with HEAD's blob" \
  has "$OUT" "git update-index --cacheinfo 100644,$good,secrets/key.pem"
ok "unlocked: nothing was committed" test "$(git -C "$repo" rev-parse HEAD:secrets/key.pem)" = "$good"
git -C "$repo" update-index --cacheinfo "100644,$good,secrets/key.pem"

# 4. plaintext staged for a git-crypt path (clean filter bypassed) is refused
printf 'b = "2"\n' >> "$repo/config.tfvars"
git -C "$repo" -c filter.git-crypt.clean=cat add config.tfvars
no "unlocked: plaintext for a git-crypt path is refused" commit_in "$repo" -m plain
ok "unlocked: the plaintext refusal names the file" has "$OUT" "config.tfvars"
ok "unlocked: the plaintext refusal says it is not encrypted" has "$OUT" "not encrypted"
git -C "$repo" checkout -q HEAD -- config.tfvars

# 5. the real chain: a worktree checked out with the cat bypass holds
# ciphertext; plain git re-hashes it with the real clean filter (a new mtime
# is enough) and `git add -A` stages it encrypted twice.
wt="$tmp/wt"
git -C "$repo" -c filter.git-crypt.smudge=cat -c filter.git-crypt.clean=cat -c filter.git-crypt.required=false \
  worktree add -q -b topic "$wt" master
ok "fixture: the worktree holds ciphertext" test "$(head_bytes < "$wt/secrets/key.pem")" = "$HDR"
sleep 1; touch "$wt/secrets/key.pem"
printf 'wt\n' >> "$wt/docs/readme.md"
git -C "$wt" add -A
ok "fixture: add -A staged the secret encrypted twice" \
  test "$(git -C "$wt" cat-file blob :secrets/key.pem | git-crypt smudge --key-file "$key" | head_bytes)" = "$HDR"
no "worktree: add -A of a ciphertext checkout is refused" commit_in "$wt" -m wt
ok "worktree: the refusal names the file" has "$OUT" "secrets/key.pem"
# git re-hashed every ciphertext file it saw, so config.tfvars may be
# staged encrypted twice as well
git -C "$wt" restore --staged secrets/key.pem config.tfvars
ok "worktree: after restore --staged, the docs change commits" commit_in "$wt" -m wt-docs

# 6. the clone's own .git/hooks still run: pre-commit (the gitleaks shim)
# after the guard, post-commit (beads) after the commit, from the main
# checkout and from a linked worktree; a failing local pre-commit blocks.
cat > "$repo/.git/hooks/pre-commit" <<EOF
#!/bin/sh
echo "local pre-commit ran in \$(pwd)" >> "$tmp/local.log"
[ ! -e "$tmp/local-fail" ]
EOF
cat > "$repo/.git/hooks/post-commit" <<EOF
#!/bin/sh
echo "local post-commit ran" >> "$tmp/local.log"
EOF
chmod +x "$repo/.git/hooks/pre-commit" "$repo/.git/hooks/post-commit"
: > "$tmp/local.log"
printf 'x\n' >> "$repo/docs/readme.md"; git -C "$repo" add docs/readme.md
ok "chain: a commit with local hooks passes" commit_in "$repo" -m chain
ok "chain: the local pre-commit ran" has "$tmp/local.log" "local pre-commit ran"
ok "chain: the local post-commit ran" has "$tmp/local.log" "local post-commit ran"
: > "$tmp/local.log"
printf 'y\n' >> "$wt/docs/readme.md"; git -C "$wt" add docs/readme.md
ok "chain: a worktree commit passes" commit_in "$wt" -m chain-wt
ok "chain: the local pre-commit ran from the worktree" has "$tmp/local.log" "local pre-commit ran in $wt"
ok "chain: the local post-commit ran from the worktree" has "$tmp/local.log" "local post-commit ran"
touch "$tmp/local-fail"
printf 'z\n' >> "$repo/docs/readme.md"; git -C "$repo" add docs/readme.md
no "chain: a failing local pre-commit blocks the commit" commit_in "$repo" -m blocked
rm -f "$tmp/local-fail"
# a refused secret never reaches the local hook
: > "$tmp/local.log"
git -C "$repo" update-index --cacheinfo "100644,$bad,secrets/key.pem"
no "chain: the guard refuses before the local hook" commit_in "$repo" -m double2
no "chain: the local pre-commit did not run after a refusal" has "$tmp/local.log" "local pre-commit ran"
git -C "$repo" update-index --cacheinfo "100644,$good,secrets/key.pem"

# 7. with no local pre-commit, the user's shared gitleaks hook runs if present,
# and its absence is no error
rm -f "$repo/.git/hooks/pre-commit"
mkdir -p "$HOME/.claude/hooks"
printf '#!/bin/sh\necho "shared gitleaks ran" >> "%s"\n' "$tmp/local.log" > "$HOME/.claude/hooks/gitleaks-pre-commit.sh"
chmod +x "$HOME/.claude/hooks/gitleaks-pre-commit.sh"
: > "$tmp/local.log"
ok "fallback: a commit with no local pre-commit passes" commit_in "$repo" -m retry-docs
ok "fallback: the shared gitleaks hook ran" has "$tmp/local.log" "shared gitleaks ran"
rm -f "$HOME/.claude/hooks/gitleaks-pre-commit.sh"
printf 'w\n' >> "$repo/docs/readme.md"; git -C "$repo" add docs/readme.md
ok "fallback: no gitleaks anywhere is no error" commit_in "$repo" -m no-gitleaks

# --- a locked clone: no key, cat filters, as install_locked_clone makes ---
locked="$tmp/locked"
git clone -q --no-checkout "$repo" "$locked"
git -C "$locked" config filter.git-crypt.smudge cat
git -C "$locked" config filter.git-crypt.clean cat
git -C "$locked" config filter.git-crypt.required false
git -C "$locked" checkout -q master
git -C "$locked" config core.hooksPath "$HOOKS"
ok "fixture: the locked clone holds ciphertext" test "$(head_bytes < "$locked/secrets/key.pem")" = "$HDR"

# 8. a non-secret commit passes
printf 'l\n' >> "$locked/docs/readme.md"; git -C "$locked" add docs/readme.md
ok "locked: a non-secret commit passes" commit_in "$locked" -m docs

# 9. an edited secret would be committed as plaintext: refused
printf -- '-----BEGIN KEY-----\nnew\n' > "$locked/secrets/key.pem"
git -C "$locked" add secrets/key.pem
no "locked: a plaintext secret edit is refused" commit_in "$locked" -m edit
ok "locked: the refusal names the file" has "$OUT" "secrets/key.pem"
git -C "$locked" checkout -q HEAD -- secrets/key.pem

# 10. ciphertext the locked clone made up (header, but no commit holds it)
forged="$( { printf '\0GITCRYPT\0'; head -c 40 /dev/urandom; } | git -C "$locked" hash-object -w --stdin)"
git -C "$locked" update-index --cacheinfo "100644,$forged,secrets/key.pem"
no "locked: ciphertext no commit holds is refused" commit_in "$locked" -m forged
ok "locked: the refusal says the clone has no key" has "$OUT" "no git-crypt key"
git -C "$locked" checkout -q HEAD -- secrets/key.pem

# 11. a version some commit already holds passes (a revert, or taking master's)
first="$(git -C "$locked" rev-list --reverse HEAD -- secrets/key.pem | head -1)"
old="$(git -C "$locked" rev-parse "$first:secrets/key.pem")"
ok "fixture: an older version differs from HEAD's" test "$old" != "$(git -C "$locked" rev-parse HEAD:secrets/key.pem)"
git -C "$locked" update-index --cacheinfo "100644,$old,secrets/key.pem"
ok "locked: a git-crypt blob from history passes" commit_in "$locked" -m revert-secret

echo "githooks: $pass passed, $fail failed"
(( fail == 0 ))
