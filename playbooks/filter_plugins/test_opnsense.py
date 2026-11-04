"""Tests for the OPNsense filter plugin (playbooks/filter_plugins/opnsense.py).

    python3 -m pytest playbooks/filter_plugins/test_opnsense.py -q
"""
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(__file__))
import opnsense as opn  # noqa: E402

FW = {"wan": "192.168.1.250", "lan": "10.0.10.2", "opt1": "10.0.20.2", "opt4": "10.0.30.2"}
IFMAP = {}
PRESENT = {"wan", "lan", "opt1", "opt4"}


def rule(**kw):
    base = {"description": "r", "interface": "wan", "action": "pass", "source": {"any": True}, "destination": {"any": True}}
    base.update(kw)
    return base


def test_render_replaces_firewall_placeholders():
    out = opn.opn_render({"d": {"address": "{{ fw.opt1 }}", "port": "25"}}, FW)
    assert out == {"d": {"address": "10.0.20.2", "port": "25"}}


@pytest.mark.parametrize("profile,expected", [("staging", ["both"]), ("production", ["both", "prod-a", "prod-b"])])
def test_active_drops_other_profile(profile, expected):
    items = [{"description": "both"}, {"description": "prod-a", "profile": "production"},
             {"description": "prod-b", "enabled_in": "production"}]
    assert [i["description"] for i in opn.opn_active(items, profile)] == expected


def test_rules_keep_yaml_order_and_skip_linked_and_missing_interfaces():
    rules = [rule(description="a"), rule(description="linked", linked_nat_rule=True),
             rule(description="wg", interface="opt2"), rule(description="b", interface="lan")]
    out = opn.opn_filter_rules(rules, IFMAP, PRESENT)
    assert [(r["description"], r["sequence"]) for r in out] == [("a", "100"), ("b", "130")]
    assert opn.opn_filter_skipped(rules, IFMAP, PRESENT) == ["wg (interface opt2)"]


def test_endpoint_mapping():
    r = opn.opn_filter_rules([rule(source={"net": "lan"}, destination={"ip": "wanip", "port": "443"})], IFMAP, PRESENT)[0]
    assert (r["source_net"], r["destination_net"], r["destination_port"]) == ("lan", "wanip", "443")


def test_unrendered_placeholder_never_widens_a_rule():
    # An undefined address must not turn into '' (which the API reads as "any").
    rendered = opn.opn_render([rule(destination={"address": "{{ fw.lan_v6.split('/')[0] }}"})], FW)
    with pytest.raises(ValueError):
        opn.opn_filter_rules(rendered, IFMAP, PRESENT)


def test_unrendered_placeholder_rejected_in_nat():
    fwd = [{"description": "f", "interface": "wan", "protocol": "tcp", "destination": {"ip": "wanip", "port": "25"},
            "target": {"address": "{{ fw.nope }}"}, "local_port": "25"}]
    with pytest.raises(ValueError):
        opn.opn_dnat_rules(opn.opn_render(fwd, FW), IFMAP)
