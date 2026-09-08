#!/usr/bin/env python3
"""Tests for the build_digest seam. Zero-dependency: `python3 proxy_visit_digest_test.py`.

Only the pure message builder is tested; Loki/Slack I/O is thin edge glue.
"""
from proxy_visit_digest import build_digest, _domain

DATE = "Sun 26 Jul 2026"


def _recs(*pairs):
    return [{"user": u, "url": url, "kind": "nav"} for u, url in pairs]


def test_none_on_no_activity():
    assert build_digest([], None, DATE) is None


def test_none_when_only_excluded_user():
    recs = _recs(("vbarzin@gmail.com", "https://x.com"))
    assert build_digest(recs, "vbarzin@gmail.com", DATE) is None


def test_excluded_user_dropped_but_others_kept():
    recs = _recs(
        ("vbarzin@gmail.com", "https://secret.com"),
        ("alice", "https://github.com/a"),
    )
    msg = build_digest(recs, "vbarzin@gmail.com", DATE)
    assert "secret.com" not in msg, msg
    assert "alice" in msg and "github.com" in msg, msg
    assert "1 user" in msg, msg  # only alice counted


def test_per_user_domain_counts_and_ranking():
    recs = _recs(
        ("alice", "https://github.com/a"),
        ("alice", "https://github.com/b"),
        ("alice", "https://news.ycombinator.com/"),
        ("bob", "https://youtube.com/watch"),
    )
    msg = build_digest(recs, None, DATE)
    # 2 users, 4 pages
    assert "2 users, 4 pages" in msg, msg
    # alice: github.com x2 ranked before news.ycombinator.com x1
    alice_line = [l for l in msg.splitlines() if l.startswith("• *alice*")][0]
    assert alice_line.index("github.com ×2") < alice_line.index("news.ycombinator.com ×1"), alice_line
    assert "*alice* (3)" in alice_line, alice_line


def test_www_stripped_and_grouped():
    recs = _recs(
        ("alice", "https://www.example.com/1"),
        ("alice", "https://example.com/2"),
    )
    msg = build_digest(recs, None, DATE)
    assert "example.com ×2" in msg, msg
    assert "www.example.com" not in msg, msg


def test_domain_helper():
    assert _domain("https://www.foo.com/x?y=1") == "foo.com"
    assert _domain("https://sub.foo.com/") == "sub.foo.com"
    assert _domain("not a url") == "(unknown)"


def _run():
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print("proxy_visit_digest: %d tests passed" % len(fns))


if __name__ == "__main__":
    _run()
