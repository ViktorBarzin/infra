#!/usr/bin/env python3
"""Tests for scan-guard.py, the PreToolUse(Bash) guard against whole-disk scans.

Run: python3 test_scan_guard.py

The blocked cases are the shapes that ran on 2026-10-11, taken from that day's
transcripts: a subagent's `xargs grep` over every transcript at 07:14, and the
`find /` and `du` calls among the afternoon's ~80 sessions. The allowed cases
are what an agent does all day and must keep doing: greps inside a repo, reads
of one named transcript, and the same words inside quotes.
"""
import importlib.util
import json
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("scan_guard", os.path.join(HERE, "scan-guard.py"))
scan_guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scan_guard)
check = scan_guard.check

T = "/home/wizard/.claude/projects/-home-wizard-code/0279788c-224d-481c-bc6a-1b6b3728b926.jsonl"

BLOCKED_TRANSCRIPTS = [
    # 07:14 on 2026-10-11, verbatim apart from the patterns.
    "cd ~/.claude/projects; ls -t -- */*.jsonl | head -200 | xargs -d '\\n' grep -l 'isCompactSummary' 2>/dev/null | head -3",
    "cd ~/.claude/projects; F=$(ls -t */*.jsonl | head -200 | xargs grep -l 'compact')",
    "cd ~/.claude/projects; grep -c compact */*.jsonl",
    "cd ~/.claude/projects && rg compact",
    "grep -l foo ~/.claude/projects/*/*.jsonl",
    "grep -rn foo ~/.claude/projects",
    "grep -rln foo /home/wizard/.claude/projects/-home-wizard-code/",
    "rg -l 'foo' $HOME/.claude/projects",
    "sudo grep -l foo /home/*/.claude/projects/*/*.jsonl",
    "ugrep -r foo ~/.claude/projects",
    "jq -r .type ~/.claude/projects/-home-wizard-code/*.jsonl | sort | uniq -c",
    "cat ~/.claude/projects/*/*.jsonl | grep foo",
    "find ~/.claude/projects -name '*.jsonl' -exec grep -l foo {} +",
    "find ~/.claude/projects -name '*.jsonl' -newer x",
    "ls -t ~/.claude/projects/*/*.jsonl | head -50 | xargs grep -l foo",
    "timeout 60 grep -rl foo ~/.claude/projects",
    # Inside a loop or a conditional, missed by the first version.
    "for h in wizard emo; do sudo find /home/$h/.claude/projects -path '*/memory/*' -type f; done",
    "if true; then grep -rl x ~/.claude/projects; fi",
    # 06:39 on 2026-10-12, killed by devvm-io-guard after reading 29 MB. The
    # path reached grep through variables, so the first version never saw it.
    "T=$(tmux show-options -v -t renovate-upgrades @claude_transcript 2>/dev/null); echo \"$T\"; D=$(dirname \"$T\"); "
    "for id in toolu_01Sv toolu_01Cc; do f=$(grep -rl \"\\\"id\\\":\\\"$id\\\"\" \"$D\" 2>/dev/null | head -1); echo \"== $id in $f\"; done",
    "D=$(dirname \"$(tmux show-options -v @claude_transcript)\"); rg -l foo \"$D\"",
    "P=~/.claude/projects/-home-wizard-code; grep -l foo \"$P\"/*.jsonl",
    "P=/home/wizard/.claude/projects/-home-wizard-code; for f in \"$P\"/*.jsonl; do grep -q foo \"$f\" && echo $f; done",
    "for f in ~/.claude/projects/*/*.jsonl; do grep -l foo \"$f\"; done",
    # ~/.claude itself holds the transcripts.
    "grep -rl foo ~/.claude",
    "grep -rl \"'id':'toolu_01Sv'\" /home/wizard/.claude",
    "rg foo $HOME/.claude/",
    "sudo grep -rl foo /home/*/.claude",
    "cd ~/.claude && grep -rn foo .",
]

BLOCKED_WIDE = [
    "find / -name replay-checks-top.png 2>/dev/null | head",
    "find ~ -name '*.png'",
    "find $HOME -type f -newer x",
    "find /home -name AGENTS.md",
    "find ~ -maxdepth 5 -name x",
    "sudo -n find / -xdev -name foo",
    "du -sh ~",
    "du -sh ~/* | sort -h",
    "du -sh /home/*",
    "du -h --max-depth=1 /",
    "du -sh /",
    "grep -r foo /",
    "grep -rn TODO ~",
    "rg foo ~",
    "rg -l secret /home",
    "ls -R /",
    "while true; do du -sh ~; sleep 5; done",
    "{ find / -name x; } 2>/dev/null",
]

ALLOWED = [
    # One named transcript or tool-result file: wrap-up reads its own.
    "grep -n foo " + T,
    "cd ~/.claude/projects/-home-wizard-code && grep -c compact 0279788c-224d-481c-bc6a-1b6b3728b926.jsonl",
    "grep -o 'x' /home/wizard/.claude/projects/-home-wizard-code-terminal-lobby/54213bab-87ac-44b6-a170-cab397485341/tool-results/b8btevfl0.txt | head",
    "tail -n 50 " + T,
    "jq -r .type " + T + " | sort | uniq -c",
    "wc -l " + T,
    # A transcript path held in a variable is still one file.
    "T=$(tmux show-options -v @claude_transcript); grep -n foo \"$T\"",
    "T=$(tmux show-options -v @claude_transcript); tail -c 4000 \"$T\" | jq -r .type",
    # Small files under ~/.claude, and a repo's own .claude directory.
    "grep -n hooks ~/.claude/settings.json",
    "cat ~/.claude/settings.json | jq .hooks",
    "grep -rn description ~/.claude/skills/unslop",
    "ls ~/.claude",
    "find ~/.claude -maxdepth 2 -name settings.json",
    "grep -rn foo .claude",
    # From the replay of 3,424 real commands: one named file in a variable,
    # a pid found by its command line, and find listing recent config files.
    "F=/home/wizard/.claude/projects/-home-wizard-code/0164/tool-results/bsb1vvzsc.txt; grep -o -E 'autoMemory' \"$F\" | sort -u",
    "S=/home/wizard/.claude/projects/-home-wizard-code-infra/2a14/workflows/scripts/wave.js; grep -n step $S | head",
    "P=$(pgrep -f 'count.py /home/wizard/.claude/projects' | head -1); grep -e rchar /proc/$P/io",
    "find ~/.claude ~/.codex -maxdepth 4 -newermt '-20 minutes' -type f",
    # A loop over a handful of named files.
    "for f in a.txt b.txt; do grep -c x \"$f\"; done",
    # Listing is metadata only.
    "ls -t ~/.claude/projects/-home-wizard-code/*.jsonl | head -3",
    "find ~/.claude/projects -maxdepth 2 -name '*.jsonl' -mmin -60",
    # The words in quotes, as a pattern or a message.
    "cd ~/code && grep -rlI '\\.claude/projects' --exclude-dir=node_modules ~/.claude/skills .claude infra/scripts",
    "git commit -m 'scan-guard: block grep over ~/.claude/projects and find /'",
    "echo 'du -sh ~ is slow'",
    "grep -n 'find /' docs/x.md",
    # Ordinary work.
    "grep -rn foo .",
    "grep -rn foo ~/code/infra/stacks",
    "rg foo src/",
    "find . -name '*.py'",
    "find ~/code -maxdepth 2 -name AGENTS.md",
    "find ~ -maxdepth 2 -name '.zshrc'",
    "find / -maxdepth 1 -type d",
    "du -sh ~/code/infra",
    "du -sh .",
    "ls -la /",
    "ls -R src",
    "homelab claude-usage --session 0279788c",
    "git grep -n foo",
    # Heredoc bodies are data.
    "python3 - <<'EOF'\nimport glob\n# grep -r foo ~/.claude/projects\nEOF",
    # Unparseable input is never blocked.
    "grep 'unterminated ~/.claude/projects",
]


class Blocks(unittest.TestCase):
    def test_transcript_scans(self):
        for cmd in BLOCKED_TRANSCRIPTS:
            with self.subTest(cmd=cmd):
                hit = check(cmd)
                self.assertIsNotNone(hit, cmd)
                self.assertIn("homelab claude-usage", hit)

    def test_whole_disk_scans(self):
        for cmd in BLOCKED_WIDE:
            with self.subTest(cmd=cmd):
                hit = check(cmd)
                self.assertIsNotNone(hit, cmd)
                self.assertIn("narrow", hit)


    def test_a_variable_path_is_named_in_the_message(self):
        hit = check('D=$(dirname "$(tmux show-options -v @claude_transcript)"); '
                    'grep -rl foo "$D"')
        self.assertIn("from-var-D", hit)


class Allows(unittest.TestCase):
    def test_normal_work(self):
        for cmd in ALLOWED:
            with self.subTest(cmd=cmd):
                self.assertIsNone(check(cmd), cmd)


class Hook(unittest.TestCase):
    """The stdin/exit-code contract Claude Code relies on."""

    def run_hook(self, payload):
        return subprocess.run(
            [sys.executable, os.path.join(HERE, "scan-guard.py")],
            input=payload, capture_output=True, text=True, timeout=10)

    def test_block_exits_2_with_the_reason_on_stderr(self):
        r = self.run_hook(json.dumps({"tool_name": "Bash",
                                      "tool_input": {"command": "du -sh ~"}}))
        self.assertEqual(r.returncode, 2)
        self.assertIn("BLOCKED by scan-guard", r.stderr)

    def test_allow_exits_0(self):
        r = self.run_hook(json.dumps({"tool_name": "Bash",
                                      "tool_input": {"command": "ls"}}))
        self.assertEqual(r.returncode, 0)

    def test_bad_input_is_never_a_block(self):
        self.assertEqual(self.run_hook("not json").returncode, 0)
        self.assertEqual(self.run_hook(json.dumps({"tool_name": "Read"})).returncode, 0)


if __name__ == "__main__":
    unittest.main()
