#!/bin/bash
# Tests for scripts/t3-autoupdate.sh on a box with no t3 at all: a devvm built
# from stacks/devvm, where playbooks/devvm.yml runs the updater once to put the
# first build in place. npm, logger and t3 itself are stubs; the versions dir,
# the /usr/bin/t3 link, the state dir, the freeze file and the lock are temp
# paths. Covered: the no-t3 branch, and a run on the live box with scratch
# paths (cases 10-12), which on 2026-11-11 read the live /usr/bin/t3, "rolled
# back" its own scratch install and paged T3AutoUpdateRollbackFailed. The gated
# bump itself is exercised by the runbook's dry run
# (docs/runbooks/t3-version-bump.md).
# Run: bash scripts/t3-autoupdate.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

mkdir -p "$WORK/stubs" "$WORK/linkdir"
# npm view t3@<tag> version -> $NPM_LATEST (empty = offline);
# npm i --prefix <dir> t3@<ver> -> a launcher that prints "t3 v<ver>".
cat >"$WORK/stubs/npm" <<'STUB'
#!/bin/bash
echo "npm $*" >>"$CALLS"
case "$1" in
  view) [ -n "${NPM_LATEST:-}" ] && echo "$NPM_LATEST"; exit 0 ;;
  i|install)
    [ "${NPM_FAIL:-0}" = 1 ] && exit 1
    [ "$2" = --prefix ] || exit 1
    prefix=$3; v=${4#t3@}
    mkdir -p "$prefix/node_modules/t3/bin" "$prefix/node_modules/.bin"
    printf '#!/bin/bash\necho "t3 v%s"\n' "$v" >"$prefix/node_modules/t3/bin/t3.mjs"
    chmod +x "$prefix/node_modules/t3/bin/t3.mjs"
    ln -s ../t3/bin/t3.mjs "$prefix/node_modules/.bin/t3"
    exit 0 ;;
esac
exit 1
STUB
printf '#!/bin/bash\nexit 0\n' >"$WORK/stubs/logger"
# The box running the test may have a real /usr/bin/t3 later on PATH; this
# stub hides it, so `t3` is the temp link or nothing. LIVE_T3=<ver> makes it
# stand for the live box's /usr/bin/t3 at <ver> instead.
printf '#!/bin/bash\n[ -n "${LIVE_T3:-}" ] && { echo "t3 v$LIVE_T3"; exit 0; }\n[ -x "$LINK" ] && exec "$LINK" "$@"\nexit 127\n' >"$WORK/stubs/t3"
# systemctl: list-units shows $UNITS (the live box's t3-serve@ units), every
# other call is recorded and succeeds.
cat >"$WORK/stubs/systemctl" <<'STUB'
#!/bin/bash
case "$1" in
  list-units) for u in ${UNITS:-}; do echo "$u loaded active running t3"; done ;;
  show) ;;
  *) echo "systemctl $*" >>"$CALLS" ;;
esac
exit 0
STUB
chmod +x "$WORK/stubs/npm" "$WORK/stubs/logger" "$WORK/stubs/t3" "$WORK/stubs/systemctl"
# The real lib with a health gate that always passes, for the cases that need
# a run to get past it.
printf '. "%s/t3-safe-restart.sh"\nhealth_check() { echo "health_check $*" >>"$CALLS"; return 0; }\n' "$HERE" >"$WORK/lib-gate-ok.sh"

LINK=$WORK/linkdir/t3
VERS=$WORK/versions
STATE=$WORK/state
FREEZE=$WORK/freeze
CALLS=$WORK/calls

reset() { rm -rf "$VERS" "$STATE" "$FREEZE" "$WORK/linkdir"/* "$WORK/legacy"; : >"$CALLS"; }

run() { # env... -> output, then rc=<n>
  (
    export PATH="$WORK/linkdir:$WORK/stubs:/usr/bin:/bin" CALLS LINK
    export T3_VERSIONS_DIR="$VERS" T3_LINK="$LINK" T3_STATE_DIR="$STATE"
    export T3_FREEZE_FILE="$FREEZE" T3_UPDATE_LOCK="$WORK/lock" T3_LEGACY_DIR="$WORK/legacy"
    export T3_USER_MAP="$WORK/no-map" T3_SAFE_RESTART_LIB="$HERE/t3-safe-restart.sh"
    export T3_TMPDIR="$WORK" T3_BACKUP_DEST="$WORK/backups"
    for kv in "$@"; do export "${kv?}"; done
    bash "$HERE/t3-autoupdate.sh"
    echo "rc=$?"
  ) 2>&1
}

# 1. A new box: no link, no legacy install. The updater installs the tracked
#    release into its own prefix, points the link at it and records last-good.
reset
out=$(run NPM_LATEST=0.1.8)
target=$(readlink "$LINK" 2>/dev/null)
if [[ "$target" == "$(readlink -f "$VERS/0.1.8/node_modules/.bin/t3")" && -x "$target" ]]; then
  ok "no t3: links $LINK to the 0.1.8 install"
else bad "no t3: link is '$target'; output: $out"; fi
[[ "$("$LINK" --version)" == "t3 v0.1.8" ]] && ok "no t3: the link runs 0.1.8" || bad "no t3: link does not run 0.1.8"
[[ "$(cat "$STATE/last-good" 2>/dev/null)" == 0.1.8 ]] && ok "no t3: last-good is 0.1.8" || bad "no t3: last-good is '$(cat "$STATE/last-good" 2>/dev/null)'"
[[ "$out" == *"first install"* && "$out" == *"rc=0"* ]] && ok "no t3: says first install, exits 0" || bad "no t3: output: $out"
grep -q '^npm i --prefix .*t3@0.1.8$' "$CALLS" && ok "no t3: installs into a prefix, not npm -g" || bad "no t3: npm calls: $(cat "$CALLS")"

# 2. A second run on that box is an ordinary run: already current, no install.
: >"$CALLS"
out=$(run NPM_LATEST=0.1.8)
[[ "$out" == *"nothing to do"* ]] && ok "second run: nothing to do" || bad "second run: $out"
grep -q '^npm i ' "$CALLS" && bad "second run: installed again" || ok "second run: no install"

# 3. T3_PIN wins over the dist-tag for the first install too.
reset
out=$(run NPM_LATEST=0.1.9 T3_PIN=0.1.7)
[[ "$("$LINK" --version 2>/dev/null)" == "t3 v0.1.7" ]] && ok "pin: first install is the pinned 0.1.7" || bad "pin: output: $out"

# 4. The link exists but does not run (a broken build on a live box): never
#    swapped to an ungated build. The old "is t3 installed?" exit stands.
reset
ln -s "$WORK/nowhere" "$LINK"
out=$(run NPM_LATEST=0.1.8)
[[ "$(readlink "$LINK")" == "$WORK/nowhere" ]] && ok "broken link: left alone" || bad "broken link: now $(readlink "$LINK")"
[[ "$out" == *"is t3 installed?"* ]] && ok "broken link: says so" || bad "broken link: output: $out"
grep -q '^npm i ' "$CALLS" && bad "broken link: installed anyway" || ok "broken link: no install"

# 5. A legacy npm -g install is present (no link): also not a new box.
reset
mkdir -p "$WORK/legacy"
out=$(run NPM_LATEST=0.1.8)
[[ ! -e "$LINK" && ! -L "$LINK" ]] && ok "legacy install: no link made" || bad "legacy install: link made; $out"

# 6. Frozen: nothing happens, even on a new box.
reset
touch "$FREEZE"
out=$(run NPM_LATEST=0.1.8)
[[ ! -e "$LINK" && ! -L "$LINK" && "$out" == *FROZEN* ]] && ok "frozen: no install" || bad "frozen: $out"

# 7. npm cannot resolve the tag (offline): no link, exit non-zero so the
#    playbook task fails instead of leaving a box without T3 unnoticed.
reset
out=$(run NPM_LATEST=)
[[ ! -e "$LINK" && ! -L "$LINK" ]] && ok "offline: no link" || bad "offline: link made"
[[ "$out" != *"rc=0"* ]] && ok "offline: non-zero exit" || bad "offline: exited 0: $out"

# 8. The install fails: no link, no half-made versions dir entry, non-zero exit.
reset
out=$(run NPM_LATEST=0.1.8 NPM_FAIL=1)
[[ ! -e "$LINK" && ! -L "$LINK" && ! -e "$VERS/0.1.8" ]] && ok "npm fails: nothing left behind" || bad "npm fails: $(ls -la "$VERS" 2>&1)"
[[ "$out" != *"rc=0"* ]] && ok "npm fails: non-zero exit" || bad "npm fails: exited 0: $out"

# 9. Dry run on a new box: no install.
reset
out=$(run NPM_LATEST=0.1.8 T3_DRY_RUN=1)
[[ ! -e "$LINK" && ! -L "$LINK" ]] && ok "dry run: no link" || bad "dry run: link made"

# On the live box `t3` on PATH is /usr/bin/t3, never the scratch link.
LIVE_PATH="$WORK/stubs:/usr/bin:/bin"

# 10. The live box with scratch paths: /usr/bin/t3 (on PATH) runs 0.1.8 and the
#     scratch link does not exist yet. The run reads the version at T3_LINK,
#     so it is a first install into scratch: no bump, no rollback, no npm -g.
reset
out=$(run NPM_LATEST=0.1.9 LIVE_T3=0.1.8 PATH="$LIVE_PATH")
[[ "$("$LINK" --version 2>/dev/null)" == "t3 v0.1.9" && "$out" == *"first install"* && "$out" == *"rc=0"* ]] \
  && ok "scratch on a live box: first install into the scratch link" || bad "scratch on a live box: output: $out"
[[ "$out" != *"rolling back"* && "$out" != *"rolled back"* ]] && ok "scratch on a live box: no rollback" || bad "scratch on a live box: rolled back: $out"
grep -q '^npm i -g' "$CALLS" && bad "scratch on a live box: ran npm -g" || ok "scratch on a live box: no npm -g"

# 11. A bump through scratch paths on a live box: the t3-serve@ units run
#     /usr/bin/t3, not the scratch link, so the canary does not restart them.
reset
run NPM_LATEST=0.1.8 >/dev/null
: >"$CALLS"
out=$(run NPM_LATEST=0.1.9 LIVE_T3=0.1.8 PATH="$LIVE_PATH" UNITS=t3-serve@alice.service T3_SAFE_RESTART_LIB="$WORK/lib-gate-ok.sh")
[[ "$("$LINK" --version 2>/dev/null)" == "t3 v0.1.9" && "$out" == *"rc=0"* ]] && ok "scratch bump: scratch link moves to 0.1.9" || bad "scratch bump: output: $out"
grep -q '^systemctl restart' "$CALLS" && bad "scratch bump: restarted a live serve: $(cat "$CALLS")" || ok "scratch bump: no live serve restarted"
[[ "$out" == *"not restarting"* ]] && ok "scratch bump: says why it skipped the canary" || bad "scratch bump: output: $out"

# 12. A rollback with a scratch link never falls back to npm -g, which would
#     install over the live box's global t3.
reset
out=$(
  export PATH="$WORK/linkdir:$WORK/stubs:/usr/bin:/bin" CALLS LINK
  export T3_VERSIONS_DIR="$VERS" T3_LINK="$LINK" T3_STATE_DIR="$STATE" T3_LEGACY_DIR="$WORK/legacy"
  # shellcheck source=scripts/t3-safe-restart.sh
  . "$HERE/t3-safe-restart.sh"
  target=0.1.9 last_good=0.1.8
  rollback_binary; echo "rc=$?"
)
grep -q '^npm i -g' "$CALLS" && bad "scratch rollback: ran npm -g" || ok "scratch rollback: no npm -g"
[[ "$out" == *"ROLLBACK FAILED"* && "$out" != *"rc=0"* ]] && ok "scratch rollback: fails and says so" || bad "scratch rollback: output: $out"

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
