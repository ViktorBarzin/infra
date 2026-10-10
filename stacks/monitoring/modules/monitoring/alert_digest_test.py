#!/usr/bin/env python3
"""Tests for the weekly Trivy section of the alert digest.

Zero-dependency: `python3 alert_digest_test.py` (or pytest). Only the pure
seams are tested: the weekday gate, the stats collector driven by a fake
query function, and the message builder. Prometheus/Slack I/O is edge glue.
"""
import datetime

import alert_digest as ad

MONDAY = datetime.datetime(2026, 10, 12, 7, 0, tzinfo=datetime.timezone.utc)
TUESDAY = MONDAY + datetime.timedelta(days=1)


def _sev(**counts):
    return [{"metric": {"severity": k}, "value": [0, str(v)]} for k, v in counts.items()]


def test_trivy_day_gate():
    assert ad.is_trivy_day(MONDAY, 0)
    assert not ad.is_trivy_day(TUESDAY, 0)
    assert ad.is_trivy_day(TUESDAY, 1)


def test_parse_trivy_weekday():
    assert ad.parse_weekday("Mon") == 0
    assert ad.parse_weekday("sunday") == 6
    assert ad.parse_weekday("3") == 3
    assert ad.parse_weekday("never") is None
    assert ad.parse_weekday("") is None


def test_delta_formatting():
    assert ad._delta(10, 7) == "+3"
    assert ad._delta(7, 10) == "-3"
    assert ad._delta(5, 5) == "±0"
    assert ad._delta(5, None) == "no data a week ago"


def _fake_query(responses):
    """Return a query function that answers by substring match on the PromQL."""

    def q(promql):
        for needle, result in responses:
            if needle in promql:
                return result
        return []

    return q


def test_collect_trivy_stats_maps_queries():
    q = _fake_query(
        [
            # order matters: more specific needles first
            ("trivy_image_vulnerabilities{severity=~\"Critical|High\"}[1h] offset 7d", _sev(Critical=4, High=40)),
            ("trivy_image_vulnerabilities{severity=~\"Critical|High\"}[1h]", _sev(Critical=5, High=50)),
            ("count by (namespace, name)", [{"metric": {}, "value": [0, "240"]}]),
            ("topk(", [
                {"metric": {"namespace": "web", "image_repository": "library/nginx", "image_tag": "1.25"}, "value": [0, "12"]},
                {"metric": {"namespace": "batch", "image_repository": "acme/job", "image_tag": "v1"}, "value": [0, "3"]},
            ]),
            ("trivy_vulnerability_id[1h] offset 7d", _sev(Critical=2, High=20)),
            ("and on (namespace)", _sev(Critical=1, High=12)),
            ("trivy_vulnerability_id[1h]", _sev(Critical=3, High=30)),
            ("trivy_image_exposedsecrets", [{"metric": {}, "value": [0, "2"]}]),
            ("trivy_resource_configaudits offset 7d", _sev(High=9)),
            ("trivy_resource_configaudits", _sev(Critical=1, High=10, Medium=20, Low=30)),
            ("rbacassessments", _sev(Critical=2, High=3)),
            ("trivy_resource_infraassessments", _sev(High=1, Low=4)),
            ("trivy_cluster_compliance", [{"metric": {"title": "CIS Kubernetes Benchmarks v1.23"}, "value": [0, "17"]}]),
            ("kube_ingress_annotations", [{"metric": {"namespace": "web"}, "value": [0, "1"]}]),
        ]
    )
    s = ad.collect_trivy_stats(q)
    assert s["vuln_total"] == {"Critical": 5, "High": 50}
    assert s["vuln_total_prev"] == {"Critical": 4, "High": 40}
    assert s["fixable"] == {"Critical": 3, "High": 30}
    assert s["fixable_prev"] == {"Critical": 2, "High": 20}
    assert s["fixable_public"] == {"Critical": 1, "High": 12}
    assert s["scanned"] == 240
    assert s["secret_images"] == 2
    assert s["top_fixable"][0] == {"namespace": "web", "image": "library/nginx:1.25", "count": 12, "public": True}
    assert s["top_fixable"][1]["public"] is False
    assert s["config_audit"]["Low"] == 30
    assert s["config_audit_prev"] == {"High": 9}
    assert s["compliance_fail"] == {"CIS Kubernetes Benchmarks v1.23": 17}


def test_collect_trivy_stats_empty_prev_is_none():
    q = _fake_query([("trivy_image_vulnerabilities{severity=~\"Critical|High\"}[1h]))", _sev(Critical=1, High=1))])
    s = ad.collect_trivy_stats(q)
    # "offset 7d" queries answer [] here (no data a week ago) -> None, not zeros
    assert s["vuln_total_prev"] is None
    assert s["fixable_prev"] is None


def _stats(**over):
    base = {
        "scanned": 240,
        "vuln_total": {"Critical": 5, "High": 50},
        "vuln_total_prev": {"Critical": 4, "High": 52},
        "fixable": {"Critical": 3, "High": 30},
        "fixable_prev": None,
        "fixable_public": {"Critical": 1, "High": 12},
        "top_fixable": [{"namespace": "web", "image": "library/nginx:1.25", "count": 12, "public": True}],
        "secret_images": 2,
        "config_audit": {"Critical": 1, "High": 10, "Medium": 20, "Low": 30},
        "config_audit_prev": {"Critical": 1, "High": 10, "Medium": 20, "Low": 30},
        "rbac": {"Critical": 2, "High": 3},
        "infra": {"High": 1, "Low": 4},
        "compliance_fail": {"CIS Kubernetes Benchmarks v1.23": 17},
    }
    base.update(over)
    return base


def test_build_trivy_section_contents():
    msg = ad.build_trivy_section(_stats())
    assert "Weekly Trivy summary" in msg
    assert "240" in msg
    # totals with week-over-week change
    assert "Critical 5 (+1)" in msg, msg
    assert "High 50 (-2)" in msg, msg
    # fixable with no prior week
    assert "fixable Critical 3, High 30" in msg, msg
    assert "no data a week ago" in msg, msg
    # unfixable = total - fixable
    assert "unfixable Critical 2, High 20" in msg, msg
    assert "web" in msg and "library/nginx:1.25" in msg and "12" in msg
    assert "internet-reachable" in msg
    assert "2 image(s)" in msg
    assert "Config audit: Critical 1, High 10 (total \u00b10)" in msg, msg
    assert "Medium" not in msg, msg
    assert "CIS Kubernetes Benchmarks v1.23: 17" in msg


def test_build_trivy_section_no_data():
    msg = ad.build_trivy_section(_stats(scanned=0, vuln_total={}, fixable={}, top_fixable=[]))
    assert "no scan data" in msg.lower(), msg


def test_build_message_appends_trivy_section():
    msg = ad.build_message([], [], trivy_section="TRIVY-BLOCK")
    assert msg.endswith("TRIVY-BLOCK"), msg
    assert "TRIVY-BLOCK" not in ad.build_message([], [])


def _alert(name, summary, sev="warning"):
    return {"alertname": name, "severity": sev, "lane": "", "summary": summary, "age": "1h"}


def test_many_instances_of_one_alert_collapse_to_one_line():
    alerts = [_alert("TrivyFixableCVEInternetReachable", "ns%d: 3 fixable" % i) for i in range(40)]
    alerts.append(_alert("PayslipStale", "payslip late"))
    msg = ad.build_message(alerts, [])
    assert msg.count("TrivyFixableCVEInternetReachable") == 1, msg
    assert "\u00d740" in msg, msg
    assert "ns0: 3 fixable" in msg, msg
    assert "ns39" not in msg, msg
    assert "PayslipStale" in msg and "payslip late" in msg, msg
    # the header still counts every alert
    assert "*41*" in msg, msg


def test_few_instances_stay_listed():
    alerts = [_alert("JobFailed", "job %d" % i) for i in range(3)]
    msg = ad.build_message(alerts, [])
    assert msg.count("JobFailed") == 3, msg


if __name__ == "__main__":
    import sys

    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print("ok   ", name)
            except Exception as e:  # noqa: BLE001 - test runner reports every failure
                failed += 1
                print("FAIL ", name, "-", repr(e))
    sys.exit(1 if failed else 0)
