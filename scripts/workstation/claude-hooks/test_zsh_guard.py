#!/usr/bin/env python3
"""Tests for zsh-guard.py — the PreToolUse(Bash) zsh-semantics guard.

Run: python3 test_zsh_guard.py
"""
import importlib.util
import json
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("zsh_guard", os.path.join(HERE, "zsh-guard.py"))
zsh_guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(zsh_guard)
check = zsh_guard.check
rewrite = zsh_guard.rewrite


class WordSplitting(unittest.TestCase):
    """zsh does not word-split unquoted expansions: `F='-a -b'; cmd $F` -> ONE argv."""

    def test_git_crypt_flags_via_variable(self):
        # The exact shape that has recurred on this devvm for months.
        cmd = ('GC="-c filter.git-crypt.smudge=cat -c filter.git-crypt.required=false" '
               '&& git $GC worktree add x')
        self.assertIn("word-split", (check(cmd) or ("", ""))[1])

    def test_simple_flag_list(self):
        self.assertIsNotNone(check("FLAGS='-a -b'; mycmd $FLAGS"))

    def test_whole_command_in_a_variable(self):
        self.assertIsNotNone(check('G="git -c foo=bar"; $G add file'))

    def test_braced_expansion(self):
        self.assertIsNotNone(check('F="-a -b"; cmd ${F}'))

    # --- must NOT fire ---
    def test_quoted_use_is_fine(self):
        self.assertIsNone(check('MSG="fix things properly"; git commit -m "$MSG"'))

    def test_command_substitution_then_quoted_use(self):
        self.assertIsNone(check(
            'TOKEN=$(vault kv get -field=t secret/x); curl -H "Authorization: Bearer $TOKEN" https://a'))

    def test_single_word_value(self):
        self.assertIsNone(check("F=abc; echo $F"))

    def test_path_value_is_not_a_flag_list(self):
        self.assertIsNone(check('D="/home/wizard/code"; cd $D'))

    def test_inlined_flags(self):
        self.assertIsNone(check(
            "git -c filter.git-crypt.smudge=cat -c filter.git-crypt.required=false worktree add x"))

    def test_explicit_zsh_split_is_allowed(self):
        self.assertIsNone(check('F="-a -b"; cmd ${=F}'))

    def test_array_expansion_is_allowed(self):
        self.assertIsNone(check('F=(-a -b); cmd "${F[@]}"'))


class RewriteToExplicitSplit(unittest.TestCase):
    """An unquoted flag-list variable is rewritten to zsh's ${=VAR}, which
    splits it the way bash would, so the command runs instead of bouncing."""

    G = 'G="git -c filter.git-crypt.smudge=cat -c filter.git-crypt.required=false"; '

    def test_command_prefix_variable(self):
        self.assertEqual(rewrite(self.G + "$G add x && $G commit -q"),
                         self.G + "${=G} add x && ${=G} commit -q")

    def test_braced_form(self):
        self.assertEqual(rewrite('F="-a -b"; cmd ${F} x'), 'F="-a -b"; cmd ${=F} x')

    def test_push_retry_loop_from_the_renovate_workflow(self):
        cmd = (self.G + "\nfor i in $(seq 1 10); do if $G push -q forgejo HEAD:master 2>&1; "
               "then echo pushed; break; fi; $G fetch -q forgejo && $G rebase -q forgejo/master; "
               "done; $G log --oneline -1")
        out = rewrite(cmd)
        self.assertNotIn("$G ", out)
        self.assertEqual(out.count("${=G}"), 4)
        self.assertIsNone(check(out))

    def test_use_inside_command_substitution(self):
        self.assertEqual(rewrite(self.G + 'echo "$($G log -1)"'),
                         self.G + 'echo "$(${=G} log -1)"')

    def test_heredoc_body_is_left_alone(self):
        cmd = self.G + "$G commit -F - <<'EOF'\nuse $G here\nEOF"
        self.assertEqual(rewrite(cmd),
                         self.G + "${=G} commit -F - <<'EOF'\nuse $G here\nEOF")

    # --- left unchanged ---
    def test_quoted_use(self):
        self.assertIsNone(rewrite(self.G + '"$G" status'))

    def test_single_quoted_bash_c(self):
        self.assertIsNone(rewrite(self.G + "bash -c '$G status'"))

    def test_message_variable(self):
        self.assertIsNone(rewrite('MSG="fix things properly"; echo $MSG'))

    def test_already_explicit(self):
        self.assertIsNone(rewrite('F="-a -b"; cmd ${=F}'))

    def test_form_it_cannot_rewrite_still_blocks(self):
        cmd = 'F="-a -b"; cmd ${F:-x}'
        self.assertIsNone(rewrite(cmd))
        self.assertIsNotNone(check(cmd))


class HookOutput(unittest.TestCase):
    """main() as Claude Code runs it: JSON on stdin, decision on stdout/exit."""

    def run_hook(self, command):
        payload = {"tool_name": "Bash",
                   "tool_input": {"command": command, "description": "d", "timeout": 5000}}
        return subprocess.run([sys.executable, os.path.join(HERE, "zsh-guard.py")],
                              input=json.dumps(payload), capture_output=True, text=True)

    def test_rewrite_is_returned_as_updated_input(self):
        r = self.run_hook('F="-a -b"; cmd $F')
        self.assertEqual(r.returncode, 0)
        out = json.loads(r.stdout)["hookSpecificOutput"]
        self.assertEqual(out["hookEventName"], "PreToolUse")
        self.assertNotIn("permissionDecision", out)   # normal permission checks still run
        self.assertEqual(out["updatedInput"],
                         {"command": 'F="-a -b"; cmd ${=F}', "description": "d", "timeout": 5000})

    def test_clean_command_prints_nothing(self):
        r = self.run_hook("git status")
        self.assertEqual((r.returncode, r.stdout), (0, ""))

    def test_glob_still_blocks(self):
        r = self.run_hook("echo fix(x): y")
        self.assertEqual(r.returncode, 2)
        self.assertIn("BLOCKED by zsh-guard", r.stderr)


class ParenGlobbing(unittest.TestCase):
    """Unquoted `word(...)` is a zsh glob -> 'no matches found', silently empty."""

    def test_unquoted_conventional_commit_subject(self):
        hit = check("git commit -m fix(scope): thing")
        self.assertIsNotNone(hit)
        self.assertIn("glob", hit[1])

    def test_unquoted_in_echo(self):
        self.assertIsNotNone(check("echo feat(api): add endpoint"))

    # --- must NOT fire ---
    def test_quoted_subject(self):
        self.assertIsNone(check('git commit -m "fix(scope): thing"'))

    def test_single_quoted_subject(self):
        self.assertIsNone(check("git commit -m 'fix(scope): thing'"))

    def test_heredoc_body_is_not_globbed(self):
        # The repo's own commit convention — must never be blocked.
        cmd = "git commit -F - <<'EOF'\nfix(scope): thing\n\nbody line\nEOF"
        self.assertIsNone(check(cmd))

    def test_unquoted_heredoc_body(self):
        cmd = "cat <<EOF\nfeat(x): y\nEOF"
        self.assertIsNone(check(cmd))

    def test_array_assignment(self):
        self.assertIsNone(check("arr=(a b c); echo ${arr[1]}"))

    def test_function_definition(self):
        self.assertIsNone(check("foo() { echo hi; }; foo"))

    def test_arithmetic_expansion(self):
        self.assertIsNone(check("x=$((1+2)); echo $x"))

    def test_command_substitution(self):
        self.assertIsNone(check("echo $(date +%s)"))

    def test_subshell(self):
        self.assertIsNone(check("(cd /tmp && ls)"))

    def test_parens_inside_quoted_program_text(self):
        self.assertIsNone(check('python3 -c "print(1)"'))
        self.assertIsNone(check("awk '{print $1}' file"))

    def test_glob_with_leading_space_is_a_subshell_not_a_pattern(self):
        self.assertIsNone(check("ls && (echo a)"))


class ProcessSubstitution(unittest.TestCase):
    """zsh supports <(...) and >(...) natively, the same as bash, so they pass."""

    def test_unquoted_input_process_subst(self):
        self.assertIsNone(check("cat <(seq 1 10)"))

    def test_diff_of_two_process_substs(self):
        self.assertIsNone(check("diff <(sort file1) <(sort file2)"))

    def test_join_from_the_renovate_workflow(self):
        # Blocked five times on 2026-10-15 by the check this replaced.
        self.assertIsNone(check(
            "join -t$'\\t' <(sort $S/old.txt) <(sort $S/new.txt) | awk -F'\\t' '$2!=$3'"))

    def test_output_process_subst(self):
        self.assertIsNone(check("cmd >(tee /tmp/log)"))

    def test_comparison_operators_not_confused(self):
        self.assertIsNone(check("if [ $x -lt 10 ]; then echo low; fi"))
        self.assertIsNone(check("result=$((x > 5 ? a : b))"))


class NestedQuotes(unittest.TestCase):
    """A quoted string inside "$(...)" opens a new quoting level, it does not
    close the outer one. Reading it as closing made `count(*)` look unquoted."""

    def test_sql_count_inside_quoted_command_substitution(self):
        # Blocked three times in renovate-upgrades, 2026-10-11 to 10-12.
        self.assertIsNone(check(
            'until [ "$(kubectl -n dbaas exec $P -c postgres -- psql -d woodpecker -Atc '
            '"select count(*) from pipelines where status in (\'running\',\'pending\')" '
            '2>/dev/null)" = 0 ]; do sleep 15; done'))

    def test_function_call_inside_quoted_command_substitution(self):
        self.assertIsNone(check(
            'until [ "$(q "select count(*) from pipelines;")" = 0 ]; do sleep 20; done'))

    def test_nested_substitution_two_levels(self):
        self.assertIsNone(check('echo "$(echo "$(echo "fix(x): y")")"'))

    def test_unquoted_glob_inside_substitution_still_fires(self):
        self.assertIsNotNone(check('echo "$(echo fix(x): y)"'))

    def test_unquoted_glob_after_substitution_still_fires(self):
        self.assertIsNotNone(check('echo "$(date)" fix(x): y'))


class EscapedQuotes(unittest.TestCase):
    """Backslash-escaped quotes inside double-quoted strings."""

    def test_escaped_quote_in_double_string(self):
        # Should NOT be flagged as unquoted glob despite the \\"
        hit = check('echo "He said \\"hello world\\""')
        self.assertIsNone(hit)

    def test_git_log_format_with_escaped_quotes(self):
        # Real command that uses escaped quotes
        hit = check('git log --format="%an \\"<%ae>\\""')
        self.assertIsNone(hit)


class RealCommandsFromThisRepo(unittest.TestCase):
    """Regression net: real commands that must stay runnable."""

    CASES = [
        "kubectl get pods -n linkwarden -o wide",
        "git status --porcelain | head -20",
        'kubectl exec -n dbaas pg-cluster-2 -c postgres -- psql -d linkwarden -tAc "select 1"',
        "terraform fmt -check -diff .",
        'homelab memory store "content here" --tags a,b --importance 0.7',
        "for db in a b c; do echo $db; done",
        'find / -maxdepth 6 -type d -name "archives" 2>/dev/null | head',
        "TOKEN=$(vault kv get -field=woodpecker_api_token secret/ci/global); echo ok",
        'cat "<(seq 1 10)" | wc -l',
        'diff <(sort file1) <(sort file2)',
    ]

    def test_none_are_blocked(self):
        for cmd in self.CASES:
            with self.subTest(cmd=cmd):
                self.assertIsNone(check(cmd))


if __name__ == "__main__":
    unittest.main(verbosity=2)
