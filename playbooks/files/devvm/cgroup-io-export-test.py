#!/usr/bin/env python3
"""Checks for cgroup-io-export's departed-cgroup folding.

Run it by hand, from anywhere, with no dependencies:

    python3 playbooks/files/devvm/cgroup-io-export-test.py

The exporter accumulates per-cgroup IO across cgroup lifetimes, so it keeps a
path in its state after the cgroup itself is gone. Left alone that grows for
ever: measured on the devvm 2026-09-15, 131 known paths against 77 live, the
extra ones being docker.slice/docker-<64 hex>.scope, one per container ever
run. Folding those into a per-parent bucket keeps the accumulated bytes while
bounding the series count, and these checks pin that behaviour down.
"""
import importlib.util
import os
import sys

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "cgroup-io-export")


def load():
    mod = importlib.util.module_from_spec(
        importlib.util.spec_from_loader("cgroup_io_export", None))
    with open(SCRIPT) as fh:
        exec(compile(fh.read(), SCRIPT, "exec"), mod.__dict__)
    return mod


def counters(rbytes, wbytes, rios, wios):
    return {"rbytes": rbytes, "wbytes": wbytes, "rios": rios, "wios": wios}


def main():
    m = load()
    retain = m.RETAIN_DEAD_SECONDS
    gone = "docker.slice/docker-" + "a" * 64 + ".scope"
    also_gone = "docker.slice/docker-" + "b" * 64 + ".scope"
    alive = "user.slice/user-1000.slice"

    total = {gone: counters(10, 20, 1, 2), alive: counters(1, 1, 1, 1)}
    seen = {alive: {}}
    seen_at = {alive: 100.0}

    m.fold_departed(total, seen, seen_at, 100.0)
    assert gone in total, "a cgroup missed for the first time must survive"
    assert seen_at[gone] == 100.0, "its retention clock must start"

    m.fold_departed(total, seen, seen_at, 100.0 + retain)
    assert gone in total, "it must survive the whole retention window"

    m.fold_departed(total, seen, seen_at, 100.0 + retain + 1)
    assert gone not in total, "past the window the path must go"
    assert gone not in seen_at, "and its clock with it"
    assert total["docker.slice/(departed)"] == counters(10, 20, 1, 2), \
        "its counters must land in the parent's bucket intact"
    assert total[alive] == counters(1, 1, 1, 1), "a live cgroup is untouched"

    total[also_gone] = counters(5, 7, 3, 4)
    m.fold_departed(total, seen, seen_at, 200.0)
    m.fold_departed(total, seen, seen_at, 200.0 + retain + 1)
    assert total["docker.slice/(departed)"] == counters(15, 27, 4, 6), \
        "a second departure adds to the same bucket"
    assert [k for k in total if "docker" in k] == ["docker.slice/(departed)"], \
        "one bucket per parent, however many containers came and went"

    before = dict(total["docker.slice/(departed)"])
    m.fold_departed(total, seen, seen_at, 1e9)
    assert total["docker.slice/(departed)"] == before, \
        "the bucket must not fold into itself"
    assert "docker.slice/(departed)/(departed)" not in total

    total["strays.scope"] = counters(3, 4, 5, 6)
    m.fold_departed(total, seen, seen_at, 1e9)
    m.fold_departed(total, seen, seen_at, 1e9 + retain + 1)
    assert total["(departed)"] == counters(3, 4, 5, 6), \
        "a top-level cgroup folds to the root bucket"

    assert set(seen_at) == {alive}, \
        "seen_at holds live cgroups plus pending folds, nothing else"

    print("ok, 8 checks")


if __name__ == "__main__":
    sys.exit(main())
