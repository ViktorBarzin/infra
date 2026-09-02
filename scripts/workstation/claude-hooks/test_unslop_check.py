#!/usr/bin/env python3
"""Tests for unslop-check.py — the Stop-event writing-style check.

Run: python3 test_unslop_check.py
"""
import importlib.util
import json
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HOOK = os.path.join(HERE, "unslop-check.py")
spec = importlib.util.spec_from_file_location("unslop_check", HOOK)
unslop = importlib.util.module_from_spec(spec)
spec.loader.exec_module(unslop)
tells = unslop.tells


def names(reply):
    """Just the check names that fired, without the counts and samples."""
    return {t.split(" x")[0].split(":")[0] for t in tells(reply)}


class MechanicalTells(unittest.TestCase):
    def test_em_dash(self):
        self.assertIn("em dash", names("The rollout finished — 3 pods are up."))

    def test_clean_prose_passes(self):
        self.assertEqual(tells("The rollout finished. 3 pods are up."), [])

    def test_curly_quote(self):
        self.assertIn("curly quote", names("It ’s done."))

    def test_banned_word(self):
        self.assertIn("banned word", names("Additionally, the pods are up."))

    def test_metaphor_noun(self):
        self.assertIn("abstract metaphor noun", names("Postgres is the substrate here."))

    def test_not_just_x_but_y(self):
        self.assertIn("'not just X but Y'", names("Not just faster, but cheaper."))

    def test_bold_label_bullet_colon_inside_bold(self):
        self.assertIn("bold-label-then-colon bullet", names("- **Latency:** it improved."))

    def test_bold_label_bullet_colon_outside_bold(self):
        self.assertIn("bold-label-then-colon bullet", names("- **Latency**: it improved."))

    def test_chatbot_phrase(self):
        self.assertIn("chatbot phrase", names("Fixed. I hope this helps!"))

    def test_filler_phrase(self):
        self.assertIn("filler phrase", names("I restarted it in order to clear the cache."))


class QuotedTextIsExempt(unittest.TestCase):
    """A pasted log line or someone else's words are not Claude's own prose."""

    def test_fenced_block(self):
        self.assertEqual(tells("Log:\n```\nerror — evicted\n```\nNothing else."), [])

    def test_inline_code(self):
        self.assertEqual(tells("It printed `err — evicted` and stopped."), [])

    def test_blockquote(self):
        self.assertEqual(tells("You said:\n> do it — now\n\nDone."), [])

    def test_url_is_not_a_filler_phrase(self):
        self.assertEqual(tells("See https://example.com/in-order-to/guide for the steps."), [])


class CyrillicKeepsItsDashes(unittest.TestCase):
    """In Bulgarian and Russian the dash is standard punctuation, not an AI tell."""

    def test_bulgarian_dash_passes(self):
        reply = ("Готово — трите пода работят. Рестартирах ги и всичко "
                 "изглежда наред сега.")
        self.assertEqual(tells(reply), [])

    def test_english_tells_still_fire_in_cyrillic_text(self):
        reply = ("Готово. Additionally, всичко работи и трите пода са "
                 "вдигнати без проблем.")
        self.assertIn("banned word", names(reply))

    def test_a_stray_cyrillic_word_does_not_exempt_english(self):
        self.assertIn("em dash", names("The pod — под in Bulgarian — restarted."))


class Length(unittest.TestCase):
    def test_long_prose_is_flagged(self):
        found = tells("The pod restarted after the node came back. " * 60)
        self.assertTrue(any(t.startswith("too long") for t in found))

    def test_table_rows_do_not_count_as_prose(self):
        table = "| a | b |\n|---|---|\n" + "| the node came back and the pod restarted | yes |\n" * 60
        self.assertEqual(tells("Here it is.\n\n" + table), [])

    def test_code_does_not_count_as_prose(self):
        self.assertEqual(tells("Here:\n\n```\n" + "x = 1  # a line of code\n" * 200 + "```\n"), [])


class BlockContract(unittest.TestCase):
    """The Stop-hook protocol: block on stdout, exit 0, one retry only."""

    def run_hook(self, payload):
        proc = subprocess.run([sys.executable, HOOK], input=json.dumps(payload),
                              capture_output=True, text=True)
        return proc.returncode, proc.stdout.strip()

    def test_blocks_dirty_reply(self):
        code, out = self.run_hook({"last_assistant_message": "Done — up.",
                                   "stop_hook_active": False})
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["decision"], "block")

    def test_silent_on_clean_reply(self):
        code, out = self.run_hook({"last_assistant_message": "Done. Up.",
                                   "stop_hook_active": False})
        self.assertEqual((code, out), (0, ""))

    def test_retry_is_never_blocked_again(self):
        code, out = self.run_hook({"last_assistant_message": "Done — up.",
                                   "stop_hook_active": True})
        self.assertEqual((code, out), (0, ""))

    def test_missing_reply_and_transcript_is_not_an_error(self):
        code, out = self.run_hook({"stop_hook_active": False})
        self.assertEqual((code, out), (0, ""))

    def test_garbage_stdin_is_not_an_error(self):
        proc = subprocess.run([sys.executable, HOOK], input="not json",
                              capture_output=True, text=True)
        self.assertEqual((proc.returncode, proc.stdout.strip()), (0, ""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
