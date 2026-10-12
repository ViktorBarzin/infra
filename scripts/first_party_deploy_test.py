#!/usr/bin/env python3
"""Tests for first-party-deploy.sh, the Woodpecker step that rolls a
first-party app onto a freshly built image (.woodpecker/first-party-deploy.yml).

Run: python3 scripts/first_party_deploy_test.py

A fake kubectl on PATH records every call, so the tests check exactly which
`set image` and `rollout status` commands the script would run.
"""
import os
import stat
import subprocess
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(_HERE, "first-party-deploy.sh")
G = "ghcr.io/viktorbarzin"
DIGEST = "sha256:" + "a" * 64


def run(env_vars):
    with tempfile.TemporaryDirectory() as d:
        log = os.path.join(d, "calls")
        fake = os.path.join(d, "kubectl")
        with open(fake, "w") as f:
            f.write('#!/bin/sh\nprintf "%s\\n" "$*" >> "$KUBECTL_LOG"\n')
        os.chmod(fake, os.stat(fake).st_mode | stat.S_IEXEC)
        env = {"PATH": d + ":/usr/bin:/bin", "KUBECTL_LOG": log}
        env.update(env_vars)
        p = subprocess.run(["sh", SCRIPT], env=env, capture_output=True, text=True)
        calls = []
        if os.path.exists(log):
            with open(log) as f:
                calls = f.read().splitlines()
        return p.returncode, calls, p.stdout + p.stderr


class SingleContainerApps(unittest.TestCase):
    CASES = {
        "excalidraw": ("excalidraw", "excalidraw", "excalidraw", "excalidraw-library"),
        "interview-prep-app": ("interview-prep-app", "interview-prep-app", "interview-prep-app", "interview-prep-app"),
        "k8s-portal": ("k8s-portal", "k8s-portal", "portal", "k8s-portal"),
        "learning": ("learning", "learning", "learning", "learning"),
        "pages-publish": ("pages-publish", "pages-publish", "pages-publish", "pages-publish"),
    }

    def test_each_app_sets_its_own_image_then_waits(self):
        for app, (ns, deploy, container, image) in self.CASES.items():
            with self.subTest(app=app):
                rc, calls, out = run({"APP": app, "IMAGE_TAG": "abc123"})
                self.assertEqual(rc, 0, out)
                self.assertEqual(calls, [
                    f"-n {ns} set image deployment/{deploy} {container}={G}/{image}:abc123",
                    f"-n {ns} rollout status deployment/{deploy} --timeout=300s",
                ])


class MultiContainerApps(unittest.TestCase):
    def test_repowise_sets_init_and_all_containers_with_digest(self):
        rc, calls, out = run({"APP": "repowise", "IMAGE_TAG": "0.55.0", "IMAGE_DIGEST": DIGEST})
        self.assertEqual(rc, 0, out)
        ref = f"{G}/repowise:0.55.0@{DIGEST}"
        self.assertEqual(calls, [
            f"-n repowise set image deployment/repowise cross-repo={ref} api={ref} web={ref} sync={ref}",
            "-n repowise rollout status deployment/repowise --timeout=300s",
        ])

    def test_trading_bot_moves_both_deployments_together(self):
        rc, calls, out = run({"APP": "trading-bot", "IMAGE_TAG": "0.1.109"})
        self.assertEqual(rc, 0, out)
        svc = f"{G}/trading-bot-service:0.1.109"
        workers = " ".join(f"{c}={svc}" for c in (
            "signal-generator", "learning-engine", "market-data",
            "meet-kevin-watcher", "kevin-signal-bridge", "trade-executor"))
        self.assertEqual(calls, [
            f"-n trading-bot set image deployment/trading-bot-frontend "
            f"dashboard={G}/trading-bot-dashboard:0.1.109 api-gateway={svc}",
            f"-n trading-bot set image deployment/trading-bot-workers {workers}",
            "-n trading-bot rollout status deployment/trading-bot-frontend --timeout=300s",
            "-n trading-bot rollout status deployment/trading-bot-workers --timeout=300s",
        ])


class Refusals(unittest.TestCase):
    def assertRefused(self, env):
        rc, calls, out = run(env)
        self.assertNotEqual(rc, 0, out)
        self.assertEqual(calls, [], "kubectl must not run on a refused trigger")

    def test_unknown_app(self):
        self.assertRefused({"APP": "keel", "IMAGE_TAG": "abc"})

    def test_missing_app(self):
        self.assertRefused({"IMAGE_TAG": "abc"})

    def test_missing_tag(self):
        self.assertRefused({"APP": "learning"})

    def test_bad_tags(self):
        for tag in ["a b", "x;rm -rf /", "../evil", "-flag", "t" * 129, "a@b", "$(id)"]:
            with self.subTest(tag=tag):
                self.assertRefused({"APP": "learning", "IMAGE_TAG": tag})

    def test_bad_digest(self):
        for digest in ["sha256:short", "md5:" + "a" * 64, DIGEST + ";id"]:
            with self.subTest(digest=digest):
                self.assertRefused({"APP": "learning", "IMAGE_TAG": "v1", "IMAGE_DIGEST": digest})

    def test_accepts_semver_and_full_sha_tags(self):
        for tag in ["v0.1.2", "0.1.109", "4f3bd20f79015b7daa6dbc9230b1512110167990", "latest"]:
            with self.subTest(tag=tag):
                rc, calls, out = run({"APP": "learning", "IMAGE_TAG": tag})
                self.assertEqual(rc, 0, out)


if __name__ == "__main__":
    unittest.main()
