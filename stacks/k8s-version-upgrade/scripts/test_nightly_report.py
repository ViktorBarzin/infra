"""Unit tests for nightly-report.py (pure helpers only).

Run: pytest stacks/k8s-version-upgrade/scripts/test_nightly_report.py
Loaded via importlib because the filename has a hyphen.
"""
import importlib.util
import pathlib

HERE = pathlib.Path(__file__).parent
_spec = importlib.util.spec_from_file_location("nightly_report", HERE / "nightly-report.py")
nr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(nr)

LAST_RUN = 1781996424.0  # 2026-06-20T23:00:24Z — matches last night's gauge
METRICS_BLOCKED = f"""# TYPE k8s_upgrade_available gauge
k8s_upgrade_available{{instance="",job="k8s-version-check",kind="minor",running="1.34.9",target="1.35.6"}} 1
k8s_upgrade_blocked{{instance="",job="k8s-version-upgrade"}} 1
k8s_version_check_last_run_timestamp{{instance="",job="k8s-version-check"}} {LAST_RUN}
"""
NODES_UNIFORM = [(f"k8s-node{i}", "v1.34.9") for i in range(7)]


def test_parse_metrics_basic():
    m = nr.parse_metrics(METRICS_BLOCKED)
    names = {n for n, _, _ in m}
    assert names == {"k8s_upgrade_available", "k8s_upgrade_blocked", "k8s_version_check_last_run_timestamp"}
    avail = nr.select(m, "k8s_upgrade_available")
    assert avail[0][0]["target"] == "1.35.6"
    assert avail[0][0]["kind"] == "minor"
    assert avail[0][1] == 1.0


def test_parse_metrics_ignores_comments_and_junk():
    assert nr.parse_metrics("# HELP foo\n\ngarbage line\n") == []


def test_fmt_age():
    assert nr.fmt_age(120) == "2m ago"
    assert nr.fmt_age(7200) == "2.0h ago"
    assert nr.fmt_age(172800) == "2.0d ago"


def test_compose_blocked_lists_reasons():
    m = nr.parse_metrics(METRICS_BLOCKED)
    reasons = ("addon external-secrets v0.12 supports k8s <= 1.31; target 1.35 exceeds it\n"
               "addon kyverno v1.16 supports k8s <= 1.34; target 1.35 exceeds it")
    out = nr.compose_report(LAST_RUN + 30000, NODES_UNIFORM, m, reasons, [])
    assert "🔴 BLOCKED" in out and "1.35.6" in out
    assert "external-secrets" in out and "kyverno" in out
    assert "all 7 nodes uniform" in out
    assert "fresh ✓" in out


def test_compose_noop_when_no_target():
    m = nr.parse_metrics(f'k8s_version_check_last_run_timestamp{{}} {LAST_RUN}\n')
    out = nr.compose_report(LAST_RUN + 30000, NODES_UNIFORM, m, None, [])
    assert "⚪ No upgrade needed" in out


def test_compose_upgraded_when_nodes_match_target():
    m = nr.parse_metrics(f"""k8s_upgrade_available{{kind="minor",target="1.35.6"}} 1
k8s_upgrade_blocked{{}} 0
k8s_version_check_last_run_timestamp{{}} {LAST_RUN}
""")
    nodes = [(f"k8s-node{i}", "v1.35.6") for i in range(7)]
    out = nr.compose_report(LAST_RUN + 30000, nodes, m, None, [])
    assert "🟢 UPGRADED" in out and "1.35.6" in out


def test_compose_stale_detector_flagged():
    m = nr.parse_metrics(METRICS_BLOCKED)
    out = nr.compose_report(LAST_RUN + 200000, NODES_UNIFORM, m, "x", [])  # ~55h later
    assert "Detector did not run last night" in out
    assert "STALE" in out


def test_compose_includes_recent_jobs():
    m = nr.parse_metrics(METRICS_BLOCKED)
    jobs = [{"name": "k8s-upgrade-preflight-1-35-6", "status": "Failed", "age_s": 3600}]
    out = nr.compose_report(LAST_RUN + 30000, NODES_UNIFORM, m, "x", jobs)
    assert "k8s-upgrade-preflight-1-35-6: Failed" in out


# --- held (waiting-upstream / pinned) vs actionable-blocked rendering -------
METRICS_HELD = f"""# TYPE k8s_upgrade_available gauge
k8s_upgrade_available{{instance="",job="k8s-version-check",kind="minor",running="1.35.6",target="1.36.2"}} 1
k8s_upgrade_held{{instance="",job="k8s-version-upgrade"}} 1
k8s_upgrade_blocked{{instance="",job="k8s-version-upgrade"}} 0
k8s_version_check_last_run_timestamp{{instance="",job="k8s-version-check"}} {LAST_RUN}
"""
NODES_135 = [(f"k8s-node{i}", "v1.35.6") for i in range(7)]


def test_compose_held_headline_and_grouped_reasons():
    m = nr.parse_metrics(METRICS_HELD)
    reasons = (
        "[WAITING] addon kyverno v1.18 supports k8s <= 1.35; target 1.36 exceeds it — no released kyverno version supports k8s 1.36 yet\n"
        "[PINNED] addon gpu-operator v25.10 supports k8s <= 1.35; target 1.36 exceeds it — pinned (driver/OS); holding\n"
        "[ACTIONABLE] addon calico v3.30 supports k8s <= 1.35; target 1.36 exceeds it — upgrade calico to >= 3.32"
    )
    out = nr.compose_report(LAST_RUN + 30000, NODES_135, m, reasons, [])
    # held headline, NOT a red actionable block
    assert "⏸️ HELD" in out and "1.36.2" in out
    assert "🔴 BLOCKED" not in out
    # grouped by class
    assert "Waiting on upstream" in out and "kyverno" in out
    assert "Pinned" in out and "gpu-operator" in out
    # the lone actionable piece is still listed so eventual scope is visible
    assert "calico" in out
    # tags are stripped from the rendered bullets (no raw "[WAITING]")
    assert "[WAITING]" not in out


def test_compose_blocked_groups_actionable():
    m = nr.parse_metrics(METRICS_BLOCKED)  # blocked=1
    reasons = "[ACTIONABLE] addon calico v3.30 supports k8s <= 1.35; target 1.36 exceeds it — upgrade calico to >= 3.32"
    out = nr.compose_report(LAST_RUN + 30000, NODES_UNIFORM, m, reasons, [])
    assert "🔴 BLOCKED" in out
    assert "Action needed" in out and "calico" in out
