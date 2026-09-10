#!/usr/bin/env python3
"""Turn a nightly drift run's saved plans into a report that says WHAT differs.

Background. The nightly drift job used to report a bare count and a list of
stack names ("Drift detected in: ac android-emulator ..."). That is not enough
to act on, and it is not enough to sanity-check either: on 2026-08-16 the run
reported 79 drifting / 45 clean / 29 error, which read as a mass revert. It was
neither — 5 of 6 sampled stacks re-planned clean by hand. Two separate things
had gone wrong, and a name-only message could not show either:

  * The run clones master once at 00:00 and then plans for hours. The renew-tls
    certificate commit lands ~00:06, so every stack using module.tls_secret was
    compared against the pre-renewal certificate and reported as drifting. The
    fix here is not to stop that happening, but to record the commit the run
    planned against so it is visible in the report.
  * A mid-run state-backend blip errored every remaining stack. Tier-1 stacks
    read state from CNPG, and when the Postgres primary was liveness-killed the
    rest of the run could not plan. Those stacks were reported alongside genuine
    drift, so "79 stacks differ" included 29 that we simply had not measured.

So this script does three things: show the actual resource-level differences,
keep "could not be planned" strictly separate from "differs", and name the
commit that was planned against.

Input is a directory holding, per stack, `<stack>.exit` (terraform's
-detailed-exitcode: 0 clean, 1 error, 2 drift) and `<stack>.out` (the captured
plan output). Writing files rather than shell variables is deliberate — see the
pipeline comments for the Woodpecker interpolation and `set -e` problems that
shape has already caused.

Run:  drift-report.py <plans_dir> [--commit SHA] [--pipeline-url URL]
                      [--slack-json FILE]
Tests: python3 scripts/drift_report_test.py
"""
import argparse
import json
import os
import re
import sys

# Slack hard-limits a message's text; keep well under it so a huge drift run
# still delivers something rather than being rejected wholesale.
SLACK_MAX_CHARS = 3500

MAX_STACKS = 12
MAX_RESOURCES = 6

_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

# Terragrunt prefixes terraform output with a timestamp and "STDOUT terraform: ".
# Match wherever the interesting part sits on the line rather than anchoring at
# the start, which is what made an earlier grep silently return nothing.
_PLAN = re.compile(
    r"Plan:\s+(\d+)\s+to add,\s+(\d+)\s+to change,\s+(\d+)\s+to destroy"
)

# Only `# <address> will be ...` / `must be ...` lines name a resource. The `~`
# and `+` markers inside the diff body belong to attributes, not resources, and
# counting those would inflate every stack.
_RESOURCE = re.compile(
    r"#\s+(?P<addr>\S+(?:\[[^\]]*\])?)\s+(?:will be|must be|has)\s+(?P<verb>[a-z-]+(?:\s+in-place)?)"
)

_SYMBOLS = {
    "created": "+",
    "destroyed": "-",
    "updated in-place": "~",
    "replaced": "±",
    "changed": "~",
    "read": "→",
}


def parse_plan(output):
    """Extract the change summary and the resource addresses from plan output."""
    text = _ANSI.sub("", output or "")
    add = change = destroy = 0
    resources = []
    seen = set()
    for raw in text.splitlines():
        line = raw.split("terraform: ", 1)[-1]
        m = _PLAN.search(line)
        if m:
            add, change, destroy = (int(m.group(i)) for i in (1, 2, 3))
            continue
        m = _RESOURCE.search(line)
        if m:
            addr = m.group("addr")
            sym = _SYMBOLS.get(m.group("verb").strip(), "?")
            if addr not in seen:
                seen.add(addr)
                resources.append((sym, addr))
    return {"add": add, "change": change, "destroy": destroy, "resources": resources}


def looks_like_aborted_tail(errored, all_stacks):
    """True when the errored stacks are a contiguous alphabetical tail.

    A run that plans stacks in sort order and loses its state backend partway
    fails every stack from that point on. That looks identical to "many stacks
    are broken" in a count, but it means the opposite: those stacks were never
    measured. Requires at least 3 so ordinary breakage at the end of the
    alphabet is not misread as an abort.
    """
    errored = set(errored)
    if len(errored) < 3:
        return False
    ordered = sorted(all_stacks)
    tail = ordered[len(ordered) - len(errored):]
    return set(tail) == errored


_INDEX = re.compile(r"\[[^\]]*\]")


def collapse_resources(resources, limit):
    """Render a resource list, grouping by type once it exceeds `limit`.

    Under the limit the exact addresses are what you want — you need to know
    which resource moved. Over it, an arbitrary sample actively misleads: the
    cloudflared allow-list refactor showed six destroyed carve-outs and hid the
    115 created routes that were the point. Grouping on the address with its
    for_each key stripped describes the change instead of sampling it.
    """
    if len(resources) <= limit:
        return ["    %s %s" % (sym, addr) for sym, addr in resources]

    groups = {}
    for sym, addr in resources:
        key = (sym, _INDEX.sub("", addr))
        groups[key] = groups.get(key, 0) + 1
    ordered = sorted(groups.items(), key=lambda kv: (-kv[1], kv[0][1]))
    lines = []
    for (sym, base), n in ordered[:limit]:
        lines.append("    %s %d × %s" % (sym, n, base) if n > 1
                     else "    %s %s" % (sym, base))
    if len(ordered) > limit:
        lines.append("    … %d more resource types" % (len(ordered) - limit))
    return lines


def _fmt_counts(p):
    bits = []
    if p["add"]:
        bits.append("+%d" % p["add"])
    if p["change"]:
        bits.append("~%d" % p["change"])
    if p["destroy"]:
        bits.append("-%d" % p["destroy"])
    return " ".join(bits) if bits else "no counted changes"


def build_report(entries, commit=None, pipeline_url=None,
                 max_stacks=MAX_STACKS, max_resources=MAX_RESOURCES):
    """entries: iterable of (stack, exit_code, plan_output)."""
    entries = list(entries)
    clean = [s for s, e, _ in entries if e == 0]
    errored = [s for s, e, _ in entries if e == 1]
    drifted = [(s, o) for s, e, o in entries if e == 2]
    all_stacks = [s for s, _, _ in entries]

    out = []
    head = "Terraform drift: %d differ, %d clean, %d could not be planned" % (
        len(drifted), len(clean), len(errored))
    if commit:
        head += " (planned against %s)" % commit
    out.append(head)

    if drifted:
        out.append("")
        for stack, output in drifted[:max_stacks]:
            p = parse_plan(output)
            out.append("%s — %s" % (stack, _fmt_counts(p)))
            out.extend(collapse_resources(p["resources"], max_resources))
        if len(drifted) > max_stacks:
            out.append("… and %d more stacks with drift" % (len(drifted) - max_stacks))

    if errored:
        out.append("")
        out.append("Could not be planned (state unknown, NOT drift): %d" % len(errored))
        out.append("  " + " ".join(sorted(errored)[:max_stacks]))
        if looks_like_aborted_tail(errored, all_stacks):
            out.append("  These form a contiguous alphabetical tail, which means the run")
            out.append("  most likely aborted partway rather than finding real breakage.")
            out.append("  Treat the counts above as incomplete.")

    if pipeline_url:
        out.append("")
        out.append("Full plans: %s" % pipeline_url)
    return "\n".join(out)


def slack_payload(text, channel="general"):
    if len(text) > SLACK_MAX_CHARS:
        text = text[: SLACK_MAX_CHARS - 20].rstrip() + "\n… (truncated)"
    return json.dumps({"channel": channel, "text": text})


def load_results(plans_dir):
    entries = []
    for name in sorted(os.listdir(plans_dir)):
        if not name.endswith(".exit"):
            continue
        stack = name[: -len(".exit")]
        with open(os.path.join(plans_dir, name)) as fh:
            try:
                code = int(fh.read().strip())
            except ValueError:
                code = 1
        out_path = os.path.join(plans_dir, stack + ".out")
        output = ""
        if os.path.exists(out_path):
            with open(out_path, errors="replace") as fh:
                output = fh.read()
        entries.append((stack, code, output))
    return entries


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("plans_dir")
    ap.add_argument("--commit")
    ap.add_argument("--pipeline-url")
    ap.add_argument("--slack-json")
    args = ap.parse_args()

    entries = load_results(args.plans_dir)
    report = build_report(entries, commit=args.commit, pipeline_url=args.pipeline_url)
    print(report)

    if args.slack_json:
        with open(args.slack_json, "w") as fh:
            fh.write(slack_payload(report))

    # Exit non-zero only when something was actually measured as differing;
    # an aborted run is reported but must not read as "all clear" either.
    drift = any(e == 2 for _, e, _ in entries)
    errs = any(e == 1 for _, e, _ in entries)
    return 2 if drift else (1 if errs else 0)


if __name__ == "__main__":
    sys.exit(main())
