#!/usr/bin/env python3
"""Tests for the visit_record seam. Zero-dependency: run `python3 visit_collector_test.py`.

Only the pure transform is tested (external behaviour); the CDP poll/HTTP I/O is
thin edge glue, validated live.
"""
from visit_collector import visit_record

TS = "2026-07-26T10:00:00Z"


def test_page_visit_becomes_record():
    r = visit_record(
        {"type": "page", "url": "https://example.com/x?y=1", "title": "Ex", "id": "1"},
        "alice",
        TS,
    )
    assert r == {
        "ts": TS,
        "user": "alice",
        "url": "https://example.com/x?y=1",
        "title": "Ex",
        "kind": "nav",
    }, r


def test_non_page_targets_dropped():
    for typ in ("iframe", "background_page", "service_worker", "other", "worker"):
        assert visit_record({"type": typ, "url": "https://x.com", "id": "2"}, "a", TS) is None, typ


def test_internal_and_empty_urls_dropped():
    for u in (
        "about:blank",
        "chrome://newtab/",
        "chrome-extension://abc/page.html",
        "devtools://devtools/bundled/x.html",
        "data:text/html,<h1>x",
        "blob:https://x.com/uuid",
        "view-source:https://x.com",
        "",
        "   ",
    ):
        assert visit_record({"type": "page", "url": u, "id": "3"}, "a", TS) is None, u


def test_title_optional_and_url_trimmed():
    r = visit_record({"type": "page", "url": "  https://n.com  ", "id": "4"}, "bob", TS)
    assert r["url"] == "https://n.com" and r["title"] == "", r


def test_non_dict_input():
    assert visit_record(None, "a", TS) is None
    assert visit_record("nope", "a", TS) is None


def _run():
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print("visit_collector: %d tests passed" % len(fns))


if __name__ == "__main__":
    _run()
