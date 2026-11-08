#!/usr/bin/env bash
# Tests for claude-skills-update's reconcile and patch logic.
# Run: bash playbooks/files/devvm/claude-skills-update-test.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
. "$HERE/claude-skills-update"

FAILS=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; FAILS=$((FAILS + 1)); fi; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A home whose lockfile lists three mattpocock skills and one of the user's
# own, with domain-modeling's folder missing (the 2026-11 state: the lock
# said installed, the folder was gone, and nothing ever reinstalled it).
make_home() {
  local home="$1"
  mkdir -p "$home/.agents/skills" "$home/.claude/skills"
  cat > "$home/.agents/.skill-lock.json" <<'JSON'
{"skills": {
  "grilling": {"source": "mattpocock/skills"},
  "teach": {"source": "mattpocock/skills"},
  "domain-modeling": {"source": "mattpocock/skills"},
  "file-issue": {"source": "viktor/own"}
}}
JSON
  for s in grilling teach; do
    mkdir -p "$home/.agents/skills/$s"
    echo "# $s" > "$home/.agents/skills/$s/SKILL.md"
    ln -s "../../.agents/skills/$s" "$home/.claude/skills/$s"
  done
}

# --- 1) a skill counts as installed only when its folder is there ----------
H1="$WORK/h1"; make_home "$H1"
check "lockfile lists all three matt skills" "$(matt_skills "$H1" | tr '\n' ' ')" "domain-modeling grilling teach "
check "only skills with a SKILL.md count as present" "$(present_matt_skills "$H1" | tr '\n' ' ')" "grilling teach "

# --- 2) a patch that no longer applies gets a fresh upstream copy ----------
pristine='line one
If possible, open the lesson file for the user by running a CLI command.
line three'
H2="$WORK/h2"; make_home "$H2"
SHARE="$WORK/share"; mkdir -p "$SHARE/u/patches"
# The live file still carries an OLD version of our edit, so the current patch
# applies neither forwards nor in reverse.
printf 'line one\nPush lessons to ~/code (old edit).\nline three\n' > "$H2/.agents/skills/teach/SKILL.md"
cat > "$SHARE/u/patches/teach.patch" <<'PATCH'
--- a/SKILL.md
+++ b/SKILL.md
@@ -1,3 +1,3 @@
 line one
-If possible, open the lesson file for the user by running a CLI command.
+Push lessons to ~/code/learn (new edit).
 line three
PATCH
REINSTALLED=""
# Stand-in for `npx skills add mattpocock/skills -s <name>`: writes upstream text.
reinstall_skill() { REINSTALLED="$REINSTALLED $2"; printf '%s\n' "$pristine" > "$3/.claude/skills/$2/SKILL.md"; }
chown() { :; }
PROBLEMS=""
apply_patches u "$H2"
check "the stale skill was reinstalled from upstream" "$REINSTALLED" " teach"
check "the new patch is applied after the reinstall" "$(sed -n 2p "$H2/.agents/skills/teach/SKILL.md")" "Push lessons to ~/code/learn (new edit)."
check "no problem is reported when the retry works" "$PROBLEMS" ""

# --- 3) a patch that fails even on fresh upstream text is still reported ---
H3="$WORK/h3"; make_home "$H3"
printf 'something else entirely\n' > "$H3/.agents/skills/teach/SKILL.md"
pristine='upstream rewrote the whole file'
REINSTALLED=""; PROBLEMS=""
apply_patches u "$H3"
check "it still tried a fresh copy once" "$REINSTALLED" " teach"
case "$PROBLEMS" in *"NO LONGER APPLIES"*) got=reported ;; *) got=silent ;; esac
check "a real conflict is reported" "$got" "reported"

# --- 4) an already-applied patch is left alone, no reinstall ---------------
H4="$WORK/h4"; make_home "$H4"
printf 'line one\nPush lessons to ~/code/learn (new edit).\nline three\n' > "$H4/.agents/skills/teach/SKILL.md"
REINSTALLED=""; PROBLEMS=""
apply_patches u "$H4"
check "an applied patch needs no reinstall" "$REINSTALLED" ""
check "and reports nothing" "$PROBLEMS" ""

[ "$FAILS" -eq 0 ] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
