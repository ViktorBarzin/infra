"""Unit tests for the CrowdSec -> Cloudflare edge-list sync.

Run: cd stacks/rybbit && python3 -m pytest lapi_kv_sync_test.py -q

The module reads its config from the environment at import time (it is a
single-purpose CronJob script, not a library), so the env is seeded here before
the import. Everything below stubs the two network helpers — `_cf` for the
Cloudflare API and `_req` for LAPI/Pushgateway — so no test touches a network.

The behaviour these cover is the part that went wrong in production: a
Cloudflare 429 must cost quiet rather than another identical attempt, and a run
that writes nothing must still report how far the edge list has drifted.
"""
import os

os.environ.setdefault("LAPI_KEY", "test-lapi-key")
os.environ.setdefault("CF_ACCOUNT_ID", "test-account")
os.environ.setdefault("CF_API_TOKEN", "test-token")
os.environ.setdefault("CF_BAN_LIST_ID", "test-list")
os.environ.setdefault("PUSHGATEWAY_URL", "http://pushgateway.test:9091")

import lapi_kv_sync as k  # noqa: E402


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
class Recorder:
    """Collects the calls a test cares about."""

    def __init__(self):
        self.cf_calls = []
        self.pushes = []


def install(monkeypatch, rec, *, existing, cf_error=None, state=(0, 0.0)):
    """Wire the module's I/O to in-memory fakes.

    `existing` is the set of IPs Cloudflare currently holds; `cf_error` (if
    given) is raised by any mutating call.
    """
    def fake_list_items(list_id):
        return {ip: f"id-{ip}" for ip in existing}

    def fake_replace(list_id, ips):
        rec.cf_calls.append(("PUT", sorted(ips)))
        if cf_error:
            raise cf_error
        return "op-1"

    def fake_wait(op_id):
        return True

    def fake_push(block_n, ok, drift=0, fail_streak=0, backoff_until=0.0):
        rec.pushes.append(
            dict(block_n=block_n, ok=ok, drift=drift,
                 fail_streak=fail_streak, backoff_until=backoff_until)
        )

    monkeypatch.setattr(k, "cf_list_items", fake_list_items)
    monkeypatch.setattr(k, "cf_replace_items", fake_replace)
    monkeypatch.setattr(k, "_wait_for_op", fake_wait)
    monkeypatch.setattr(k, "push_metrics", fake_push)
    monkeypatch.setattr(k, "read_state", lambda: state)


# --------------------------------------------------------------------------- #
# reconcile
# --------------------------------------------------------------------------- #
def test_in_sync_issues_no_write(monkeypatch):
    """The common case. A no-op run must not spend a list change — this is why
    thousands of `[ok]` runs coexisted with a permanently stale list."""
    rec = Recorder()
    install(monkeypatch, rec, existing={"1.1.1.1", "2.2.2.2"})
    drift, wrote = k.reconcile("block", "test-list", {"1.1.1.1", "2.2.2.2"})
    assert (drift, wrote) == (0, False)
    assert rec.cf_calls == []


def test_drift_writes_the_full_desired_set_once(monkeypatch):
    """One PUT carrying the whole desired set, not an add plus a delete."""
    rec = Recorder()
    install(monkeypatch, rec, existing={"1.1.1.1", "9.9.9.9"})
    drift, wrote = k.reconcile("block", "test-list", {"1.1.1.1", "2.2.2.2"})
    # 9.9.9.9 removed, 2.2.2.2 added -> two items differ
    assert (drift, wrote) == (2, True)
    assert rec.cf_calls == [("PUT", ["1.1.1.1", "2.2.2.2"])]


def test_drift_counts_adds_and_removes(monkeypatch):
    rec = Recorder()
    install(monkeypatch, rec, existing={"1.1.1.1"})
    drift, _ = k.reconcile("block", "test-list", {"2.2.2.2", "3.3.3.3"})
    assert drift == 3  # one removal, two additions


def test_empty_desired_is_still_written(monkeypatch):
    """CrowdSec legitimately reaching zero bans must clear the edge list. The
    fail-safe against an accidental wipe lives in main() (an unreadable LAPI
    skips the run), not here."""
    rec = Recorder()
    install(monkeypatch, rec, existing={"1.1.1.1"})
    drift, wrote = k.reconcile("block", "test-list", set())
    assert (drift, wrote) == (1, True)
    assert rec.cf_calls == [("PUT", [])]


# --------------------------------------------------------------------------- #
# backoff ladder
# --------------------------------------------------------------------------- #
def test_429_records_backoff_and_exits_zero(monkeypatch):
    """A throttle is not a job failure, and it must defer the next attempt."""
    rec = Recorder()
    err = k.CFError("PUT ... -> HTTP 429", status=429)
    install(monkeypatch, rec, existing={"1.1.1.1"}, cf_error=err)
    monkeypatch.setattr(k, "fetch_decisions", lambda: {"2.2.2.2"})

    assert k.main() == 0
    push = rec.pushes[-1]
    assert push["ok"] is False
    assert push["fail_streak"] == 1
    assert push["backoff_until"] > 0


def test_backoff_grows_up_the_ladder_then_caps(monkeypatch):
    """Each consecutive 429 buys more quiet, up to the ceiling."""
    err = k.CFError("PUT ... -> HTTP 429", status=429)
    waits = []
    for streak in range(0, 8):
        rec = Recorder()
        install(monkeypatch, rec, existing={"1.1.1.1"}, cf_error=err,
                state=(streak, 0.0))
        monkeypatch.setattr(k, "fetch_decisions", lambda: {"2.2.2.2"})
        import time as _t
        before = _t.time()
        k.main()
        waits.append(round(rec.pushes[-1]["backoff_until"] - before))

    assert waits[:5] == k.BACKOFF_LADDER            # 30m, 1h, 2h, 4h, 6h
    assert waits[5:] == [k.BACKOFF_LADDER[-1]] * 3  # capped, never unbounded


def test_hold_skips_the_write_but_still_reports_drift(monkeypatch):
    """While backing off we keep READING — Cloudflare does not throttle GETs,
    and drift is what the alert keys on."""
    rec = Recorder()
    import time as _t
    install(monkeypatch, rec, existing={"1.1.1.1"},
            state=(3, _t.time() + 3600))
    monkeypatch.setattr(k, "fetch_decisions", lambda: {"2.2.2.2"})

    assert k.main() == 0
    assert rec.cf_calls == []            # no write attempted
    push = rec.pushes[-1]
    assert push["drift"] == 2            # ...but drift is still measured
    assert push["fail_streak"] == 3


def test_success_clears_the_ladder(monkeypatch):
    rec = Recorder()
    install(monkeypatch, rec, existing={"1.1.1.1"}, state=(4, 0.0))
    monkeypatch.setattr(k, "fetch_decisions", lambda: {"2.2.2.2"})

    assert k.main() == 0
    push = rec.pushes[-1]
    assert push["ok"] is True
    assert push["fail_streak"] == 0
    assert push["backoff_until"] == 0


def test_non_429_cloudflare_error_still_fails_loud(monkeypatch):
    """Only throttling is soft. A 403 or a 500 must surface as a failed job."""
    rec = Recorder()
    err = k.CFError("PUT ... -> HTTP 403", status=403)
    install(monkeypatch, rec, existing={"1.1.1.1"}, cf_error=err)
    monkeypatch.setattr(k, "fetch_decisions", lambda: {"2.2.2.2"})

    assert k.main() == 1


def test_network_timeout_becomes_a_cferror_not_a_traceback(monkeypatch):
    """urlopen(timeout=) raises a bare TimeoutError, which is not a URLError.
    Uncaught, it exits 1 without pushing metrics — leaving the freshness alerts
    reading a stale sample. Hit for real against the Cloudflare API on
    2026-08-16."""
    def boom(*a, **kw):
        raise TimeoutError("The read operation timed out")

    monkeypatch.setattr(k, "_req", boom)
    try:
        k._cf("https://api.cloudflare.test/whatever")
    except k.CFError as e:
        assert "TimeoutError" in str(e)
    else:
        raise AssertionError("expected CFError")


def test_unreadable_lapi_never_touches_the_list(monkeypatch):
    """The fail-safe that makes the unconditional PUT safe: no desired set, no
    write — degrade to the last-known-good edge state, never to an empty one."""
    rec = Recorder()
    install(monkeypatch, rec, existing={"1.1.1.1"})

    def boom():
        raise RuntimeError("connection refused")

    monkeypatch.setattr(k, "fetch_decisions", boom)
    assert k.main() == 0
    assert rec.cf_calls == []


# --------------------------------------------------------------------------- #
# Pushgateway state parsing
# --------------------------------------------------------------------------- #
def _pgw_body(text):
    class Resp:
        def read(self):
            return text.encode()

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    return Resp()


def test_read_state_parses_labels_and_scientific_notation(monkeypatch):
    """Pushed samples always come back labelled, and timestamps come back as
    floats in scientific notation, which int() rejects."""
    body = (
        "# TYPE crowdsec_cf_list_write_fail_streak gauge\n"
        'crowdsec_cf_list_write_fail_streak{instance="",job="crowdsec-cf-list-sync"} 3\n'
        "# TYPE crowdsec_cf_list_write_backoff_until_seconds gauge\n"
        'crowdsec_cf_list_write_backoff_until_seconds{instance="",job="crowdsec-cf-list-sync"} 1.786891e+09\n'
    )
    monkeypatch.setattr(k.urllib.request, "urlopen",
                        lambda *a, **kw: _pgw_body(body))
    streak, until = k.read_state()
    assert streak == 3
    assert until == 1786891000.0


def test_read_state_is_permissive_when_pushgateway_is_down(monkeypatch):
    """Failing closed here would stop syncing bans whenever the metrics stack
    blipped, which is worse than a few extra write attempts."""
    def boom(*a, **kw):
        raise OSError("connection refused")

    monkeypatch.setattr(k.urllib.request, "urlopen", boom)
    assert k.read_state() == (0, 0.0)


def test_read_state_defaults_to_zero_on_a_fresh_pushgateway(monkeypatch):
    monkeypatch.setattr(k.urllib.request, "urlopen",
                        lambda *a, **kw: _pgw_body("# nothing here\n"))
    assert k.read_state() == (0, 0.0)
