#!/usr/bin/env python3
"""Unit tests for stray_workload_detect.

Run: python3 stray_workload_detect_test.py

The reconciler's whole job is telling "nobody declared this" apart from the
four legitimate ways a workload exists without appearing in Terraform state by
its own name: a Helm chart shipped it, an operator created it, a controller
owns it, or somebody wrote down a reason. Measured on the live cluster
2026-09-01, those four cover 382 of 383 workloads — so a rule that gets one of
them wrong does not produce a slightly noisy alert, it produces dozens of
findings and the alert gets muted.

The cases below are therefore mostly near-misses, plus the guards that make the
job refuse to report at all when the inventory itself looks wrong.
"""

import unittest

from stray_workload_detect import classify, parse_declared, reconcile

NOW = "2026-09-01T12:00:00Z"

EXEMPT = {
    "workloads": {
        ("Deployment", "kube-system", "coredns"): "kubeadm-managed control plane",
    },
    "pod_labels": [("app", "proxy-browser")],
    "managed_by": {"goauthentik.io"},
}


def live(kind, ns, name, labels=None, anns=None, owner=None,
         created="2026-01-01T00:00:00Z"):
    return {
        "kind": kind,
        "namespace": ns,
        "name": name,
        "labels": labels or {},
        "annotations": anns or {},
        "owner_kind": owner,
        "created": created,
    }


def helm_anns(release, release_ns=None):
    anns = {"meta.helm.sh/release-name": release}
    if release_ns:
        anns["meta.helm.sh/release-namespace"] = release_ns
    return anns


class Classify(unittest.TestCase):
    def check(self, item, declared=None, releases=None):
        return classify(item, declared or {}, releases or {}, EXEMPT, NOW)

    def test_a_declared_workload_is_accounted_for(self):
        declared = {("Deployment", "blog", "blog"): "blog"}
        reason, finding = self.check(live("Deployment", "blog", "blog"), declared)
        self.assertIsNone(finding)
        self.assertEqual(reason, "terraform:blog")

    def test_a_chart_workload_whose_release_is_declared_is_accounted_for(self):
        # THE BIGGEST FALSE-POSITIVE CLASS: 50 of 383 live workloads today are
        # shipped inside a Helm chart, so their own names appear nowhere in
        # Terraform state. Only the helm_release does.
        releases = {("monitoring", "prometheus"): "monitoring"}
        reason, finding = self.check(
            live("Deployment", "monitoring", "prometheus-server",
                 anns=helm_anns("prometheus", "monitoring")),
            releases=releases)
        self.assertIsNone(finding)
        self.assertEqual(reason, "helm:monitoring")

    def test_a_chart_workload_whose_release_is_not_declared_is_a_finding(self):
        # A hand-run `helm install`. The chart's own metadata is honest about
        # which release it belongs to; nothing declares that release.
        _, finding = self.check(
            live("Deployment", "scratch", "grafana",
                 anns=helm_anns("grafana", "scratch")))
        self.assertEqual(finding, "helm-release-undeclared:scratch/grafana")

    def test_a_release_installed_into_another_namespace_still_matches(self):
        # meta.helm.sh/release-namespace is where the RELEASE lives, which is
        # not always where the object lands (calico's tigera-operator does
        # exactly this). Keying on the object's namespace would flag it.
        releases = {("tigera-operator", "calico"): "calico"}
        reason, finding = self.check(
            live("Deployment", "calico-system", "calico-kube-controllers",
                 anns=helm_anns("calico", "tigera-operator")),
            releases=releases)
        self.assertIsNone(finding)
        self.assertEqual(reason, "helm:calico")

    def test_a_release_annotation_without_a_namespace_falls_back_to_the_object(self):
        releases = {("crowdsec", "crowdsec"): "crowdsec"}
        reason, finding = self.check(
            live("Deployment", "crowdsec", "crowdsec-agent",
                 anns=helm_anns("crowdsec")),
            releases=releases)
        self.assertIsNone(finding)
        self.assertEqual(reason, "helm:crowdsec")

    def test_an_operator_created_workload_with_an_owner_is_accounted_for(self):
        # kyverno's ClusterPolicy -> Deployment, tigera's Installation ->
        # DaemonSet, mysql's InnoDBCluster -> StatefulSet. 17 workloads today.
        reason, finding = self.check(
            live("Deployment", "kyverno", "kyverno-background-controller",
                 owner="ClusterPolicy"))
        self.assertIsNone(finding)
        self.assertEqual(reason, "owned-by:ClusterPolicy")

    def test_a_cronjob_pod_is_accounted_for_through_its_owner(self):
        # Every CronJob run leaves Job pods behind. Without the ownerReference
        # rule each one is a stray pod, which is a few hundred findings a day.
        reason, finding = self.check(
            live("Pod", "monitoring", "image-flipflop-detect-29291760-abcde",
                 owner="Job"))
        self.assertIsNone(finding)
        self.assertEqual(reason, "owned-by:Job")

    def test_a_reconciler_created_workload_is_accounted_for(self):
        # authentik's server builds its outpost Deployments and sets NO
        # ownerReference, so they look bare. It does stamp managed-by, and that
        # value is listed in exempt.json with a reason.
        reason, finding = self.check(
            live("Deployment", "authentik", "ak-outpost-public",
                 labels={"app.kubernetes.io/managed-by": "goauthentik.io"}))
        self.assertIsNone(finding)
        self.assertEqual(reason, "reconciler:goauthentik.io")

    def test_an_owner_reference_is_preferred_over_a_managed_by_label(self):
        # Deliberate rule order: the apiserver maintains ownerReferences, while
        # managed-by is a label anything can write. The stronger evidence wins,
        # which keeps exempt.json's managed_by list carrying as little as
        # possible. Live effect: the authentik outposts' PODS are accounted for
        # by their ReplicaSet, and only the two Deployments need the label rule.
        reason, finding = self.check(
            live("Pod", "authentik", "ak-outpost-public-abc-def",
                 labels={"app.kubernetes.io/managed-by": "goauthentik.io"},
                 owner="ReplicaSet"))
        self.assertIsNone(finding)
        self.assertEqual(reason, "owned-by:ReplicaSet")

    def test_an_inherited_chart_annotation_does_not_beat_an_owner(self):
        # A chart ships a CR, the operator builds a workload from it and copies
        # the release annotations across. The release is not a declared
        # helm_release in that namespace, so returning the helm finding before
        # looking at the owner would report a perfectly-owned workload.
        reason, finding = self.check(
            live("StatefulSet", "dbaas", "mysql-cluster",
                 anns=helm_anns("some-operator-chart", "dbaas"),
                 owner="InnoDBCluster"))
        self.assertIsNone(finding)
        self.assertEqual(reason, "owned-by:InnoDBCluster")

    def test_an_unlisted_managed_by_value_does_not_launder_a_workload(self):
        # managed-by is self-asserted, so anything could claim it. Only values
        # written down in exempt.json count.
        _, finding = self.check(
            live("Deployment", "somewhere", "thing",
                 labels={"app.kubernetes.io/managed-by": "some-controller"}))
        self.assertEqual(finding, "undeclared")

    def test_an_orphaned_deployment_is_a_finding(self):
        # THE CASE THIS JOB EXISTS FOR. servarr/qbittorrent-exporter, live
        # since 2026-03-25, keel-updated to v1.7.0 in May, in no state file and
        # in no commit: a Terraform resource that was deleted from source
        # without a destroy.
        _, finding = self.check(live("Deployment", "servarr", "qbittorrent-exporter"))
        self.assertEqual(finding, "undeclared")

    def test_the_repos_own_tier_label_does_not_account_for_anything(self):
        # Every Terraform-declared workload here carries `tier`, so it is
        # tempting as an ownership marker. It proves Terraform made the object
        # ONCE, not that anything declares it now — the orphan above carries
        # tier=4-aux. Using it would blind the job to its own headline case.
        _, finding = self.check(
            live("Deployment", "servarr", "qbittorrent-exporter",
                 labels={"app": "qbittorrent-exporter", "tier": "4-aux"}))
        self.assertEqual(finding, "undeclared")

    def test_an_exempt_workload_is_accounted_for(self):
        reason, finding = self.check(live("Deployment", "kube-system", "coredns"))
        self.assertIsNone(finding)
        self.assertEqual(reason, "exempt:kubeadm-managed control plane")

    def test_exemption_wins_over_an_undeclared_helm_release(self):
        # An exemption is a recorded decision. A later rule must not re-open it
        # and turn it back into an alert.
        reason, finding = self.check(
            live("Deployment", "kube-system", "coredns",
                 anns=helm_anns("coredns", "kube-system")))
        self.assertIsNone(finding)
        self.assertTrue(reason.startswith("exempt:"))

    def test_an_old_bare_pod_is_a_finding(self):
        # monitoring/helm-unstick-manual and immich/sw-30953, both Succeeded,
        # both left behind by hand.
        _, finding = self.check(
            live("Pod", "monitoring", "helm-unstick-manual",
                 created="2026-08-01T00:00:00Z"))
        self.assertEqual(finding, "orphan-pod")

    def test_a_fresh_bare_pod_is_not_a_finding(self):
        # Somebody is mid-debug. Reporting their pod while they use it is how
        # the alert gets muted.
        reason, finding = self.check(
            live("Pod", "default", "debug-shell", created="2026-09-01T11:00:00Z"))
        self.assertIsNone(finding)
        self.assertEqual(reason, "too-new")

    def test_a_dynamic_pod_matching_an_exempt_label_is_not_a_finding(self):
        # The proxy stack starts a per-user browser pod with no owner and a
        # name containing a random suffix, so it cannot be exempted by name.
        reason, finding = self.check(
            live("Pod", "proxy", "proxy-br-someone-5f8bbfba",
                 labels={"app": "proxy-browser"}, created="2026-08-21T14:28:36Z"))
        self.assertIsNone(finding)
        self.assertEqual(reason, "dynamic-pod:app=proxy-browser")

    def test_the_same_name_in_another_namespace_is_a_different_workload(self):
        declared = {("Deployment", "a", "web"): "a"}
        _, finding = self.check(live("Deployment", "b", "web"), declared)
        self.assertEqual(finding, "undeclared")

    def test_the_same_name_with_another_kind_is_a_different_workload(self):
        # `homelab` stacks routinely name a CronJob and a Deployment the same
        # thing in one namespace.
        declared = {("Deployment", "ns", "sync"): "ns"}
        _, finding = self.check(live("CronJob", "ns", "sync"), declared)
        self.assertEqual(finding, "undeclared")

    def test_a_static_control_plane_pod_is_accounted_for_by_its_node_owner(self):
        # kube-apiserver and etcd are static pods; the kubelet owns them via an
        # ownerReference to the Node.
        reason, finding = self.check(
            live("Pod", "kube-system", "kube-apiserver-k8s-master", owner="Node"))
        self.assertIsNone(finding)
        self.assertEqual(reason, "owned-by:Node")


class Reconcile(unittest.TestCase):
    def test_an_empty_inventory_refuses_to_report(self):
        # THE HELM-UNSTICK LESSON. An extraction that returns nothing must not
        # read as "every workload in the cluster is stray".
        findings, _, refusal = reconcile(
            [live("Deployment", "a", "one"), live("Deployment", "a", "two")],
            {}, {}, EXEMPT, NOW, min_declared=150)
        self.assertEqual(findings, [])
        self.assertIn("below the floor", refusal)

    def test_a_short_inventory_refuses_to_report(self):
        # Half the stacks failing to project is the realistic version of the
        # above: not zero rows, just far too few.
        declared = {("Deployment", "ns", f"d{i}"): "ns" for i in range(40)}
        findings, _, refusal = reconcile(
            [live("Deployment", "x", "stray")], declared, {}, EXEMPT, NOW,
            min_declared=150)
        self.assertEqual(findings, [])
        self.assertIn("40 entries", refusal)

    def test_a_plausible_inventory_reports_its_findings(self):
        declared = {("Deployment", "ns", f"d{i}"): "ns" for i in range(200)}
        lives = [live("Deployment", "ns", f"d{i}") for i in range(200)]
        lives.append(live("Deployment", "servarr", "qbittorrent-exporter"))
        findings, accounted, refusal = reconcile(
            lives, declared, {}, EXEMPT, NOW, min_declared=150)
        self.assertIsNone(refusal)
        self.assertEqual(
            [(f["namespace"], f["name"]) for f in findings],
            [("servarr", "qbittorrent-exporter")])
        self.assertEqual(accounted["terraform"], 200)

    def test_too_many_findings_refuses_to_report(self):
        # The inventory passed the floor but still does not describe this
        # cluster — a stale Tier-0 file plus a namespace-scoped extraction
        # failure would look like this. A cluster where a third of everything
        # is undeclared is a broken inventory, not a finding worth alerting on.
        declared = {("Deployment", "ns", f"d{i}"): "ns" for i in range(200)}
        lives = [live("Deployment", "ns", f"d{i}") for i in range(100)]
        lives += [live("Deployment", "gone", f"g{i}") for i in range(60)]
        findings, _, refusal = reconcile(lives, declared, {}, EXEMPT, NOW,
                                         min_declared=150)
        self.assertEqual(findings, [])
        self.assertIn("inventory fault", refusal)

    def test_helm_releases_count_toward_the_inventory_floor(self):
        # A stack that ships only helm_releases still declares things. Counting
        # workloads alone would trip the floor on a Helm-heavy cluster.
        releases = {("ns", f"r{i}"): "ns" for i in range(160)}
        findings, _, refusal = reconcile(
            [live("Deployment", "ns", "r0-server", anns=helm_anns("r0", "ns"))],
            {}, releases, EXEMPT, NOW, min_declared=150)
        self.assertIsNone(refusal)
        self.assertEqual(findings, [])

    def test_findings_are_sorted_so_the_report_is_stable(self):
        declared = {("Deployment", "ns", f"d{i}"): "ns" for i in range(200)}
        lives = [live("Deployment", "ns", f"d{i}") for i in range(200)]
        lives += [live("Pod", "z", "p", created="2026-01-01T00:00:00Z"),
                  live("Deployment", "b", "x"),
                  live("Deployment", "a", "y")]
        findings, _, refusal = reconcile(lives, declared, {}, EXEMPT, NOW,
                                         min_declared=150)
        self.assertIsNone(refusal)
        self.assertEqual([(f["kind"], f["namespace"]) for f in findings],
                         [("Deployment", "a"), ("Deployment", "b"), ("Pod", "z")])


class ParseDeclared(unittest.TestCase):
    def test_workloads_and_releases_are_split(self):
        workloads, releases = parse_declared(
            "Deployment|blog|blog|blog\n"
            "HelmRelease|monitoring|prometheus|monitoring\n"
            "CronJob|monitoring|alert-digest|monitoring\n")
        self.assertEqual(workloads, {
            ("Deployment", "blog", "blog"): "blog",
            ("CronJob", "monitoring", "alert-digest"): "monitoring",
        })
        self.assertEqual(releases, {("monitoring", "prometheus"): "monitoring"})

    def test_blank_lines_are_ignored(self):
        workloads, releases = parse_declared("\n\nDeployment|a|b|c\n\n")
        self.assertEqual(len(workloads), 1)
        self.assertEqual(releases, {})

    def test_a_cluster_scoped_declaration_keeps_an_empty_namespace(self):
        workloads, _ = parse_declared("DaemonSet||node-thing|infra\n")
        self.assertIn(("DaemonSet", "", "node-thing"), workloads)

    def test_a_truncated_line_raises_rather_than_shortening_the_inventory(self):
        # A half-written line is the shape a killed psql leaves behind.
        # Dropping it silently would turn one real declaration into a finding.
        with self.assertRaises(ValueError):
            parse_declared("Deployment|blog|blog|blog\nDeployment|blog\n")

    def test_a_line_missing_its_kind_raises(self):
        # A Terraform type this projection does not map yet returns NULL for
        # kind, which psql prints as an empty field.
        with self.assertRaises(ValueError):
            parse_declared("|ns|name|stack\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
