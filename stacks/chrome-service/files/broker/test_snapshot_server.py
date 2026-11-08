"""HTTP-level tests for the hub API (files/snapshot_server.py).

Run: cd stacks/chrome-service/files/broker && python3 -m pytest test_snapshot_server.py -v
"""
import http.client
import json
import os
import sys
import threading
from http.server import ThreadingHTTPServer

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import snapshot_server  # noqa: E402


class FakeStore:
    def __init__(self, tmp_path):
        self.snapshot_path = tmp_path / "storage-state.json"
        self.snapshot_path.write_text('{"cookies": [], "origins": []}')
        self.pushed = []

    def push(self, cookies, now):
        self.pushed.append(cookies)
        return {"accepted": len(cookies), "rejected": 0, "skipped": {},
                "snapshot_cookies": len(cookies), "accepted_domains": []}


@pytest.fixture
def server(tmp_path):
    store = FakeStore(tmp_path)

    class H(snapshot_server.Handler):
        pass

    H.store, H.read_token, H.write_token = store, "r" * 32, "w" * 32
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield srv.server_address[1], store
    srv.shutdown()


def call(port, method, path, token=None, body=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = json.dumps(body).encode() if body is not None else None
    conn.request(method, path, body=data, headers=headers)
    resp = conn.getresponse()
    return resp.status, resp.read()


@pytest.mark.parametrize("method,path,token,status", [
    ("GET", "/api/snapshot", "r" * 32, 200),
    ("GET", "/api/snapshot", "w" * 32, 401),   # write token cannot read
    ("GET", "/api/snapshot", None, 401),
    ("POST", "/api/cookies", "r" * 32, 401),   # read token cannot write
    ("POST", "/api/cookies", None, 401),
    ("GET", "/nope", "r" * 32, 404),
])
def test_tokens_are_scoped(server, method, path, token, status):
    port, _ = server
    body = {"source": "test", "cookies": []} if method == "POST" else None
    assert call(port, method, path, token, body)[0] == status


def test_push_reaches_the_store(server):
    port, store = server
    status, raw = call(port, "POST", "/api/cookies", "w" * 32,
                       {"source": "test", "cookies": [{"name": "a"}]})
    assert status == 200
    assert json.loads(raw)["accepted"] == 1
    assert store.pushed == [[{"name": "a"}]]


@pytest.mark.parametrize("body", [{"cookies": "x"}, {"nope": []}, ["list"]])
def test_malformed_push_is_rejected(server, body):
    port, store = server
    assert call(port, "POST", "/api/cookies", "w" * 32, body)[0] == 400
    assert store.pushed == []


def test_too_many_cookies_is_rejected(server):
    port, store = server
    body = {"source": "t", "cookies": [{}] * (snapshot_server.MAX_COOKIES + 1)}
    assert call(port, "POST", "/api/cookies", "w" * 32, body)[0] == 413
