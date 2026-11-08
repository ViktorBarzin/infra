"""Per-user hubs in the broker: who a request belongs to, and where its workers live.

Run: cd stacks/chrome-service/files/broker && python3 -m pytest test_broker_hubs.py -v
"""
import json
import os

import pytest

import broker

HUBS = [
    broker.Hub(user="wizard", namespace="chrome-service", cdp="http://master:9222",
               token="w" * 32, warm=True),
    broker.Hub(user="emo", namespace="chrome-emo", cdp="http://emo:9222", token="e" * 32),
]
FLEET = "chrome-fleet.viktorbarzin.me"
API = "chrome-fleet-api.viktorbarzin.me"


@pytest.mark.parametrize("auth,host,forwarded,expected", [
    ("Bearer " + "w" * 32, API, True, "wizard"),
    ("Bearer " + "e" * 32, API, True, "emo"),
    ("Bearer " + "x" * 32, API, True, None),        # unknown token
    ("", API, True, None),                          # API host needs a token
    ("", FLEET, True, "wizard"),                    # FleetView, Authentik-gated
    ("", "chrome-fleet.chrome-service.svc.cluster.local:8080", False, "wizard"),  # in-cluster (tv)
    ("", "anything.example", True, None),           # some other routed host
    ("Bearer " + "e" * 32, FLEET, True, "emo"),     # a token always wins
])
def test_resolve_hub(auth, host, forwarded, expected):
    hub = broker.resolve_hub(HUBS, authorization=auth, host=host, forwarded=forwarded,
                             fleet_host=FLEET)
    assert (hub.user if hub else None) == expected


def test_hubs_from_env_reads_tokens_from_their_own_variables(monkeypatch):
    monkeypatch.setenv("HUB_TOKEN_WIZARD", "tw")
    monkeypatch.setenv("HUB_TOKEN_EMO", "te")
    raw = json.dumps([
        {"user": "wizard", "namespace": "chrome-service", "cdp": "http://m:9222",
         "token_env": "HUB_TOKEN_WIZARD", "warm": True},
        {"user": "emo", "namespace": "chrome-emo", "cdp": "http://e:9222",
         "token_env": "HUB_TOKEN_EMO"},
    ])
    hubs = broker.hubs_from_env(raw, default_cdp="http://unused")
    assert [(h.user, h.token, h.warm) for h in hubs] == [("wizard", "tw", True), ("emo", "te", False)]


def test_hubs_from_env_defaults_to_the_master_only():
    hubs = broker.hubs_from_env("", default_cdp="http://master:9222")
    assert [(h.user, h.namespace, h.cdp, h.warm) for h in hubs] == [
        ("wizard", "chrome-service", "http://master:9222", True)]


def test_build_pod_spec_places_the_worker_in_the_hub_namespace():
    template = json.load(open(os.path.join(os.path.dirname(__file__), "worker_pod.json")))
    spec = broker.build_pod_spec(template, name="chrome-worker-x", owner="emo", purpose="p",
                                 session="x", started="1", deadline=60, namespace="chrome-emo")
    assert spec["metadata"]["namespace"] == "chrome-emo"


def test_list_workers_covers_every_hub_namespace(monkeypatch):
    calls = []

    def fake_kube(method, path, body=None):
        calls.append(path)
        ns = path.split("/namespaces/")[1].split("/")[0]
        return {"items": [{"metadata": {"name": f"w-{ns}", "labels": {}}, "status": {}}]}

    monkeypatch.setattr(broker, "kube", fake_kube)
    monkeypatch.setattr(broker, "HUBS", HUBS)
    workers = broker.list_workers()
    assert sorted((w["name"], w["namespace"]) for w in workers) == [
        ("w-chrome-emo", "chrome-emo"), ("w-chrome-service", "chrome-service")]
    assert len(calls) == 2


def test_an_unreadable_second_namespace_does_not_hide_the_first(monkeypatch):
    def fake_kube(method, path, body=None):
        if "/chrome-emo/" in path:
            raise PermissionError("403")
        return {"items": [{"metadata": {"name": "w1", "labels": {}}, "status": {}}]}

    monkeypatch.setattr(broker, "kube", fake_kube)
    monkeypatch.setattr(broker, "HUBS", HUBS)
    assert [w["name"] for w in broker.list_workers()] == ["w1"]


def test_workers_for_filters_to_one_hub():
    ws = [{"name": "a", "namespace": "chrome-service"}, {"name": "b", "namespace": "chrome-emo"}]
    assert [w["name"] for w in broker.workers_for(HUBS[1], ws)] == ["b"]
