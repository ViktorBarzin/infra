"""Unit tests for the FleetView thumbnail capture (no network).

Run: cd stacks/chrome-service/files/broker && python3 -m pytest test_screenshot.py -v
"""
import base64
import json
import sys

import pytest

import screenshot

PNG = b"\x89PNG\r\n\x1a\nfake-image-bytes"


def page(target_id, url, context="ctx-default", kind="page"):
    target = {"targetId": target_id, "type": kind, "url": url, "attached": True}
    if context is not None:
        target["browserContextId"] = context
    return target


# ------------------------------------------------------------------ pick_page
def test_pick_page_prefers_the_callers_context_over_the_launch_tab():
    # A worker launches Chrome on about:blank in the default context, and
    # browser_runner.js opens its page in a context of its own.
    targets = [
        page("launch", "about:blank"),
        page("caller", "https://example.com/", context="ctx-caller"),
    ]
    assert screenshot.pick_page(targets, {"ctx-caller"}) == "caller"


def test_pick_page_skips_targets_without_a_browser_context():
    # The embed.st orphan (infra #98) is a service worker with no
    # browserContextId. A page-type target missing it is skipped the same way.
    targets = [
        page("orphan-sw", "https://embed.st/sw.js", context=None, kind="service_worker"),
        page("orphan-page", "https://embed.st/", context=None),
        page("caller", "https://example.com/", context="ctx-caller"),
    ]
    assert screenshot.pick_page(targets, {"ctx-caller"}) == "caller"


def test_pick_page_skips_internal_pages():
    targets = [
        page("newtab", "chrome://newtab/", context="ctx-caller"),
        page("devtools", "devtools://devtools/bundled/inspector.html", context="ctx-caller"),
        page("ext", "chrome-extension://abc/popup.html", context="ctx-caller"),
        page("real", "https://example.com/"),
    ]
    assert screenshot.pick_page(targets, {"ctx-caller"}) == "real"


def test_pick_page_ignores_non_page_targets():
    targets = [
        page("frame", "https://ads.example/", context="ctx-caller", kind="iframe"),
        page("worker", "https://example.com/w.js", context="ctx-caller", kind="worker"),
        page("shared", "https://example.com/s.js", context="ctx-caller", kind="shared_worker"),
        page("browser", "", context=None, kind="browser"),
        page("real", "https://example.com/"),
    ]
    assert screenshot.pick_page(targets, {"ctx-caller"}) == "real"


def test_pick_page_falls_back_to_the_default_context_preferring_a_real_url():
    # --shared-context callers work in the default context beside the
    # launch tab, so a loaded page beats about:blank there too.
    targets = [
        page("launch", "about:blank"),
        page("shared-caller", "https://example.com/"),
    ]
    assert screenshot.pick_page(targets, set()) == "shared-caller"


def test_pick_page_keeps_chromes_order_between_equals():
    targets = [
        page("first", "https://a.example/", context="ctx-caller"),
        page("second", "https://b.example/", context="ctx-caller"),
    ]
    assert screenshot.pick_page(targets, {"ctx-caller"}) == "first"


def test_pick_page_returns_a_blank_page_rather_than_nothing():
    assert screenshot.pick_page([page("launch", "about:blank")], set()) == "launch"


def test_pick_page_returns_none_when_nothing_is_capturable():
    targets = [
        page("orphan-sw", "https://embed.st/sw.js", context=None, kind="service_worker"),
        page("newtab", "chrome://newtab/"),
    ]
    assert screenshot.pick_page(targets, set()) is None
    assert screenshot.pick_page([], set()) is None


# ------------------------------------------------------------------ Client
class FakeFramer:
    def __init__(self, incoming):
        self.sent = []
        self._incoming = [json.dumps(m).encode() for m in incoming]
        self.closed = False

    def send(self, opcode, payload):
        self.sent.append(json.loads(payload))

    def message(self):
        return self._incoming.pop(0)

    def close(self):
        self.closed = True


def test_client_skips_events_and_other_replies_until_its_own():
    framer = FakeFramer([
        {"method": "Target.targetCreated", "params": {}},
        {"id": 99, "result": {"not": "ours"}},
        {"id": 1, "result": {"ok": True}},
    ])
    client = screenshot.Client(framer)
    assert client.call("Target.getTargets") == {"ok": True}
    assert framer.sent == [{"id": 1, "method": "Target.getTargets", "params": {}}]


def test_client_routes_a_session_command_and_numbers_each_call():
    framer = FakeFramer([{"id": 1, "result": {}}, {"id": 2, "result": {"data": "x"}}])
    client = screenshot.Client(framer)
    client.call("Target.getBrowserContexts")
    assert client.call("Page.captureScreenshot", {"format": "png"}, session_id="S1") == {"data": "x"}
    assert framer.sent[1] == {"id": 2, "method": "Page.captureScreenshot",
                              "params": {"format": "png"}, "sessionId": "S1"}


def test_client_raises_on_an_error_reply():
    framer = FakeFramer([{"id": 1, "error": {"code": -32602, "message": "No target with given id"}}])
    with pytest.raises(RuntimeError, match="Target.attachToTarget"):
        screenshot.Client(framer).call("Target.attachToTarget", {"targetId": "gone"})


# ------------------------------------------------------------------ capture
class FakeClient:
    def __init__(self, targets, contexts, png=PNG):
        self.calls = []
        self.closed = False
        self._replies = {
            "Target.getTargets": {"targetInfos": targets},
            "Target.getBrowserContexts": {"browserContextIds": contexts,
                                          "defaultBrowserContextId": "ctx-default"},
            "Target.attachToTarget": {"sessionId": "S1"},
            "Page.captureScreenshot": {"data": base64.b64encode(png).decode()},
        }

    def call(self, method, params=None, session_id=None):
        self.calls.append((method, params or {}, session_id))
        return self._replies[method]

    def close(self):
        self.closed = True


WORKER_TARGETS = [
    {"targetId": "orphan-sw", "type": "service_worker", "url": "https://embed.st/sw.js"},
    page("launch", "about:blank"),
    page("caller", "https://example.com/", context="ctx-caller"),
]


def test_capture_attaches_only_to_the_picked_page_and_returns_png_bytes():
    client = FakeClient(WORKER_TARGETS, ["ctx-caller"])
    assert screenshot.capture(client) == PNG
    attach = [c for c in client.calls if c[0] == "Target.attachToTarget"]
    assert attach == [("Target.attachToTarget", {"targetId": "caller", "flatten": True}, None)]
    assert ("Page.captureScreenshot", {"format": "png"}, "S1") in client.calls


def test_capture_enables_no_domain_on_the_callers_page():
    # Runtime.enable on the caller's (possibly anti-bot) page is the
    # fingerprint the pool exists to avoid; nothing here may enable a domain.
    client = FakeClient(WORKER_TARGETS, ["ctx-caller"])
    screenshot.capture(client)
    methods = [c[0] for c in client.calls]
    assert not [m for m in methods if m.endswith(".enable") or m.startswith("Runtime.")]


def test_capture_returns_none_without_attaching_when_no_page_qualifies():
    client = FakeClient([WORKER_TARGETS[0]], [])
    assert screenshot.capture(client) is None
    assert not [c for c in client.calls if c[0] == "Target.attachToTarget"]


# ------------------------------------------------------------------ main
def test_main_needs_a_cdp_url(monkeypatch):
    monkeypatch.setattr(sys, "argv", ["screenshot.py"])
    assert screenshot.main() == 2


def test_main_writes_the_png_and_closes_the_connection(monkeypatch, capsysbinary):
    client = FakeClient(WORKER_TARGETS, ["ctx-caller"])
    seen = []
    monkeypatch.setattr(screenshot, "connect", lambda url: seen.append(url) or client)
    monkeypatch.setattr(sys, "argv", ["screenshot.py", "http://10.10.1.2:9222"])
    assert screenshot.main() == 0
    assert capsysbinary.readouterr().out == PNG
    assert seen == ["http://10.10.1.2:9222"] and client.closed


def test_main_exits_3_when_there_is_no_page(monkeypatch, capsysbinary):
    client = FakeClient([WORKER_TARGETS[0]], [])
    monkeypatch.setattr(screenshot, "connect", lambda url: client)
    monkeypatch.setattr(sys, "argv", ["screenshot.py", "http://10.10.1.2:9222"])
    assert screenshot.main() == 3
    assert capsysbinary.readouterr().out == b"" and client.closed
