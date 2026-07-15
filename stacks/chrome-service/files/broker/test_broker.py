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
