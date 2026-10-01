#!/usr/bin/env python3
"""Checks for which processes playwright-reaper is willing to consider.

Run it by hand, from anywhere, with no dependencies:

    python3 playbooks/files/devvm/playwright-reaper-test.py

The reaper sends SIGKILL to processes owned by other users, so the predicate
that picks them is the part worth pinning down. Two kinds of browser qualify:
the shared playwright-mcp@ units in system-playwright\\x2dmcp.slice, and the
per-session browsers terminal-lobby's tl-browser starts in each user's own
tl-browser.slice. A browser a person started themselves must never qualify,
whatever its arguments look like.

The tl-browser cgroup path below was measured on the devvm on 2026-10-01 with
`systemd-run --user --scope --slice=tl-browser.slice -- cat /proc/self/cgroup`.
systemd reads the dash in a slice name as nesting, so the scope lands under
tl.slice/tl-browser.slice rather than in a slice spelled tl\\x2dbrowser.slice.
"""
import importlib.util
import os
import sys

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "playwright-reaper")

GPU = "--type=gpu-process"
PROFILE = "--user-data-dir=/tmp/playwright_chromiumdev_profile-AbC123"

MCP_CGROUP = ("0::/system.slice/system-playwright\\x2dmcp.slice/"
              "playwright-mcp@wizard.service\n")
TL_CGROUP = ("0::/user.slice/user-1000.slice/user@1000.service/tl.slice/"
             "tl-browser.slice/tl-browser-s12-405359.scope\n")
TL_ESCAPED_CGROUP = ("0::/user.slice/user-1000.slice/user@1000.service/"
                     "tl\\x2dbrowser.slice/tl\\x2dbrowser\\x2ds12.scope\n")
OWN_CGROUP = ("0::/user.slice/user-1000.slice/user@1000.service/app.slice/"
              "app-google\\x2dchrome-1234.scope\n")
PANE_CGROUP = "0::/user.slice/user-1000.slice/session-5.scope\n"


def load():
    mod = importlib.util.module_from_spec(
        importlib.util.spec_from_loader("playwright_reaper", None))
    with open(SCRIPT) as fh:
        exec(compile(fh.read(), SCRIPT, "exec"), mod.__dict__)
    return mod


def argv(*args):
    return "\0".join(("/opt/google/chrome/chrome",) + args) + "\0"


def main():
    m = load()
    ok = m.eligible
    checks = 0

    assert ok(argv(GPU, PROFILE), MCP_CGROUP), \
        "a shared playwright-mcp gpu-process qualifies"
    checks += 1
    assert ok(argv(GPU, PROFILE), TL_CGROUP), \
        "a tl-browser gpu-process in the user's tl-browser.slice qualifies"
    checks += 1
    assert ok(argv(GPU, PROFILE), TL_ESCAPED_CGROUP), \
        "so does one in a slice spelled tl\\x2dbrowser.slice"
    checks += 1
    assert not ok(argv(GPU, PROFILE), OWN_CGROUP), \
        "a person's own Chrome is never considered, even with these args"
    checks += 1
    assert not ok(argv(GPU, PROFILE), PANE_CGROUP), \
        "nor is a playwright browser started straight from a pane"
    checks += 1
    assert not ok(argv("--type=renderer", PROFILE), TL_CGROUP), \
        "a renderer in the tl-browser slice is left alone"
    checks += 1
    assert not ok(argv(GPU, "--user-data-dir=/home/x/.config/chrome"),
                  TL_CGROUP), \
        "a gpu-process without a playwright profile is left alone"
    checks += 1
    assert not ok(argv(GPU, PROFILE),
                  "0::/system.slice/tl-browser-notes.service\n"), \
        "a unit whose name merely starts with tl-browser does not qualify"
    checks += 1

    print("ok, %d checks" % checks)


if __name__ == "__main__":
    sys.exit(main())
