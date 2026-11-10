"""Which upgrade-step.sh lines reach Slack.

Run: pytest stacks/k8s-version-upgrade/scripts/test_upgrade_step_slack.py

Slack gets only lines a person may need to act on: aborts, deferrals, the
kill-switch halt, warnings and failures. Progress and success lines ("Draining
k8s-node2", "Soaked clean", "upgrade complete") go to the Job's log (Loki), and
the weekly k8s-upgrade-nightly-report gives the outcome (Viktor, 2026-11-10).
"""
import pathlib
import re

SCRIPT = (pathlib.Path(__file__).parent / "upgrade-step.sh").read_text()

# slack "..." calls, the message being the first double-quoted argument.
SLACK_CALL = re.compile(r'\bslack "((?:[^"\\]|\\.)*)"')
LOG_CALL = re.compile(r'\blog "((?:[^"\\]|\\.)*)"')
ACTIONABLE = re.compile(
    r"^(ABORT|DEFERRED|HALTED|WARN|Postflight WARN|postflight FAIL|postflight smoke)")


def test_every_slack_line_is_actionable():
    chatty = [m for m in SLACK_CALL.findall(SCRIPT) if not ACTIONABLE.match(m)]
    assert chatty == []


def test_failures_and_blocks_still_post():
    posted = SLACK_CALL.findall(SCRIPT)
    for start in ("ABORT $1", "HALTED by kill-switch", "DEFERRED preflight",
                  "postflight smoke tests FAILED", "Postflight WARN"):
        assert any(m.startswith(start) for m in posted), start


def test_progress_lines_are_logged():
    logged = LOG_CALL.findall(SCRIPT)
    for text in ("Draining $TARGET_NODE", "Running update_k8s.sh on $TARGET_NODE",
                 "Soaked clean (10 min)", "K8s upgrade complete", "Starting preflight"):
        assert any(text in m for m in logged), text


def test_log_keeps_the_phase_prefix():
    # The same "[k8s-upgrade-<phase>:<node>]" prefix Slack had, so Loki
    # searches for the old Slack text still find the line.
    body = re.search(r"^log\(\) \{\n(.*?)^\}", SCRIPT, re.S | re.M)
    assert body, "log() helper missing"
    assert "[k8s-upgrade-${PHASE}${TARGET_NODE:+:$TARGET_NODE}]" in body.group(1)
