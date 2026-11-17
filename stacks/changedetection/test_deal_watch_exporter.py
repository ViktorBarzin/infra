"""Tests for the deal-watch exporter.

Run: python3 -m pytest stacks/changedetection/test_deal_watch_exporter.py -q
"""

import pytest

import deal_watch_exporter as exp

SD = "9deeea86-88fc-41eb-a267-0448f5abd72b"
OLD = "11111111-2222-3333-4444-555555555555"


def detail(uuid, **over):
    """One watch in the shape GET /api/v1/watch/<uuid> returns (0.70.3)."""
    w = {
        "uuid": uuid,
        "title": "SD card, NEW only (Amazon UK)",
        "url": "https://www.amazon.co.uk/dp/B09X7FXHVJ",
        "paused": False,
        "last_checked": 1794901196,
        "last_error": False,
        "last_notification_error": False,
        "time_between_check": {"weeks": None, "days": None, "hours": 4, "minutes": None, "seconds": None},
        "processor": "restock_diff",
        "processor_config_restock_diff": {"price_change_min": 35.67, "follow_price_changes": True},
        "processor_state_restock_diff": {"in_stock": None, "price": 35.67, "currency": "£", "last_price": None},
    }
    w.update(over)
    return w


def fake_api(details):
    """An api_get over a fixed set of watches, all in the deals group."""
    def api_get(path):
        if path == "watch?tag=deals":
            return {u: {"title": d["title"]} for u, d in details.items()}
        if path.startswith("watch/"):
            return details[path.split("/", 1)[1]]
        raise AssertionError(f"unexpected call {path}")
    return api_get


def test_collect_reads_each_watch_in_the_group():
    got = exp.collect(fake_api({SD: detail(SD)}), tag="deals")
    assert len(got) == 1
    s = got[0]
    assert s.uuid == SD
    assert s.last_checked == 1794901196
    assert s.interval_s == 4 * 3600
    assert s.failing is False
    assert s.notification_failing is False
    assert s.price == 35.67
    assert s.target == 35.67


def test_an_error_string_counts_as_failing():
    d = detail(SD, last_error="Warning, no filters were found, no change detection ran")
    assert exp.collect(fake_api({SD: d}), tag="deals")[0].failing is True


def test_a_notification_error_counts_as_notification_failing():
    d = detail(SD, last_notification_error="Slack returned 404")
    assert exp.collect(fake_api({SD: d}), tag="deals")[0].notification_failing is True


def test_no_own_interval_falls_back_to_the_global_default():
    empty = {"weeks": None, "days": None, "hours": None, "minutes": None, "seconds": None}
    d = detail(SD, time_between_check=empty)
    assert exp.collect(fake_api({SD: d}), tag="deals")[0].interval_s == exp.DEFAULT_INTERVAL_S


def test_interval_adds_up_every_unit():
    d = detail(SD, time_between_check={"weeks": None, "days": 1, "hours": 2, "minutes": 30, "seconds": None})
    assert exp.collect(fake_api({SD: d}), tag="deals")[0].interval_s == 86400 + 7200 + 1800


def test_no_price_yet_leaves_price_unset():
    d = detail(SD, processor_state_restock_diff={"price": None, "currency": None})
    s = exp.collect(fake_api({SD: d}), tag="deals")[0]
    assert s.price is None
    assert "deal_watch_price{" not in exp.render([s], now=1794901300)


def test_render_has_the_gauges_the_alerts_read():
    s = exp.collect(fake_api({SD: detail(SD)}), tag="deals")
    text = exp.render(s, now=1794901300)
    labels = f'uuid="{SD}",title="SD card, NEW only (Amazon UK)"'
    assert f"deal_watch_last_checked_timestamp_seconds{{{labels}}} 1794901196" in text
    assert f"deal_watch_check_interval_seconds{{{labels}}} 14400" in text
    assert f"deal_watch_check_failing{{{labels}}} 0" in text
    assert f"deal_watch_notification_failing{{{labels}}} 0" in text
    assert f"deal_watch_paused{{{labels}}} 0" in text
    assert f"deal_watch_price{{{labels}}} 35.67" in text
    assert f"deal_watch_target_price{{{labels}}} 35.67" in text
    assert "deal_watches_total 1" in text
    assert "deal_watches_exporter_last_success_timestamp_seconds 1794901300" in text
    assert text.endswith("\n")


def test_render_escapes_quotes_and_backslashes_in_titles():
    s = exp.collect(fake_api({SD: detail(SD, title='Card "fast" \\ cheap')}), tag="deals")
    assert 'title="Card \\"fast\\" \\\\ cheap"' in exp.render(s, now=1)


def test_an_empty_group_still_reports_success():
    text = exp.render(exp.collect(fake_api({}), tag="deals"), now=5)
    assert "deal_watches_total 0" in text
    assert "deal_watches_exporter_last_success_timestamp_seconds 5" in text


def test_api_key_comes_from_the_homepage_credentials_json():
    raw = '{"changedetection": {"api_key": "abc123"}}'
    assert exp.api_key_from_env({"CHANGEDETECTION_CREDENTIALS": raw}) == "abc123"


def test_api_failure_raises_so_the_job_fails():
    def broken(path):
        raise OSError("connection refused")
    with pytest.raises(OSError):
        exp.collect(broken, tag="deals")
