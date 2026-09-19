"""Unit tests for the chrome-broker pure logic (no k8s/CDP I/O).

Run: cd stacks/chrome-service/files/broker && python3 -m pytest test_broker.py -v
"""
import json
import os

import broker

TEMPLATE = json.load(open(os.path.join(os.path.dirname(__file__), "worker_pod.json")))


def test_build_pod_spec_stamps_labels_and_deadline():
    spec = broker.build_pod_spec(
        TEMPLATE, name="chrome-worker-abc", owner="agent-x",
        purpose="scrape", session="abc", started="1000", deadline=3600)
    assert spec["metadata"]["name"] == "chrome-worker-abc"
    assert spec["metadata"]["labels"]["chrome-pool/owner"] == "agent-x"
    assert spec["metadata"]["labels"]["chrome-pool/session"] == "abc"
    assert spec["metadata"]["annotations"]["chrome-pool/purpose"] == "scrape"
    assert spec["metadata"]["annotations"]["chrome-pool/started"] == "1000"
    assert spec["spec"]["activeDeadlineSeconds"] == 3600
    # activeDeadlineSeconds must stay an int (k8s rejects a string)
    assert isinstance(spec["spec"]["activeDeadlineSeconds"], int)
    # every placeholder is substituted — none leak through
    assert "__" not in json.dumps(spec)


def test_build_pod_spec_does_not_mutate_template():
    before = json.dumps(TEMPLATE)
    broker.build_pod_spec(TEMPLATE, name="w1", owner="o", purpose="p",
                          session="s", started="1", deadline=60)
    assert json.dumps(TEMPLATE) == before  # template reused across sessions


def test_pick_free_worker_prefers_unclaimed_ready():
    pods = [
        {"session": "", "ready": True, "name": "w1"},
        {"session": "busy", "ready": True, "name": "w2"},
    ]
    assert broker.pick_free_worker(pods)["name"] == "w1"


def test_pick_free_worker_skips_unready():
    pods = [{"session": "", "ready": False, "name": "w-booting"}]
    assert broker.pick_free_worker(pods) is None


def test_pick_free_worker_none_when_all_busy():
    assert broker.pick_free_worker([{"session": "x", "ready": True, "name": "w2"}]) is None


def test_should_reap_idle_ttl():
    now = 10_000
    # idle worker (no session), released 21 min ago > 20m idle TTL -> reap
    assert broker.should_reap({"session": "", "released_at": now - 21 * 60}, now, idle_ttl=1200) is True
    # idle 5 min < 20m -> keep
    assert broker.should_reap({"session": "", "released_at": now - 5 * 60}, now, idle_ttl=1200) is False


def test_should_reap_never_reaps_a_claimed_session():
    # a claimed session's hard cap is activeDeadlineSeconds (k8s), never the idle reaper
    now = 10_000
    assert broker.should_reap({"session": "busy", "released_at": 0}, now, idle_ttl=1200) is False


def test_worker_name_is_unique_and_dns_safe():
    a = broker.worker_name("abc123")
    assert a.startswith("chrome-worker-")
    assert a.islower() and a.replace("-", "").isalnum()
    assert len(a) <= 63  # k8s name limit


def test_wait_ready_returns_the_worker_so_acquire_can_read_its_ip(monkeypatch):
    """/acquire reports podIP from what wait_ready hands back.

    In-cluster callers (e.g. f1-stream's replays sourcing) dial the worker's CDP
    by IP — there is no Service selecting app=chrome-worker — so a wait_ready
    that stopped returning the worker would silently empty that field.
    """
    worker = {"name": "chrome-worker-abc", "ready": True, "ip": "10.10.1.5", "session": "abc"}
    monkeypatch.setattr(broker, "list_workers", lambda: [worker])
    assert broker.wait_ready("chrome-worker-abc") is worker
    assert broker.wait_ready("chrome-worker-abc")["ip"] == "10.10.1.5"


def test_list_workers_shape_carries_ip(monkeypatch):
    """The pod IP must survive list_workers, which is where /acquire reads it."""
    monkeypatch.setattr(broker, "kube", lambda *a, **k: {"items": [{
        "metadata": {"name": "chrome-worker-abc", "labels": {}, "annotations": {}},
        "status": {"phase": "Running", "podIP": "10.10.1.5",
                   "containerStatuses": [{"ready": True}]},
    }]})
    got = broker.list_workers()[0]
    assert got["ip"] == "10.10.1.5"
    assert got["ready"] is True


# ----------------------------------------------------------- browser reset
# The target list a live warm worker actually reports, measured on
# chrome-worker-f1a4fbb1 on 2026-09-19 with one test session still open.
LIVE_TABS = [
    {"id": "P1", "type": "page", "url": "https://sw-repro.test/"},
    {"id": "P2", "type": "page", "url": "about:blank"},
    {"id": "B1", "type": "background_page",
     "url": "chrome-extension://nmmhkkegccagdldgiimedpiccmgmieda/_generated_background_page.html"},
    {"id": "B2", "type": "background_page",
     "url": "chrome-extension://nkeimhogjdpnpccoofpliimaahmaaome/background.html"},
    {"id": "S1", "type": "service_worker",
     "url": "chrome-extension://fignfifoniblkonapihmkfakmlgkbkcf/service_worker.js"},
    {"id": "S2", "type": "service_worker",
     "url": "chrome-extension://ghbmnnjooekpmoecnnnilnnbdlolhkhi/service_worker.js"},
    {"id": "S3", "type": "service_worker", "url": "https://sw-repro.test/sw.js"},
]


def test_plan_browser_reset_closes_only_the_session_targets():
    close, need_blank = broker.plan_browser_reset(LIVE_TABS)
    assert sorted(close) == ["P1", "S3"]
    assert need_blank is False


def test_plan_browser_reset_keeps_every_extension_target():
    """Closing these would take out the stealth the pool exists to provide."""
    close, _ = broker.plan_browser_reset(LIVE_TABS)
    for keep in ("B1", "B2", "S1", "S2"):
        assert keep not in close


def test_plan_browser_reset_closes_the_orphan_from_issue_98():
    tabs = [{"id": "6D71A05B00BDB41A185ADD2043A71627", "type": "service_worker",
             "url": "https://embed.st/embed/admin/ppv-azerbaijan-grand-prix-practice-3/sw.js"}]
    close, need_blank = broker.plan_browser_reset(tabs)
    assert close == ["6D71A05B00BDB41A185ADD2043A71627"]
    # nothing blank survived, so the worker needs its starting tab back
    assert need_blank is True


def test_plan_browser_reset_keeps_exactly_one_blank_page():
    tabs = [
        {"id": "A", "type": "page", "url": "about:blank"},
        {"id": "B", "type": "page", "url": "about:blank"},
        {"id": "C", "type": "page", "url": "about:blank"},
    ]
    close, need_blank = broker.plan_browser_reset(tabs)
    assert close == ["B", "C"]
    assert need_blank is False


def test_plan_browser_reset_asks_for_a_blank_when_the_session_navigated_it_away():
    tabs = [{"id": "A", "type": "page", "url": "https://example.com/"}]
    close, need_blank = broker.plan_browser_reset(tabs)
    assert close == ["A"]
    assert need_blank is True


def test_plan_browser_reset_on_a_clean_worker_is_a_no_op():
    tabs = [{"id": "P2", "type": "page", "url": "about:blank"},
            {"id": "S1", "type": "service_worker",
             "url": "chrome-extension://fignfifoniblkonapihmkfakmlgkbkcf/service_worker.js"}]
    close, need_blank = broker.plan_browser_reset(tabs)
    assert close == []
    assert need_blank is False


def test_plan_browser_reset_tolerates_junk():
    assert broker.plan_browser_reset([]) == ([], True)
    assert broker.plan_browser_reset(None) == ([], True)
    # a target with no id cannot be closed, and must not crash the planner
    assert broker.plan_browser_reset([{"type": "page", "url": "https://x/"}]) == ([], True)


def test_release_worker_resets_a_warm_pod_but_not_a_bare_one(monkeypatch):
    """A bare pod's browser dies with the pod; a warm one is reused, so it is
    the one that has to be cleaned before the next caller gets it."""
    calls = []
    monkeypatch.setattr(broker, "kube", lambda *a, **k: calls.append(a[0]))
    monkeypatch.setattr(broker, "reset_browser", lambda ip: calls.append(f"reset:{ip}"))

    broker.release_worker({"name": "w", "bare": True, "ip": "10.10.1.5"})
    assert "reset:10.10.1.5" not in calls and "DELETE" in calls

    calls.clear()
    broker.release_worker({"name": "w", "bare": False, "ip": "10.10.1.5"})
    assert calls == ["reset:10.10.1.5", "PATCH"]


def test_reset_browser_without_an_ip_does_nothing():
    """A pod with no IP yet must not make release hang on a connect timeout."""
    assert broker.reset_browser("") == 0
    assert broker.reset_browser(None) == 0


def test_plan_browser_reset_closes_pages_before_workers():
    """A service worker closed while a page it controls is still open can be
    restarted by that page, so the client has to go first."""
    tabs = [
        {"id": "SW", "type": "service_worker", "url": "https://x.test/sw.js"},
        {"id": "PG", "type": "page", "url": "https://x.test/"},
    ]
    close, _ = broker.plan_browser_reset(tabs)
    assert close == ["PG", "SW"], "pages must be closed before workers"


class _FakeCDP:
    """Minimal /json/list + /json/close stand-in for reset_browser.

    close_delay says how many list calls a target stays visible for after its
    close returns, which is the real behaviour: /json/close answers "Target is
    closing" and the target lingers for a moment.
    """

    def __init__(self, tabs, close_delay=0, never_dies=()):
        self.tabs = {t["id"]: t for t in tabs}
        self.close_delay = close_delay
        self.never_dies = set(never_dies)
        self.closing = {}
        self.closed_calls = []
        self.new_calls = []
        self.list_calls = 0

    def open(self, req, timeout=None):
        url = req if isinstance(req, str) else req.full_url
        if "/json/list" in url:
            self.list_calls += 1
            for tid in list(self.closing):
                self.closing[tid] -= 1
                if self.closing[tid] <= 0 and tid not in self.never_dies:
                    self.tabs.pop(tid, None)
                    self.closing.pop(tid)
            return _FakeResp(json.dumps(list(self.tabs.values())).encode())
        if "/json/close/" in url:
            tid = url.rsplit("/", 1)[1]
            self.closed_calls.append(tid)
            self.closing[tid] = self.close_delay
            if self.close_delay <= 0 and tid not in self.never_dies:
                self.tabs.pop(tid, None)
            return _FakeResp(b"Target is closing")
        if "/json/new" in url:
            self.new_calls.append(url)
            return _FakeResp(b"{}")
        raise AssertionError("unexpected CDP call " + url)


class _FakeResp:
    def __init__(self, body):
        self._body = body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _patch_cdp(monkeypatch, fake):
    monkeypatch.setattr(broker.urllib.request, "urlopen", fake.open)
    monkeypatch.setattr(broker.time, "sleep", lambda s: None)


def test_reset_browser_closes_the_session_targets(monkeypatch):
    fake = _FakeCDP(LIVE_TABS)
    _patch_cdp(monkeypatch, fake)
    assert broker.reset_browser("10.0.0.1") == 2
    assert sorted(fake.closed_calls) == ["P1", "S3"]
    assert "B1" not in fake.closed_calls and "S1" not in fake.closed_calls


def test_reset_browser_waits_for_an_asynchronous_close(monkeypatch):
    """Measured on a live worker: a service worker was still listed in a
    snapshot taken right after its close returned 200. A 200 is not proof."""
    fake = _FakeCDP(LIVE_TABS, close_delay=3)
    _patch_cdp(monkeypatch, fake)
    assert broker.reset_browser("10.0.0.1") == 2
    assert fake.list_calls > 2, "should have re-listed until the targets went"


def test_reset_browser_gives_up_on_a_target_that_will_not_die(monkeypatch):
    """Release must never wedge on a stubborn target: report it and move on."""
    fake = _FakeCDP(LIVE_TABS, close_delay=1, never_dies=("S3",))
    _patch_cdp(monkeypatch, fake)
    monkeypatch.setattr(broker, "RESET_CONFIRM_SECONDS", 0.05)
    assert broker.reset_browser("10.0.0.1") == 1  # the page went, the worker did not


def test_reset_browser_reopens_a_blank_only_when_none_survived(monkeypatch):
    fake = _FakeCDP(LIVE_TABS)
    _patch_cdp(monkeypatch, fake)
    broker.reset_browser("10.0.0.1")
    assert fake.new_calls == [], "a blank page survived, so none should be opened"

    fake = _FakeCDP([{"id": "A", "type": "page", "url": "https://example.com/"}])
    _patch_cdp(monkeypatch, fake)
    broker.reset_browser("10.0.0.1")
    assert len(fake.new_calls) == 1 and "about:blank" in fake.new_calls[0]


def test_reset_browser_survives_an_unreachable_worker(monkeypatch):
    def boom(*a, **k):
        raise OSError("connection refused")
    monkeypatch.setattr(broker.urllib.request, "urlopen", boom)
    assert broker.reset_browser("10.0.0.1") == 0
