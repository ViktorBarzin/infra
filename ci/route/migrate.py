#!/usr/bin/env python3
"""Move a repo's GitHub push triggers to Woodpecker's route step.

For each .github/workflows/*.yml with an `on.push` trigger:
- the push trigger goes; workflow_dispatch gains the input `runner`;
- each `runs-on: ubuntu-*` job reads `${{ inputs.runner || 'ubuntu-*' }}`;
- the push's branches, tags, paths and paths-ignore, with their comments,
  become one route step in .woodpecker/build.yml, which runs `ci-route`.

Plan: infra docs/plans/2026-11-26-gha-quota-fallback.md. infra and
cloud-builder keep their push triggers and are never migrated.

Usage: migrate.py <repo dir> [--check]
"""

import argparse
import dataclasses
import json
import pathlib
import re
import sys

import yaml

ROUTE_IMAGE = "ghcr.io/viktorbarzin/infra-ci:latest"
RUNNER_INPUT = [
    "      runner:",
    "        description: Runner label. Woodpecker's ci-route sets it (infra ci/route).",
    "        type: string",
    "        default: ubuntu-latest",
]
EVENT_DEPENDENT = re.compile(r"github\.event\.(before|head_commit|commits|compare)")


@dataclasses.dataclass
class Trigger:
    branches: list
    tags: list
    paths: list
    paths_ignore: list
    comments: list


def _indent(line):
    return len(line) - len(line.lstrip(" "))


def _block_end(lines, start, indent):
    """Index after the block that starts at lines[start] with this indent."""
    i = start + 1
    while i < len(lines) and (not lines[i].strip() or _indent(lines[i]) > indent):
        i += 1
    return i


def migrate_workflow(text):
    """Return (new text, Trigger), or (text, None) when there is no push trigger."""
    doc = yaml.safe_load(text)
    on = doc.get(True, doc.get("on"))
    if not isinstance(on, dict) or "push" not in on:
        if on == "push" or (isinstance(on, list) and "push" in on):
            raise ValueError("write `on:` as a block before migrating")
        return text, None
    push = on["push"] or {}
    for key in ("branches-ignore", "tags-ignore"):
        if key in push:
            raise ValueError(f"push.{key} has no Woodpecker form here; move it by hand")

    lines = text.split("\n")
    on_at = next(i for i, l in enumerate(lines) if re.match(r"^on:\s*(#.*)?$", l))
    on_end = _block_end(lines, on_at, 0)
    push_at = next(i for i in range(on_at + 1, on_end) if re.match(r"^  push:", lines[i]))
    push_end = _block_end(lines, push_at, 2)
    while push_end > push_at + 1 and not lines[push_end - 1].strip():
        push_end -= 1
    comments = [l.strip() for l in lines[push_at + 1 : push_end] if l.strip().startswith("#")]
    trigger = Trigger(
        branches=list(push.get("branches", [])),
        tags=list(push.get("tags", [])),
        paths=list(push.get("paths", [])),
        paths_ignore=list(push.get("paths-ignore", [])),
        comments=comments,
    )
    del lines[push_at:push_end]
    on_end -= push_end - push_at

    wd = next((i for i in range(on_at + 1, on_end) if re.match(r"^  workflow_dispatch:", lines[i])), None)
    if wd is None:
        lines[on_at + 1 : on_at + 1] = ["  workflow_dispatch:", "    inputs:", *RUNNER_INPUT]
    else:
        wd_end = _block_end(lines, wd, 2)
        inputs = next((i for i in range(wd + 1, wd_end) if re.match(r"^    inputs:", lines[i])), None)
        if inputs is None:
            lines[wd] = "  workflow_dispatch:"
            lines[wd + 1 : wd + 1] = ["    inputs:", *RUNNER_INPUT]
        else:
            lines[inputs + 1 : inputs + 1] = RUNNER_INPUT

    new = "\n".join(lines)
    # A push now arrives as a workflow_dispatch from ci-route.
    new = re.sub(r"github\.event_name\s*==\s*'push'", "github.event_name == 'workflow_dispatch'", new)
    new = re.sub(
        r"^(\s+runs-on:\s*)(ubuntu-[\w.-]+)\s*$",
        lambda m: f"{m.group(1)}${{{{ inputs.runner || '{m.group(2)}' }}}}",
        new,
        flags=re.M,
    )
    return new, trigger


def _when(trigger):
    if not trigger.branches and not trigger.tags:
        # A bare `push:` ran on every branch and every tag.
        return [{"event": "push"}, {"event": "tag"}]
    rules = []
    if trigger.branches:
        rule = {"event": "push", "branch": trigger.branches}
        path = {}
        if trigger.paths:
            path["include"] = trigger.paths
        if trigger.paths_ignore:
            path["exclude"] = trigger.paths_ignore
        if path:
            rule["path"] = path
        rules.append(rule)
    if trigger.tags:
        rules.append({"event": "tag", "ref": [f"refs/tags/{t}" for t in trigger.tags]})
    return rules


def woodpecker_file(triggers):
    """The .woodpecker/build.yml text for {workflow file name: Trigger}."""
    out = [
        "# Starts this repo's GitHub workflows: each step asks the infra pipeline",
        "# ci-route to pick GitHub's runners, or the homelab's when the private GitHub",
        "# minutes are used up (infra",
        '# docs/architecture/ci-cd.md, "Routing builds through Woodpecker").',
        "# Each step keeps the push trigger its workflow had: generated by infra",
        "# ci/route/migrate.py. A new workflow gets a step here, not an on.push.",
        "when:",
        "  - event: [push, tag]",
        "",
        "skip_clone: true",
        "",
        "steps:",
    ]
    for name, trigger in sorted(triggers.items()):
        out += [f"  - name: {name}"]
        out += [f"    {c}" for c in trigger.comments]
        out += [
            f"    image: {ROUTE_IMAGE}",
            "    pull: true",
            "    environment:",
            "      WOODPECKER_TOKEN:",
            "        from_secret: woodpecker_api_token",
            "    commands:",
            f"      - ci-route --request {name}",
            "    when:",
        ]
        for rule in _when(trigger):
            first = True
            for key, value in rule.items():
                out.append(f"      {'- ' if first else '  '}{key}: {json.dumps(value)}")
                first = False
        out.append("")
    return "\n".join(out)


def migrate_repo(root, check=False):
    root = pathlib.Path(root)
    if root.name in ("infra", "cloud-builder"):
        raise SystemExit(f"{root.name} keeps its GitHub push triggers")
    target = root / ".woodpecker" / "build.yml"
    if target.exists():
        raise SystemExit(f"{target} exists already")
    triggers, warnings = {}, []
    for wf in sorted((root / ".github" / "workflows").glob("*.y*ml")):
        text = wf.read_text()
        new, trigger = migrate_workflow(text)
        if trigger is None:
            continue
        if EVENT_DEPENDENT.search(text):
            warnings.append(f"{wf.name}: reads github.event.* of a push; check it under workflow_dispatch")
        triggers[wf.name] = trigger
        if not check:
            wf.write_text(new)
    if triggers and not check:
        target.parent.mkdir(exist_ok=True)
        target.write_text(woodpecker_file(triggers))
    return triggers, warnings


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("repo")
    p.add_argument("--check", action="store_true", help="report only; change no file")
    a = p.parse_args(argv)
    triggers, warnings = migrate_repo(a.repo, a.check)
    for name in sorted(triggers):
        print(f"migrate: {name}")
    for w in warnings:
        print(f"migrate: WARNING {w}")
    return 0 if triggers else 1


if __name__ == "__main__":
    sys.exit(main())
