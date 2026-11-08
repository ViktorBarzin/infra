"""Tests for the hub's snapshot + tombstone store and the push handler.

Run: cd stacks/chrome-service/files/broker && python3 -m pytest test_hub_store.py -v
"""
import json

import pytest

import cookie_merge as cm
import hub_store

NOW = 1_800_000_000.0
LATER = NOW + 86_400
MUCH_LATER = NOW + 30 * 86_400


def ck(name="sid", domain=".example.com", expires=LATER, value="v"):
    return {"name": name, "value": value, "domain": domain, "path": "/", "expires": expires,
            "httpOnly": True, "secure": True, "sameSite": "Lax"}


class FakeBrowser:
    """Stands in for the hub Chrome: holds cookies, applies set_cookies."""

    def __init__(self, cookies):
        self.cookies = {cm.cookie_key(c): c for c in cookies}
        self.set_calls = []

    def storage_state(self, cdp_base):
        return {"cookies": list(self.cookies.values()), "origins": []}

    def set_cookies(self, cdp_base, params):
        self.set_calls.append(params)
        for p in params:
            c = dict(p)
            c.setdefault("expires", -1)
            self.cookies[cm.cookie_key(c)] = c
        return len(params), 0


@pytest.fixture
def store(tmp_path, monkeypatch):
    browser = FakeBrowser([ck()])
    monkeypatch.setattr(hub_store.cdp_cookies, "storage_state", browser.storage_state)
    monkeypatch.setattr(hub_store.cdp_cookies, "set_cookies", browser.set_cookies)
    return hub_store.HubStore("http://cdp", tmp_path), browser


def test_refresh_writes_snapshot_and_returns_cookies(store):
    hub, _ = store
    cookies = hub.refresh(NOW)
    assert [c["name"] for c in cookies] == ["sid"]
    assert json.loads(hub.snapshot_path.read_text())["cookies"][0]["name"] == "sid"


def test_refresh_records_a_sign_out_as_a_tombstone(store):
    hub, browser = store
    hub.refresh(NOW)
    browser.cookies.clear()  # signed out at the hub
    hub.refresh(NOW + 10)
    assert hub.load_tombstones() == {cm.cookie_key(ck()): LATER}


def test_push_after_sign_out_cannot_resurrect_the_old_cookie(store):
    hub, browser = store
    hub.refresh(NOW)
    browser.cookies.clear()
    hub.refresh(NOW + 10)
    result = hub.push([ck(expires=LATER)], NOW + 20)
    assert result["accepted"] == 0
    assert result["skipped"] == {"tombstoned": 1}


def test_push_sets_accepted_cookies_and_refreshes_the_snapshot(store):
    hub, browser = store
    hub.refresh(NOW)
    result = hub.push([ck(value="fresh", expires=MUCH_LATER), ck(name="new")], NOW + 5)
    assert result["accepted"] == 2 and result["rejected"] == 0
    assert result["snapshot_cookies"] == 2
    assert all(len(call) == 2 for call in browser.set_calls)
    names = {c["name"] for c in json.loads(hub.snapshot_path.read_text())["cookies"]}
    assert names == {"sid", "new"}


def test_push_with_nothing_new_does_not_call_the_browser(store):
    hub, browser = store
    hub.refresh(NOW)
    result = hub.push([ck(expires=LATER - 5)], NOW + 5)
    assert result["accepted"] == 0
    assert browser.set_calls == []


def test_a_new_empty_hub_still_gets_a_snapshot(store):
    hub, browser = store
    browser.cookies.clear()
    hub.refresh(NOW)
    assert json.loads(hub.snapshot_path.read_text()) == {"cookies": [], "origins": []}


def test_refresh_refuses_to_overwrite_with_an_empty_jar(store):
    hub, browser = store
    hub.refresh(NOW)
    browser.cookies.clear()
    hub.refresh(NOW + 1)
    # the snapshot keeps the last good jar; only the tombstone moves
    assert json.loads(hub.snapshot_path.read_text())["cookies"]
