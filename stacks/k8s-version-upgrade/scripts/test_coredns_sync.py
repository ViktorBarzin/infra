"""Tests for coredns-sync.py's decision and DNS-packet helpers.

Run: python3 -m pytest stacks/k8s-version-upgrade/scripts/test_coredns_sync.py
"""
import importlib.util
import pathlib
import struct

import pytest

_spec = importlib.util.spec_from_file_location(
    "coredns_sync", pathlib.Path(__file__).with_name("coredns-sync.py"))
cs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cs)

KUBEADM = "registry.k8s.io/coredns/coredns:v1.13.1"


@pytest.mark.parametrize("live,want", [
    ("registry.k8s.io/coredns/coredns:v1.12.4", "upgrade"),
    ("registry.k8s.io/coredns/coredns:v1.13.0", "upgrade"),
    ("registry.k8s.io/coredns/coredns:v1.13.1", "unchanged"),
    ("registry.k8s.io/coredns/coredns:v1.13.2", "newer"),
    ("registry.k8s.io/coredns/coredns:v1.14.0", "newer"),
    # A mirror or a different repo with the same tag is still that version.
    ("docker.io/coredns/coredns:1.13.1", "unchanged"),
    ("docker.io/coredns/coredns:1.12.0", "upgrade"),
])
def test_decide_compares_versions_not_strings(live, want):
    assert cs.decide(live, KUBEADM) == want


@pytest.mark.parametrize("live", [
    "registry.k8s.io/coredns/coredns:latest",
    "registry.k8s.io/coredns/coredns@sha256:" + "a" * 64,
    "registry.k8s.io/coredns/coredns",
])
def test_decide_leaves_an_unreadable_live_tag_alone(live):
    assert cs.decide(live, KUBEADM) == "unknown"


def test_decide_refuses_an_unreadable_kubeadm_tag():
    assert cs.decide("registry.k8s.io/coredns/coredns:v1.13.1",
                     "registry.k8s.io/coredns/coredns:latest") == "unknown"


def test_digest_suffix_is_ignored_when_a_tag_is_present():
    live = "registry.k8s.io/coredns/coredns:v1.12.0@sha256:" + "b" * 64
    assert cs.decide(live, KUBEADM) == "upgrade"


def test_registry_port_is_not_mistaken_for_a_tag():
    assert cs.decide("mirror.lan:5000/coredns/coredns:v1.13.1", KUBEADM) == "unchanged"


def test_kubeadm_image_is_picked_from_the_images_list():
    listing = "\n".join([
        "registry.k8s.io/kube-apiserver:v1.35.9",
        "registry.k8s.io/kube-proxy:v1.35.9",
        "registry.k8s.io/coredns/coredns:v1.13.1",
        "registry.k8s.io/pause:3.10.1",
    ])
    assert cs.coredns_from_images_list(listing) == KUBEADM


def test_images_list_without_coredns_is_an_error():
    with pytest.raises(ValueError):
        cs.coredns_from_images_list("registry.k8s.io/pause:3.10.1\n")


def _response(query: bytes, rcode: int, answers: int) -> bytes:
    qid = struct.unpack(">H", query[:2])[0]
    flags = 0x8180 | rcode
    return struct.pack(">HHHHHH", qid, flags, 1, answers, 0, 0) + query[12:]


def test_answer_with_records_counts_as_resolved():
    q = cs.build_query("kubernetes.default.svc.cluster.local", qid=4242)
    assert cs.parse_answer(q, _response(q, 0, 1))


@pytest.mark.parametrize("rcode,answers", [(3, 0), (2, 0), (0, 0)])
def test_nxdomain_servfail_or_empty_answer_is_not_resolved(rcode, answers):
    q = cs.build_query("kubernetes.default.svc.cluster.local", qid=7)
    assert not cs.parse_answer(q, _response(q, rcode, answers))


def test_reply_to_another_query_id_is_not_resolved():
    q = cs.build_query("kubernetes.default.svc.cluster.local", qid=1)
    other = cs.build_query("kubernetes.default.svc.cluster.local", qid=2)
    assert not cs.parse_answer(q, _response(other, 0, 1))


def test_query_encodes_the_name_as_labels():
    q = cs.build_query("a.bc", qid=0)
    assert q[12:] == b"\x01a\x02bc\x00" + struct.pack(">HH", 1, 1)
