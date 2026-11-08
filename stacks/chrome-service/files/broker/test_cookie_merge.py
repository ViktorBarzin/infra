"""Tests for the hub's cookie merge rules.

Run: cd stacks/chrome-service/files/broker && python3 -m pytest test_cookie_merge.py -v
"""
import io
import json

import pytest

import cdp_cookies
import cookie_merge as cm

NOW = 1_800_000_000.0
LATER = NOW + 86_400
MUCH_LATER = NOW + 30 * 86_400


def ck(name="sid", domain=".example.com", path="/", expires=LATER, value="v",
       secure=True, httpOnly=True, **extra):
    c = {"name": name, "value": value, "domain": domain, "path": path,
         "expires": expires, "httpOnly": httpOnly, "secure": secure, "sameSite": "Lax"}
    c.update(extra)
    return c


def run(incoming, hub=(), tombstones=None, protected=("google.com",), hub_limit=3000):
    return cm.merge(list(incoming), list(hub), dict(tombstones or {}), NOW,
                    protected=protected, hub_limit=hub_limit)


@pytest.mark.parametrize("cookie,reason", [
    (ck(expires=-1), "session"),
    (ck(expires=0), "session"),
    (ck(expires=NOW - 1), "expired"),
    (ck(domain=".viktorbarzin.me"), "local_host"),
    (ck(domain="t3.viktorbarzin.me"), "local_host"),
    (ck(domain="viktorbarzin.me"), "local_host"),
    (ck(domain="nas.viktorbarzin.lan"), "local_host"),
    (ck(domain="localhost"), "local_host"),
    (ck(domain="10.0.10.10"), "local_host"),
    (ck(name=""), "invalid"),
])
def test_skips_cookies_that_never_go_to_the_hub(cookie, reason):
    result = run([cookie])
    assert result.accepted == []
    assert result.skipped == {reason: 1}


def test_new_cookie_on_a_known_domain_is_accepted():
    result = run([ck(name="new")], hub=[ck(name="other")])
    assert [c["name"] for c in result.accepted] == ["new"]


def test_later_expiry_replaces_the_hub_copy():
    result = run([ck(value="fresh", expires=MUCH_LATER)], hub=[ck(value="old", expires=LATER)])
    assert [c["value"] for c in result.accepted] == ["fresh"]


@pytest.mark.parametrize("incoming_expires", [LATER, LATER - 60])
def test_same_or_earlier_expiry_never_replaces_the_hub_copy(incoming_expires):
    result = run([ck(value="stale", expires=incoming_expires)], hub=[ck(value="hub", expires=LATER)])
    assert result.accepted == []
    assert result.skipped == {"not_newer": 1}


def test_hub_session_cookie_is_never_replaced():
    result = run([ck(value="x", expires=MUCH_LATER)], hub=[ck(value="hub", expires=-1)])
    assert result.accepted == []
    assert result.skipped == {"not_newer": 1}


def test_tombstoned_cookie_does_not_come_back():
    key = cm.cookie_key(ck())
    result = run([ck(expires=LATER)], tombstones={key: LATER})
    assert result.accepted == []
    assert result.skipped == {"tombstoned": 1}


def test_fresh_login_after_a_sign_out_passes_the_tombstone():
    key = cm.cookie_key(ck())
    result = run([ck(expires=MUCH_LATER)], tombstones={key: LATER})
    assert len(result.accepted) == 1


def test_protected_domain_fills_missing_but_never_replaces():
    hub = [ck(name="SID", domain=".google.com", expires=LATER)]
    replace = run([ck(name="SID", domain=".google.com", expires=MUCH_LATER)], hub=hub)
    assert replace.accepted == []
    assert replace.skipped == {"protected": 1}
    fill = run([ck(name="NEW", domain="accounts.google.com", expires=MUCH_LATER)], hub=hub)
    assert [c["name"] for c in fill.accepted] == ["NEW"]


def test_unknown_domain_needs_httponly_or_secure():
    plain = run([ck(domain=".tracker.example", secure=False, httpOnly=False)], hub=[ck()])
    assert plain.skipped == {"untrusted_new_domain": 1}
    secure = run([ck(domain=".bank.example", secure=True, httpOnly=False)], hub=[ck()])
    assert len(secure.accepted) == 1


def test_hub_limit_blocks_new_keys_but_not_updates():
    hub = [ck(name=f"c{i}") for i in range(3)]
    new = run([ck(name="extra")], hub=hub, hub_limit=3)
    assert new.skipped == {"hub_full": 1}
    update = run([ck(name="c0", expires=MUCH_LATER)], hub=hub, hub_limit=3)
    assert len(update.accepted) == 1


def test_partitioned_and_unpartitioned_cookies_are_different_keys():
    part = ck(partitionKey="https://site.example", _crHasCrossSiteAncestor=False)
    assert cm.cookie_key(part) != cm.cookie_key(ck())
    result = run([part], hub=[ck()])
    assert len(result.accepted) == 1


def test_duplicate_incoming_keys_keep_the_latest_expiry():
    result = run([ck(value="a", expires=LATER), ck(value="b", expires=MUCH_LATER)])
    assert [c["value"] for c in result.accepted] == ["b"]


def test_to_cdp_param_translates_playwright_fields():
    param = cm.to_cdp_param(ck(partitionKey="https://site.example", _crHasCrossSiteAncestor=True,
                               sameSite="None"))
    assert param["partitionKey"] == {"topLevelSite": "https://site.example", "hasCrossSiteAncestor": True}
    assert "_crHasCrossSiteAncestor" not in param
    assert param["sameSite"] == "None"
    assert param["expires"] == LATER
    plain = cm.to_cdp_param(ck())
    assert "partitionKey" not in plain


@pytest.mark.parametrize("prev,current,before,expected", [
    # a cookie that left the master before expiring becomes a tombstone
    ([ck()], [], {}, {cm.cookie_key(ck()): LATER}),
    # a cookie that is still there is not a tombstone, and clears an old one
    ([ck()], [ck()], {cm.cookie_key(ck()): NOW + 5}, {}),
    # a cookie that left because it expired is not a tombstone
    ([ck(expires=NOW - 5)], [], {}, {}),
    # session cookies never become tombstones
    ([ck(expires=-1)], [], {}, {}),
    # expired tombstones are pruned
    ([], [], {cm.cookie_key(ck(name="old")): NOW - 1}, {}),
])
def test_update_tombstones(prev, current, before, expected):
    assert cm.update_tombstones(prev, current, before, NOW) == expected


def test_tombstone_keys_survive_a_json_round_trip():
    tombs = {cm.cookie_key(ck(partitionKey="https://p.example")): LATER}
    assert cm.tombstones_from_json(cm.tombstones_to_json(tombs)) == tombs


class _FakeFramer:
    """Answers each Storage.setCookies with success, or an error for 'bad'."""

    def __init__(self):
        self.sent = []
        self._replies = []

    def send(self, opcode, payload):
        msg = json.loads(payload)
        self.sent.append(msg)
        if any(c["name"] == "bad" for c in msg["params"]["cookies"]):
            self._replies.append({"id": msg["id"], "error": {"code": -32602, "message": "Invalid cookie"}})
        else:
            self._replies.append({"id": msg["id"], "result": {}})

    def message(self):
        return json.dumps(self._replies.pop(0)).encode()

    def close(self):
        pass


def test_set_cookies_sends_one_cookie_per_call_and_counts_rejects(monkeypatch):
    framer = _FakeFramer()
    version = json.dumps({"webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/browser/x"}).encode()
    monkeypatch.setattr(cdp_cookies.urllib.request, "urlopen", lambda url, timeout=0: io.BytesIO(version))
    monkeypatch.setattr(cdp_cookies, "_handshake", lambda url, timeout: framer)
    params = [cm.to_cdp_param(ck(name=n)) for n in ("good", "bad", "good2")]
    assert cdp_cookies.set_cookies("http://127.0.0.1:9222", params) == (2, 1)
    assert [len(m["params"]["cookies"]) for m in framer.sent] == [1, 1, 1]
    assert {m["method"] for m in framer.sent} == {"Storage.setCookies"}
