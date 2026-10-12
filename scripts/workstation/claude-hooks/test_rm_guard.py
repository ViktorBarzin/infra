#!/usr/bin/env python3
"""Tests for rm-guard.py, the PreToolUse(Bash) guard for the shapes Claude
Code's own rm checks ask a person about even in bypass mode: rm -r on a path
an empty variable would turn into / or a top-level directory, and a wrapped
shell -c script in a command that joins with && or ||.

Run: python3 test_rm_guard.py

The blocked cases are the shape that raised "approve this command" in bypass
sessions on 2026-10-12, and the shapes that made Claude Code 2.1.296 ask in a
scratch session started with --dangerously-skip-permissions. The allowed cases
are ones that same session ran without asking, plus the ${VAR:?} rewrite the
guard tells the agent to use.

The cd-then-glob cases come from headless `claude -p
--dangerously-skip-permissions` runs, where an ask comes back as an error.
"""
import importlib.util
import json
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("rm_guard", os.path.join(HERE, "rm-guard.py"))
rm_guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rm_guard)
check = rm_guard.check

BLOCKED = [
    # 2026-10-12 01:43, the zero-downtime-deployment session, trimmed.
    "S=/var/tmp/claude-1000/x/scratchpad/tfval; for b in f1-stream-b0 f1-stream-roles; "
    "do rm -rf $S/$b; mkdir -p $S/$b; done",
    # Asked in the scratch session.
    "S=.; for b in z; do rm -rf $S/$b; done",
    "S=.; for b in q; do rm -rf $S/$b/sub; done",
    # The same danger with no loop: nothing in the command sets the variable.
    "rm -rf $X/$Y",
    "rm -rf $X/*",
    "rm -rf ${X}/${Y}",
    "rm -rf \"$X/$Y\"",
    "rm -Rf $X/$Y",
    "rm -fr $X/$Y",
    "rm --recursive --force $X/$Y",
    "sudo rm -rf $X/$Y",
    "cd /tmp && rm -rf $X/$Y",
    "while read d; do rm -rf $base/$d; done < list",
    "if true; then rm -rf $X/$Y; fi",
    # An assignment made inside the loop does not count either.
    "for b in a; do S=.; rm -rf $S/$b; done",
    # $(...) is not a literal, so the variable stays unknown.
    "S=$(pwd); for b in a; do rm -rf $S/$b; done",
    "rm -rf ${X:-}/$Y",
    # A # inside a word is not a comment.
    "P=x; for b in a; do rm -rf ${P#pod/}/$b; done",
]

ALLOWED = [
    # Ran without asking in the scratch session.
    "S=.; b=x; rm -rf $S/$b",
    "S=.; rm -rf ${S}/q",
    "rm -rf $HOME/zz-rmcal-nonexistent",
    "d=$(mktemp -d); rm -rf $d",
    "rm -rf $RMCAL_X",
    "for b in q; do rm -rf ./$b; done",
    "for b in q; do rm -rf $b; done",
    "rm -f $X/zz",
    # The rewrite the block message asks for.
    "S=.; for b in x; do rm -rf \"${S:?}/${b:?}\"; done",
    "rm -rf \"${X:?}/${Y:?}\"",
    "rm -rf \"${X:?not set}\"/\"${Y:?}\"",
    "rm -rf ${X:-/tmp/fallback}/$Y",
    # Ordinary removals.
    "rm -rf node_modules dist",
    "rm -rf /tmp/build-123",
    "rm -rf ./out/$name",
    "rm -rf build/$target",
    "rm file.txt",
    # The words inside data, not a command.
    "echo 'rm -rf $X/$Y'",
    "git commit -m \"note: rm -rf $X/$Y is dangerous\"",
    "cat <<'EOF'\nrm -rf $X/$Y\nEOF",
    "grep -n 'rm -rf $S/$b' notes.md",
    # A comment is not a command.
    "ls  # rm -rf $X/$Y",
]


# A shell -c script wrapped by another command (kubectl exec, docker exec)
# that also takes a variable, anywhere in a command that joins with && or ||.
# Claude Code 2.1.296 says it "could not check the script for dangerous
# removals" and asks, even in bypass mode and with no rm in the script. The
# first is the paperless session's command from 2026-10-12 02:48, trimmed.
BLOCKED_SHELL_C = [
    "P=$(kubectl -n paperless-ngx get pod -l app=paperless-ngx -o name | head -1); "
    "kubectl -n paperless-ngx cp ./ai1.py ${P#pod/}:/tmp/ai1.py -c paperless-ngx && "
    "kubectl -n paperless-ngx exec $P -c paperless-ngx -- sh -c "
    "'cd /usr/src/paperless/src && python3 manage.py shell < /tmp/ai1.py' 2>&1 | tail -8",
    "P=x; echo ${P} && kubectl -n ns exec $P -- sh -c 'echo hi'",
    "P=x; echo \"${P#pod/}\" && kubectl -n ns exec \"$P\" -- sh -c 'echo hi'",
    "P=x; false || kubectl -n ns exec $P -- sh -c 'echo hi'",
    "P=$(echo x); true && kubectl -n ns exec $P -- bash -c 'echo hi'",
    "P=x; echo ${P} || exit 1; kubectl -n ns exec $P -- sh -c 'echo hi'",
    "sudo kubectl -n ns exec $P -- sh -c 'echo hi' && echo done",
    "docker exec $C bash -lc 'echo hi' && echo done",
]

# Ran without asking in the same session.
ALLOWED_SHELL_C = [
    "P=x; echo ${P#pod/}; kubectl -n ns exec $P -- sh -c 'echo hi'",
    "P=$(kubectl get pod -o name); kubectl -n ns exec $P -c c -- sh -c 'cd /tmp && echo hi'",
    "kubectl -n ns cp ./a.py x:/tmp/a.py -c box && kubectl -n ns exec x -c box -- sh -c 'echo hi'",
    "P=x; echo ${P#pod/} && kubectl -n ns exec $P -- python3 -c 'print(1)'",
    "P=x; echo ${P#pod/} && sh -c 'echo hi'",
    "P=x; true && env X=$P sh -c 'echo hi'",
    "P=x; true && sh -c 'echo hi' $P",
    "echo ${HOME#/} && sh -c 'echo hi'",
    # The rewrites the block message asks for.
    "set -e; P=x; echo ${P}; kubectl -n ns exec $P -- sh -c 'echo hi'",
    "P=x; if echo ${P}; then kubectl -n ns exec $P -- sh -c 'echo hi'; fi",
    # && inside the quoted script, or inside a heredoc, is not the outer chain.
    "kubectl -n ns exec $P -- sh -c 'cd /tmp && echo hi'",
    "cat > a.sh <<'EOF'\nx && y\nEOF\nkubectl exec $P -- sh -c 'echo hi'",
]


# rm of a whole directory's contents (the last path part is exactly *) after a
# cd Claude Code cannot follow. It says "This command changes directories
# before the removal, so the relative glob target cannot be statically
# resolved" and asks, even for rm -f. The first is from the renovate-upgrades
# session's subagent on 2026-10-12 06:37, trimmed; it asked four times.
BLOCKED_CD_GLOB = [
    "S=/var/tmp/x/scratchpad/kt; cd $S && rm -f out/*; timeout 300 docker run --rm "
    "-v $S:/w -w /w kyverno-cli apply rendered/a.yaml -o out/g.yaml",
    "S=/tmp/kt; cd $S; rm -f out/*",
    "S=/tmp/kt; cd \"$S\" && rm -f -- out/*",
    "S=/tmp/kt; cd \"${S:?}\" && rm -f out/*",
    "S=/tmp/kt; cd $S && rm -f ./out/*",
    "S=/tmp/kt; cd $S/sub && rm -f ../out/*",
    "S=/tmp/kt; cd $S && rm -rf out/*",
    "S=/tmp/kt; cd $S && rm -f out/* out/a.yaml",
    "S=/tmp/kt; cd $S || exit; rm -f out/*",
    "S=/tmp/kt; cd $S && echo x && rm -f out/*",
    "S=/tmp/kt; for f in a; do cd $S && rm -f out/*; done",
    "S=/tmp/kt; cd $S && rm -f \"out\"/*",
    "cd kt && rm -f out/*",
    "pushd /tmp/kt && rm -f out/*",
    "cd ~ && cd /tmp/kt && rm -f out/*",
    "cd - >/dev/null; cd /tmp/kt && rm -f out/*",
    # A bare * asks with or without a cd.
    "rm -f *",
    "cd /tmp/kt/out && rm -f *",
    "cd /tmp/kt/out && rm -f ./*",
    "cd /tmp/kt && cd sub && rm -f *",
    # $PWD counts as possibly empty here.
    "S=/tmp/kt; cd $S && rm -f \"$PWD\"/*",
]

# Ran without asking in the same runs.
ALLOWED_CD_GLOB = [
    "cd /tmp/kt && rm -f out/*",
    "cd /tmp/kt && rm -f ./out/*",
    "cd /tmp/kt && rm -rf out/*",
    "cd /tmp/kt && rm -f sub/* && rm -f out/*",
    "S=/tmp/kt; rm -f $S/out/*",
    "S=/tmp/kt; rm -f $S/out/* ; cd $S && ls",
    "S=/tmp/kt; cd $S && rm -f \"$S\"/out/*",
    "rm -f kt/out/*",
    "rm -f ./kt/out/*",
    # Only a bare * as the last part counts.
    "S=/tmp/kt; cd $S && rm -f out/*.yaml",
    "S=/tmp/kt; cd $S && rm -f out/a*",
    "S=/tmp/kt; cd $S && rm -f out/?.yaml",
    "S=/tmp/kt; cd $S && rm -f out/{a,b}.yaml",
    "cd /tmp/kt && rm -f */b",
    "cd /tmp/kt/out && rm -f *.yaml",
    "S=/tmp/kt; cd $S && rm -f out/a.yaml",
    "S=/tmp/kt; cd $S && rm -rf out",
    "S=/tmp/kt; cd $S && find out -mindepth 1 -delete",
    # The rewrites the block message asks for.
    "S=/tmp/kt; cd $S && rm -f \"${PWD:?}\"/out/*",
    "S=/tmp/kt; cd $S && rm -f -- \"${PWD:?}\"/out/*",
    "cd /tmp/kt/out && rm -f \"${PWD:?}\"/*",
    "S=/tmp/kt; cd $S && rm -f \"${PWD:?}\"/*",
    # Words in data, not a command.
    "S=/tmp/kt; cd $S && echo 'rm -f out/*'",
]


class RmGuardTest(unittest.TestCase):
    def test_blocked_cd_glob(self):
        for cmd in BLOCKED_CD_GLOB:
            with self.subTest(cmd=cmd):
                self.assertIsNotNone(check(cmd), "should block")

    def test_allowed_cd_glob(self):
        for cmd in ALLOWED_CD_GLOB:
            with self.subTest(cmd=cmd):
                self.assertIsNone(check(cmd), "should allow")

    def test_cd_glob_message_names_the_fix(self):
        msg = check("S=/tmp/kt; cd $S && rm -f out/*")
        self.assertIn('rm -f "${PWD:?}"/out/*', msg)
        self.assertIn('rm -f "${PWD:?}"/*', check("rm -f ./*"))

    def test_blocked_shell_c(self):
        for cmd in BLOCKED_SHELL_C:
            with self.subTest(cmd=cmd):
                self.assertIsNotNone(check(cmd), "should block")

    def test_allowed_shell_c(self):
        for cmd in ALLOWED_SHELL_C:
            with self.subTest(cmd=cmd):
                self.assertIsNone(check(cmd), "should allow")

    def test_shell_c_message_names_the_fix(self):
        msg = check("P=x; echo ${P} && kubectl -n ns exec $P -- sh -c 'echo hi'")
        self.assertIn("set -e", msg)
        self.assertIn("$P", msg)

    def test_blocked(self):
        for cmd in BLOCKED:
            with self.subTest(cmd=cmd):
                self.assertIsNotNone(check(cmd), "should block")

    def test_allowed(self):
        for cmd in ALLOWED:
            with self.subTest(cmd=cmd):
                self.assertIsNone(check(cmd), "should allow")

    def test_message_names_the_variable_and_the_fix(self):
        msg = check("S=.; for b in z; do rm -rf $S/$b; done")
        self.assertIn("$S/$b", msg)
        self.assertIn("${S:?}", msg)
        self.assertIn("${b:?}", msg)

    def test_hook_exit_codes(self):
        def run(payload):
            return subprocess.run([sys.executable, os.path.join(HERE, "rm-guard.py")],
                                  input=json.dumps(payload), capture_output=True, text=True)
        blocked = run({"tool_name": "Bash", "tool_input": {"command": "rm -rf $X/$Y"}})
        self.assertEqual(blocked.returncode, 2)
        self.assertIn("rm-guard", blocked.stderr)
        self.assertEqual(run({"tool_name": "Bash", "tool_input": {"command": "rm -rf dist"}}).returncode, 0)
        self.assertEqual(run({"tool_name": "Read", "tool_input": {}}).returncode, 0)
        bad = subprocess.run([sys.executable, os.path.join(HERE, "rm-guard.py")],
                             input="not json", capture_output=True, text=True)
        self.assertEqual(bad.returncode, 0)


if __name__ == "__main__":
    unittest.main()
