"""How much of a pytest suite runs code no other test runs.

Reads a coverage.py data file recorded with per-test contexts and branch
coverage, and reports, per test function (parametrized cases merged):

- functions that execute no branch arc another function doesn't,
- groups of functions whose footprints are identical,
- the fewest functions that still execute every arc the suite executes
  (lazy greedy set cover).

Coverage sees which code ran, not what a test asserted, so every number here
is an upper bound on redundancy: a list to review, never a list to delete.

Record the data without touching the project's virtualenv:

    python -m pip install --no-deps --target /tmp/covlib coverage pytest-cov
    PYTHONPATH=/tmp/covlib python -m pytest -q -p no:cacheprovider \\
        --cov=<package> --cov-branch --cov-context=test --cov-report=

(add pytest-xdist and execnet to /tmp/covlib and `-p xdist -n 8` for a slow
suite; pytest-cov keeps per-test contexts across workers). Then:

    python3 redundancy.py .coverage <label>

which prints a summary and writes <data>.summary.json and <data>.detail.json.
"""

import collections
import heapq
import json
import sqlite3
import sys


def footprints(db_path: str) -> dict[str, set[int]]:
    """Arc ids executed by each test node id, setup + call + teardown."""
    db = sqlite3.connect(db_path)
    contexts = dict(db.execute("select id, context from context"))
    arc_ids: dict[tuple[int, int, int], int] = {}
    tests: dict[str, set[int]] = collections.defaultdict(set)
    for file_id, ctx_id, a, b in db.execute("select file_id, context_id, fromno, tono from arc"):
        ctx = contexts[ctx_id]
        if not ctx:
            continue  # import-time code, not attributable to a test
        node = ctx.rsplit("|", 1)[0]
        tests[node].add(arc_ids.setdefault((file_id, a, b), len(arc_ids)))
    return tests


def greedy_cover(sets: dict[str, set[int]]) -> list[str]:
    universe = set().union(*sets.values())
    covered: set[int] = set()
    heap = [(-len(s), name) for name, s in sets.items()]
    heapq.heapify(heap)
    chosen = []
    while len(covered) < len(universe) and heap:
        _, name = heapq.heappop(heap)
        gain = len(sets[name] - covered)
        if gain == 0:
            continue
        if heap and gain < -heap[0][0]:
            heapq.heappush(heap, (-gain, name))
            continue
        chosen.append(name)
        covered |= sets[name]
    return chosen


def main(db_path: str, label: str) -> None:
    tests = footprints(db_path)
    funcs: dict[str, set[int]] = collections.defaultdict(set)
    for node, arcs in tests.items():
        funcs[node.split("[", 1)[0]] |= arcs

    runs_arc = collections.Counter()
    for arcs in funcs.values():
        runs_arc.update(arcs)
    no_unique = sorted(f for f, arcs in funcs.items() if all(runs_arc[a] > 1 for a in arcs))

    by_footprint = collections.defaultdict(list)
    for f in sorted(funcs):
        by_footprint[frozenset(funcs[f])].append(f)
    groups = sorted((g for g in by_footprint.values() if len(g) > 1), key=len, reverse=True)
    cover = greedy_cover(funcs)

    def file_of(f: str) -> str:
        return f.split("::", 1)[0]

    per_file = collections.defaultdict(lambda: {"functions": 0, "no_unique": 0, "twin": 0})
    for f in funcs:
        per_file[file_of(f)]["functions"] += 1
    for f in no_unique:
        per_file[file_of(f)]["no_unique"] += 1
    for g in groups:
        for f in g[1:]:
            per_file[file_of(f)]["twin"] += 1

    summary = {
        "label": label,
        "test_items": len(tests),
        "functions": len(funcs),
        "arcs": len(runs_arc),
        "functions_with_no_unique_arc": len(no_unique),
        "identical_groups": len(groups),
        "functions_with_a_twin": sum(len(g) - 1 for g in groups),
        "identical_groups_in_one_file": sum(1 for g in groups if len({file_of(f) for f in g}) == 1),
        "fewest_functions_covering_every_arc": len(cover),
        "files_by_twins": sorted(per_file.items(), key=lambda kv: kv[1]["twin"], reverse=True)[:15],
    }
    with open(f"{db_path}.summary.json", "w") as fh:
        json.dump(summary, fh, indent=1)
    with open(f"{db_path}.detail.json", "w") as fh:
        json.dump({"identical_groups": groups, "no_unique": no_unique, "cover": cover}, fh, indent=1)
    print(json.dumps({k: v for k, v in summary.items() if k != "files_by_twins"}, indent=1))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
