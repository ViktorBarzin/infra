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
