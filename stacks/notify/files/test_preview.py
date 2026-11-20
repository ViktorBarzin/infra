"""Tests for test notifications: template rendering and sample values. Run: python3 -m unittest"""

import unittest

import preview


class FakeProm:
    """Answers instant queries from a dict {(expr, at): [result rows]}."""

    def __init__(self, answers=None, label_values=None):
        self.answers = answers or {}
        self.label_values = label_values or {}
        self.calls = []

    def query(self, expr, at=None):
        self.calls.append((expr, at))
        return self.answers.get((expr, at), self.answers.get((expr, "*"), []))

    def values(self, label, metrics):
        return self.label_values.get((label, tuple(metrics)), self.label_values.get(label, []) if metrics else [])


def row(value, **labels):
    return {"metric": labels, "value": value}


class RenderTest(unittest.TestCase):
    def r(self, text, labels=None, value=0.0, prom=None, at=None):
        return preview.render(text, labels or {}, value, prom or FakeProm(), at)

    def test_plain_text(self):
        self.assertEqual(self.r("CPU hot"), "CPU hot")

    def test_labels_both_spellings(self):
        self.assertEqual(self.r("on {{ $labels.node }} / {{ .Labels.node }}", {"node": "k8s-node3"}), "on k8s-node3 / k8s-node3")

    def test_missing_label_is_empty(self):
        self.assertEqual(self.r("[{{ $labels.nope }}]"), "[]")

    def test_value_plain_like_go(self):
        self.assertEqual(self.r("{{ $value }}", value=95.07659199593999), "95.07659199593999")
        self.assertEqual(self.r("{{ .Value }}", value=3.0), "3")

    def test_printf(self):
        self.assertEqual(self.r('{{ $value | printf "%.0f" }}%', value=95.5), "96%")
        self.assertEqual(self.r('{{ printf "%.1f" $value }}', value=2.25), "2.2")
        self.assertEqual(self.r('{{ $value | printf "%d" }}', value=3.0), "3")

    def test_humanize(self):
        self.assertEqual(self.r("{{ $value | humanize }}", value=1234567), "1.235M")
        self.assertEqual(self.r("{{ $value | humanize }}", value=0.5), "500m")
        self.assertEqual(self.r("{{ $value | humanize1024 }}", value=3 * 1024 ** 3), "3Gi")
        self.assertEqual(self.r("{{ $value | humanizePercentage }}", value=0.913), "91.3%")

    def test_humanize_duration(self):
        self.assertEqual(self.r("{{ $value | humanizeDuration }}", value=90061), "1d 1h 1m 1s")
        self.assertEqual(self.r("{{ $value | humanizeDuration }}", value=3600), "1h 0m 0s")
        self.assertEqual(self.r("{{ $value | humanizeDuration }}", value=42), "42s")
        self.assertEqual(self.r("{{ $value | humanizeDuration }}", value=0.25), "250ms")

    def test_trim_markers(self):
        self.assertEqual(self.r("a {{- $labels.x -}} b", {"x": "X"}), "aXb")

    def test_with_query_uses_first_value(self):
        prom = FakeProm({('sum(up{job="x"})', 100.0): [row(7.0)]})
        text = 'Up: {{ with query "sum(up{job=\\"x\\"})" }}{{ . | first | value | printf "%.0f" }}{{ end }} targets'
        self.assertEqual(self.r(text, prom=prom, at=100.0), "Up: 7 targets")

    def test_with_query_without_result_drops_the_block(self):
        self.assertEqual(self.r('A{{ with query "nothing" }}B{{ . | first | value }}{{ end }}C'), "AC")

    def test_unknown_action_renders_nothing(self):
        self.assertEqual(self.r("x{{ $externalLabels.cluster }}y"), "xy")


class SampleTest(unittest.TestCase):
    rule = {
        "name": "PVFillingUp",
        "query": "kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.85",
        "labels": {"severity": "warning", "notify": "page"},
        "annotations": {"summary": "PV {{ $labels.persistentvolumeclaim }} is {{ $value | humanizePercentage }} full"},
        "alerts": [],
    }

    def test_firing_now_uses_prometheus_own_text(self):
        rule = dict(self.rule, alerts=[{
            "labels": {"alertname": "PVFillingUp", "persistentvolumeclaim": "immich", "severity": "warning"},
            "annotations": {"summary": "PV immich is 91% full"},
            "state": "firing",
            "value": "9.1e-01",
        }])
        s = preview.sample(rule, FakeProm(), now=1000.0)
        self.assertEqual(s["source"], "firing now")
        self.assertEqual(s["alert"]["annotations"], {"summary": "PV immich is 91% full"})

    def test_last_firing_is_replayed(self):
        prom = FakeProm({
            (preview.last_fired_query("PVFillingUp"), None): [row(500.0)],
            (self.rule["query"], 500.0): [row(0.913, persistentvolumeclaim="immich", namespace="immich")],
        })
        s = preview.sample(self.rule, prom, now=1000.0)
        self.assertTrue(s["source"].startswith("last fired"))
        self.assertEqual(s["alert"]["annotations"]["summary"], "PV immich is 91.3% full")
        labels = s["alert"]["labels"]
        self.assertEqual((labels["alertname"], labels["severity"], labels["namespace"]), ("PVFillingUp", "warning", "immich"))

    def test_never_fired_uses_current_series_past_the_threshold(self):
        prom = FakeProm({
            ("kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes", None): [row(0.41, persistentvolumeclaim="nextcloud")],
        })
        s = preview.sample(self.rule, prom, now=1000.0)
        self.assertEqual(s["source"], "made-up value on real labels")
        self.assertEqual(s["alert"]["annotations"]["summary"], "PV nextcloud is 102% full")

    def test_nothing_known_makes_labels_up(self):
        prom = FakeProm(label_values={"persistentvolumeclaim": ["postgres-data"]})
        s = preview.sample(self.rule, prom, now=1000.0)
        self.assertEqual(s["source"], "made-up values")
        self.assertEqual(s["alert"]["annotations"]["summary"], "PV postgres-data is 102% full")

    def test_label_missing_on_the_rules_metrics_takes_any_real_value(self):
        prom = FakeProm(label_values={("persistentvolumeclaim", ()): ["any-pvc"]})
        s = preview.sample(self.rule, prom, now=1000.0)
        self.assertEqual(s["alert"]["annotations"]["summary"], "PV any-pvc is 102% full")

    def test_less_than_threshold_goes_below(self):
        self.assertEqual(preview.past_threshold("<", 10.0), 8.0)
        self.assertEqual(preview.past_threshold(">", 0.0), 1.0)
        self.assertEqual(preview.past_threshold("<", 0.0), -1.0)
        self.assertEqual(preview.past_threshold("==", 0.0), 0.0)

    def test_split_comparison(self):
        self.assertEqual(preview.split_comparison("foo > 30 * 86400"), ("foo", ">", 2592000.0))
        self.assertEqual(preview.split_comparison("a < 3 and b > 0"), None)
        self.assertEqual(preview.split_comparison("up == 0"), ("up", "==", 0.0))
        self.assertEqual(preview.split_comparison("absent(up)"), None)

    def test_prometheus_errors_still_give_a_sample(self):
        class Broken(FakeProm):
            def query(self, expr, at=None):
                raise preview.Unavailable("down")

            def values(self, label, metrics):
                raise preview.Unavailable("down")

        s = preview.sample(self.rule, Broken(), now=1000.0)
        self.assertEqual(s["source"], "made-up values")
        self.assertIn("example", s["alert"]["annotations"]["summary"])


if __name__ == "__main__":
    unittest.main()
