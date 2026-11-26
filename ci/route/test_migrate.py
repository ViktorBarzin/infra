"""Tests for migrate.py on real workflow shapes (cloud, tv, portal-immich-frame).

Run: python3 -m unittest discover -s ci/route
"""

import textwrap
import unittest

import yaml

import migrate

CLI_RELEASE = textwrap.dedent(
    """\
    name: Release the CLI

    on:
      push:
        branches: [master]
        paths:
          - "cli/package.json"
          - ".github/workflows/cli-release.yml"
      workflow_dispatch: {}

    jobs:
      build:
        runs-on: ubuntu-latest
        steps:
          - run: echo hi
      publish:
        needs: build
        runs-on: ubuntu-24.04
        steps:
          - run: echo publish
      mac:
        runs-on: macos-15
        steps:
          - run: echo mac
    """
)

TV_BUILD = textwrap.dedent(
    """\
    name: Build and Push
    on:
      push:
        branches: [master]
        # Documentation never reaches the image.
        paths-ignore:
          - "docs/**"
          - "**.md"
      workflow_dispatch: {}
    jobs:
      build:
        runs-on: ubuntu-latest
        steps:
          - run: echo build
    """
)

TAG_BUILD = textwrap.dedent(
    """\
    on:
      push:
        tags: ['v*']
      # Lets a build be exercised without publishing anything.
      workflow_dispatch:
    jobs:
      apk:
        runs-on: ubuntu-latest
        steps:
          - run: echo apk
    """
)

DISPATCH_ONLY = textwrap.dedent(
    """\
    on:
      workflow_dispatch: {}
    jobs:
      a:
        runs-on: ubuntu-latest
        steps:
          - run: echo a
    """
)


def on(doc):
    w = yaml.safe_load(doc)
    return w.get(True, w.get("on"))


class Workflow(unittest.TestCase):
    def test_push_goes_and_the_runner_input_comes(self):
        new, trigger = migrate.migrate_workflow(CLI_RELEASE)
        self.assertNotIn("push", on(new))
        runner = on(new)["workflow_dispatch"]["inputs"]["runner"]
        self.assertEqual(runner["default"], "ubuntu-latest")
        self.assertEqual(trigger.branches, ["master"])
        self.assertEqual(trigger.paths, ["cli/package.json", ".github/workflows/cli-release.yml"])

    def test_ubuntu_jobs_read_the_input_and_others_keep_their_runner(self):
        new, _ = migrate.migrate_workflow(CLI_RELEASE)
        jobs = yaml.safe_load(new)["jobs"]
        self.assertEqual(jobs["build"]["runs-on"], "${{ inputs.runner || 'ubuntu-latest' }}")
        self.assertEqual(jobs["publish"]["runs-on"], "${{ inputs.runner || 'ubuntu-24.04' }}")
        self.assertEqual(jobs["mac"]["runs-on"], "macos-15")

    def test_paths_ignore_and_its_comment_move_to_the_trigger(self):
        new, trigger = migrate.migrate_workflow(TV_BUILD)
        self.assertEqual(trigger.paths_ignore, ["docs/**", "**.md"])
        self.assertIn("# Documentation never reaches the image.", trigger.comments)
        self.assertNotIn("Documentation never", new)

    def test_a_tag_trigger_and_a_bare_dispatch(self):
        new, trigger = migrate.migrate_workflow(TAG_BUILD)
        self.assertEqual(trigger.tags, ["v*"])
        self.assertEqual(trigger.branches, [])
        self.assertIn("runner", on(new)["workflow_dispatch"]["inputs"])
        self.assertIn("# Lets a build be exercised", new)

    def test_a_bare_push_runs_on_every_branch_and_tag(self):
        bare = "on:\n  push:\n  pull_request:\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: x\n"
        _, trigger = migrate.migrate_workflow(bare)
        self.assertEqual(migrate._when(trigger), [{"event": "push"}, {"event": "tag"}])

    def test_a_push_only_gate_now_means_the_dispatch(self):
        gated = (
            "on:\n  push:\n    branches: [main]\n  pull_request:\njobs:\n  deploy:\n"
            "    if: github.event_name == 'push' && github.ref == 'refs/heads/main'\n"
            "    runs-on: ubuntu-latest\n    steps:\n      - run: x\n"
        )
        new, _ = migrate.migrate_workflow(gated)
        self.assertEqual(
            yaml.safe_load(new)["jobs"]["deploy"]["if"],
            "github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main'",
        )

    def test_a_workflow_without_push_is_left_alone(self):
        self.assertEqual(migrate.migrate_workflow(DISPATCH_ONLY), (DISPATCH_ONLY, None))


class WoodpeckerFile(unittest.TestCase):
    def test_one_route_step_per_workflow_with_its_filters(self):
        _, cli = migrate.migrate_workflow(CLI_RELEASE)
        _, tv = migrate.migrate_workflow(TV_BUILD)
        _, tag = migrate.migrate_workflow(TAG_BUILD)
        doc = migrate.woodpecker_file({"cli-release.yml": cli, "build.yml": tv, "apk.yml": tag})
        wp = yaml.safe_load(doc)
        steps = {s["name"]: s for s in wp["steps"]}
        self.assertEqual(steps["cli-release.yml"]["commands"], ["ci-route --request cli-release.yml"])
        self.assertEqual(list(steps["cli-release.yml"]["environment"]), ["WOODPECKER_TOKEN"])
        self.assertEqual(
            steps["cli-release.yml"]["when"],
            [{"event": "push", "branch": ["master"], "path": {"include": cli.paths}}],
        )
        self.assertEqual(steps["build.yml"]["when"][0]["path"], {"exclude": ["docs/**", "**.md"]})
        self.assertEqual(steps["apk.yml"]["when"], [{"event": "tag", "ref": ["refs/tags/v*"]}])
        self.assertTrue(wp["skip_clone"])
        self.assertIn("# Documentation never reaches the image.", doc)


if __name__ == "__main__":
    unittest.main()
