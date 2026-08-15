#!/usr/bin/env python3
"""Tests for zsh-guard.py — the PreToolUse(Bash) zsh-semantics guard.

Run: python3 test_zsh_guard.py
"""
import importlib.util
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("zsh_guard", os.path.join(HERE, "zsh-guard.py"))
zsh_guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(zsh_guard)
check = zsh_guard.check


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
    ]

    def test_none_are_blocked(self):
        for cmd in self.CASES:
            with self.subTest(cmd=cmd):
                self.assertIsNone(check(cmd))


if __name__ == "__main__":
    unittest.main(verbosity=2)
