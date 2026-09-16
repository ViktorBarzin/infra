#!/usr/bin/env python3
"""Regression tests for the agent-api trace shipper and its alert.

Covers four defects found in review of commit eb3aca8c, each of which was
silent in the sense that the config looked right and nothing would have said
otherwise:

  1. `action_on_failure: fudge` pinned an unparseable line to the LAST GOOD
     event timestamp + 1ns, i.e. frozen in the past, which destroys the
     replay ordering the stage exists for and eventually trips Loki's
     reject_old_samples_max_age (live: 1w). `skip` keeps promtail's read time.
  2. The alert runbook sent the operator to the promtail journal to see a
     timestamp parse failure. Promtail logs those at level=debug and this
     shipper runs log_level: warn, so the journal is guaranteed empty.
  3. A single `[28d] > 0` enable gate arms on one trace line ever written, so
     the design's own end-to-end smoke test produced a 21-day standing warning.
  4. The pipeline shipped `request.text` and `tool_calls[].input` verbatim into
     a Loki whose ingress is auth = "none" behind a source-IP gate covering the
     whole pod CIDR, retained 30 days.

Run: python3 scripts/agent_api_trace_observability_test.py
"""

import json
import os
import re
import select
import shutil
import subprocess
import tempfile
import time
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROMTAIL_CFG = os.path.join(REPO, "scripts", "devvm-promtail.yaml")
LOKI_TF = os.path.join(REPO, "stacks", "monitoring", "modules", "monitoring", "loki.tf")
PROMTAIL_BIN = "/usr/local/bin/promtail"

GOOD_TS = "2026-09-14T11:02:31.442Z"

# Sentinels stand in for the two verbatim fields the trace schema carries.
# Neither may reach Loki. Strings are distinctive so a partial leak is caught.
SECRET_REQUEST = "SENTINEL-REQUEST-vault-kv-get-field-token"
SECRET_TOOL_INPUT = "SENTINEL-TOOLINPUT-Authorization-Bearer-abcdef"

FIXTURE = "\n".join([
    json.dumps({
        "ts": GOOD_TS, "trace_id": "01JBGOOD", "task_id": "01JBT",
        "conversation_id": "c-1", "actor": "muse", "verb": "POST /v1/x",
        "request": {"text": SECRET_REQUEST},
        "response": {"status": "accepted"},
        "tool_calls": [{"name": "Bash", "input": SECRET_TOOL_INPUT,
                        "result_bytes": 812}],
        "duration_ms": 143,
    }),
    # `ts` written as epoch milliseconds - the shape a release could regress to.
    json.dumps({"ts": 1757845351442, "trace_id": "01JBEPOCH", "actor": "muse"}),
    # `ts` renamed, so the timestamp stage finds nothing at all.
    json.dumps({"timestamp": GOOD_TS, "trace_id": "01JBRENAMED", "actor": "muse"}),
    # A value that is a string but not RFC3339Nano.
    json.dumps({"ts": "14/09/2026 11:06:00", "trace_id": "01JBDDMM"}),
    # Not JSON at all, carrying content that must not leak either.
    "not json at all " + SECRET_REQUEST,
]) + "\n"


def _read(path):
    with open(path) as fh:
        return fh.read()


def promtail_available():
    return os.path.isfile(PROMTAIL_BIN) and os.access(PROMTAIL_BIN, os.X_OK)


_PIPELINE_CACHE = []


def run_pipeline():
    """Run the COMMITTED pipeline over the fixture, return shipped entries.

    Only __path__, the positions file and the listen port are rewritten; every
    pipeline stage is exercised exactly as deployed. `promtail -dry-run` tails
    and never exits on its own, so it is stopped once its output has settled.
    The result is cached: eight tests share one run.
    """
    if _PIPELINE_CACHE:
        return _PIPELINE_CACHE[0]

    workdir = tempfile.mkdtemp(prefix="agent-api-trace-test-")
    try:
        fixture = os.path.join(workdir, "trace.jsonl")
        with open(fixture, "w") as fh:
            fh.write(FIXTURE)

        cfg = _read(PROMTAIL_CFG)
        cfg = cfg.replace("/var/log/agent-api/trace.jsonl", fixture)
        cfg = cfg.replace("/var/lib/promtail/positions.yaml",
                          os.path.join(workdir, "positions.yaml"))
        # The deployed config binds :9080; the real shipper already holds it on
        # this box, and a bind failure would otherwise look like "nothing
        # shipped", i.e. a green run that tested nothing.
        cfg = cfg.replace("http_listen_port: 9080", "http_listen_port: 0")
        # Drop the journal job so the dry run's output is only the trace job.
        cfg = re.sub(r"\n  - job_name: journal\n.*?(?=\n  # agent-api's request trace)",
                     "\n", cfg, flags=re.S)
        cfg_path = os.path.join(workdir, "promtail.yaml")
        with open(cfg_path, "w") as fh:
            fh.write(cfg)

        out = _run_until_settled(
            [PROMTAIL_BIN, "-config.file=" + cfg_path, "-dry-run"],
            expect_entries=FIXTURE.strip().count("\n") + 1)

        if "address already in use" in out or "error creating promtail" in out:
            raise AssertionError("promtail could not start:\n" + out[-2000:])

        entries = []
        for line in out.splitlines():
            m = re.match(r"^(\d{4}-\d{2}-\d{2}T\S+?)\s*(\{.*?\})\s*(\{.*\}|.*)$", line)
            if m and "job=" in m.group(2):
                entries.append((m.group(1), m.group(3)))

        _PIPELINE_CACHE.append((entries, out))
        return _PIPELINE_CACHE[0]
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def _run_until_settled(argv, expect_entries, quiet_for=2.0, deadline=45.0):
    """Collect a tailing process's output until every entry has arrived.

    promtail -dry-run never exits, and it prints its startup banner well
    before the file target is discovered, so "output has gone quiet" alone
    stops too early and yields an empty, green-looking run. Wait for the
    expected entry count first, then for quiet, then stop.
    """
    entry_re = re.compile(r"^\d{4}-\d{2}-\d{2}T\S+?\s*\{.*job=", re.M)
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    chunks = []
    last = started = time.time()
    try:
        os.set_blocking(proc.stdout.fileno(), False)
        while time.time() - started < deadline:
            ready, _, _ = select.select([proc.stdout], [], [], 0.25)
            if ready:
                data = proc.stdout.read()
                if data:
                    chunks.append(data)
                    last = time.time()
                    continue
            seen = len(entry_re.findall("".join(chunks)))
            if seen >= expect_entries and time.time() - last > quiet_for:
                break
            if proc.poll() is not None:
                break
    finally:
        proc.terminate()
        try:
            proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
    return "".join(chunks)


def loki_tf_alert_expr():
    src = _read(LOKI_TF)
    block = src[src.index('alert  = "AgentApiTraceSilent"'):]
    m = re.search(r'expr\s+=\s+"((?:[^"\\]|\\.)*)"', block)
    assert m, "AgentApiTraceSilent has no expr"
    return m.group(1).replace('\\"', '"')


def loki_tf_alert_block():
    src = _read(LOKI_TF)
    start = src.index('alert  = "AgentApiTraceSilent"')
    return src[start:start + 6000]


@unittest.skipUnless(promtail_available(), "promtail binary not present")
class TimestampFailureHandling(unittest.TestCase):
    """Finding 1: a line promtail cannot timestamp must not be frozen in the past."""

    def test_unparseable_lines_are_not_pinned_to_the_last_good_timestamp(self):
        entries, raw = run_pipeline()
        self.assertGreaterEqual(len(entries), 5, "fixture did not ship:\n" + raw)

        # `fudge` produces GOOD_TS + 1ns, +2ns, ... for each failing line. Any
        # shipped timestamp inside a microsecond of the good one is that bug.
        good_prefix = "2026-09-14T11:02:31.442"
        frozen = [ts for ts, _ in entries[1:] if ts.startswith(good_prefix)]
        self.assertEqual(
            frozen, [],
            "action_on_failure is fudging unparseable lines onto the previous "
            "event's timestamp (frozen in the past, which Loki 400-rejects "
            "once it ages past reject_old_samples_max_age=1w): " + repr(frozen))

    def test_config_uses_skip_not_fudge(self):
        cfg = _read(PROMTAIL_CFG)
        self.assertFalse("action_on_failure: fudge" in cfg,
                         "fudge pins a failing line to the last good event "
                         "timestamp + 1ns, i.e. frozen in the past")
        self.assertTrue("action_on_failure: skip" in cfg)

    def test_no_line_is_dropped_when_its_timestamp_fails(self):
        entries, raw = run_pipeline()
        self.assertEqual(len(entries), 5,
                         "skip must keep every line, not drop it:\n" + raw)


class ParseFailureDiagnosticIsHonest(unittest.TestCase):
    """Finding 2: don't send the operator somewhere guaranteed to be empty."""

    def test_runbook_does_not_promise_parse_failures_in_the_promtail_journal(self):
        block = loki_tf_alert_block()
        m = re.search(r"journalctl -u promtail(?:[^\n]*\n){0,4}", block)
        if m:
            self.assertNotRegex(
                m.group(0), r"(?i)parse|ts will not|logged here",
                "the promtail journal cannot show a timestamp parse failure: "
                "promtail logs those at level=debug and this shipper runs "
                "log_level: warn")

    def test_promtail_config_does_not_claim_it_logs_the_failure(self):
        cfg = _read(PROMTAIL_CFG)
        self.assertFalse("promtail logs the parse failure" in cfg,
                         "it does not, at log_level: warn")

    def test_the_debug_level_caveat_is_recorded_where_it_is_needed(self):
        cfg = _read(PROMTAIL_CFG)
        self.assertTrue("level=debug" in cfg,
                        "the config must record that stage failures are "
                        "debug-level, or the next reader repeats the mistake")
        self.assertTrue(re.search(r"log_level:\s*warn", cfg) is not None,
                        "if this shipper ever runs at debug, revisit the "
                        "caveat above action_on_failure")


class EnableGateCannotBeArmedByOneBurst(unittest.TestCase):
    """Finding 3: a single smoke test must not produce a standing warning."""

    def test_gate_is_two_prior_week_windows_not_a_single_28d_window(self):
        expr = loki_tf_alert_expr()
        self.assertNotRegex(
            expr, r'count_over_time\(\{job="agent-api-trace"\}\[28d\]\)',
            "a single [28d] gate arms on one trace line, so the design's own "
            "step-4 smoke test leaves this alert standing from D+7 to D+28")
        self.assertTrue('[7d] offset 7d' in expr, expr)
        self.assertTrue('[7d] offset 14d' in expr, expr)

    def test_silence_test_keeps_its_or_vector_zero_guard(self):
        expr = loki_tf_alert_expr()
        self.assertTrue("or vector(0)" in expr,
                      "without the guard a `< 1` comparison is silent at "
                      "exactly zero, the case the alert exists to catch")

    def test_a_single_burst_satisfies_at_most_one_gate_window(self):
        """The two gate windows are disjoint, so no instant is in both.

        This is the whole reason the pair works, and it is cheap to assert
        directly rather than trusting the reading of the expression.
        """
        expr = loki_tf_alert_expr()
        offsets = sorted(int(o) for o in re.findall(r"\[7d\] offset (\d+)d", expr))
        self.assertEqual(offsets, [7, 14])
        day = 86400
        # window(offset) = [now - offset - 7d, now - offset]
        a = (-(7 + 7) * day, -7 * day)
        b = (-(14 + 7) * day, -14 * day)
        self.assertLessEqual(b[1], a[0], "gate windows must not overlap")


@unittest.skipUnless(promtail_available(), "promtail binary not present")
class VerbatimContentNeverReachesLoki(unittest.TestCase):
    """Finding 4: request.text and tool_calls[].input stay on the box."""

    def test_no_shipped_line_carries_request_text_or_tool_input(self):
        entries, raw = run_pipeline()
        shipped = "\n".join(line for _, line in entries)
        for sentinel in (SECRET_REQUEST, SECRET_TOOL_INPUT):
            self.assertFalse(
                sentinel in shipped,
                "verbatim trace content reached the shipped line; Loki's .lan "
                "ingress is auth = none behind a source-IP gate covering "
                "10.0.0.0/8 (the whole pod CIDR) and keeps 30 days")

    def test_the_metadata_that_makes_the_trace_searchable_survives(self):
        entries, raw = run_pipeline()
        shipped = "\n".join(line for _, line in entries)
        for keep in ("01JBGOOD", "muse", "POST /v1/x", "accepted", "Bash"):
            self.assertTrue(keep in shipped,
                            "the projection dropped a field the alert and the "
                            "query examples depend on: " + keep)

    def test_every_shipped_line_is_valid_json(self):
        entries, raw = run_pipeline()
        for ts, line in entries:
            try:
                json.loads(line)
            except ValueError as exc:
                self.fail("projection emitted invalid JSON at %s: %s (%s)"
                          % (ts, line[:120], exc))

    def test_a_non_json_trace_line_still_ships_as_traffic(self):
        """Malformed input must not vanish, or the alert reads healthy."""
        entries, raw = run_pipeline()
        nulls = [l for _, l in entries if l.count("null") >= 8]
        self.assertTrue(nulls,
                        "a line that is not JSON should project to all-nulls, "
                        "so a broken trace still counts as traffic")


if __name__ == "__main__":
    unittest.main(verbosity=2)
