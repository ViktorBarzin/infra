#!/usr/bin/env python3
"""code-quality — measure whether a repo is getting more maintainable, honestly.

Driven by `homelab quality`. The point of a repeat run is the TREND, not the
number: one run says a repo has three invisible coupling pairs, two say whether
last month's work removed them.

What this deliberately does NOT measure, and why, is in detectors.json under
"banned". The short version: summed cyclomatic complexity, the maintainability
index and the SQALE debt ratio were all measured against line count on this
monorepo on 2026-09-06 and all three turned out to be line count wearing a hat.
Summed CCN reported a false +6,198 regression on a refactor that improved the
code. They are refused by construction here rather than merely left out.

Everything in the core needs nothing but git, so it runs on any repo in the
workspace with no install. Detectors that need a tool are optional and simply
report themselves absent.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
DETECTORS = HERE / "detectors.json"
HISTORY = HERE / "history"
PUSHGATEWAY = os.environ.get("TL_PUSHGATEWAY", "http://10.0.20.100:30091")
JOB = "code-quality"

SOURCE_EXT = {".go", ".ts", ".tsx", ".js", ".jsx", ".py", ".rs", ".svelte",
              ".sh", ".css", ".tf", ".vim"}
TEST_RE = re.compile(r"(^|/)(test|tests)/|_test\.go$|\.test\.[jt]sx?$|(^|/)test_[^/]+\.py$")


# --- shelling out ---------------------------------------------------------

def git(repo: pathlib.Path, *args: str, check: bool = True) -> str:
    """Run git in repo and return stdout. Returns '' on failure when check=False."""
    try:
        out = subprocess.run(["git", "-C", str(repo), *args],
                             capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return ""
    if out.returncode != 0:
        if check:
            raise RuntimeError(f"git {' '.join(args)} failed in {repo}: {out.stderr.strip()}")
        return ""
    return out.stdout


def is_repo(p: pathlib.Path) -> bool:
    return (p / ".git").exists()


def repo_name(repo: pathlib.Path) -> str:
    """Identity for the series, taken from the remote rather than the directory.

    A worktree or a differently-named clone is the SAME repo and its runs have
    to land in the same series. Measured: checking out 62d1ae6 into a temp
    worktree produced a snapshot named after the temp directory, so `diff` had
    nothing to pair it with and the before-and-after comparison silently did
    not exist.
    """
    url = git(repo, "config", "--get", "remote.origin.url", check=False).strip()
    if url:
        return re.sub(r"\.git$", "", url.rstrip("/").rsplit("/", 1)[-1])
    top = git(repo, "rev-parse", "--show-toplevel", check=False).strip()
    return pathlib.Path(top).name if top else repo.name


# --- pure helpers, the testable core --------------------------------------

def classify(path: str) -> str:
    """prod, test or other. `other` is everything that is not source we count."""
    if pathlib.PurePath(path).suffix not in SOURCE_EXT:
        return "other"
    return "test" if TEST_RE.search(path) else "prod"


def coupling_degree(a_count: int, b_count: int, both: int) -> float:
    """Co-change degree, max-denominator convention.

    Max rather than min on purpose: min flatters a rarely-touched file that
    happens to move whenever its busy partner does. Measured both ways on
    terminal-lobby's telemetry pair: 0.50 max, 0.60 min.
    """
    d = max(a_count, b_count)
    return 0.0 if d == 0 else both / d


# .ts and .tsx are one language, and so are .js and .jsx. Comparing suffixes
# directly called a .tsx/.ts pair cross-language, which is the kind of wrong
# that makes a whole detector untrustworthy.
LANG = {".go": "go", ".ts": "ts", ".tsx": "ts", ".js": "js", ".jsx": "js",
        ".py": "py", ".rs": "rs", ".svelte": "svelte", ".sh": "sh",
        ".css": "css", ".tf": "tf", ".vim": "vim"}


def language(path: str) -> str:
    return LANG.get(pathlib.PurePath(path).suffix, "other")


def cross_language(a: str, b: str) -> bool:
    return language(a) != language(b)


def test_partner(a: str, b: str) -> bool:
    """True when these are a source file and its own test, in either order.

    A file and its test SHOULD move together; that is the system working. Left
    in, this was the top-ranked pair on the first real run (pushsender.go and
    pushsender_test.go at 0.82) and it would have buried the finding that
    matters.

    One of the two must actually BE a test. Without that condition the stems of
    frontend-v2/public/sw.js and frontend/sw.js both reduce to "sw", so the pair
    of byte-identical copies this detector exists to find excluded itself and
    the repo scored a clean zero.
    """
    if classify(a) == classify(b):
        return False

    def stem(p: str) -> str:
        s = pathlib.PurePath(p).name
        for suf in (".test.tsx", ".test.ts", ".test.jsx", ".test.js", "_test.go"):
            if s.endswith(suf):
                s = s[: -len(suf)]
                break
        else:
            s = pathlib.PurePath(s).stem
            if s.startswith("test_"):
                s = s[5:]
        # A test may carry a qualifier naming the case it covers, as in
        # watchmode.auto.test.ts against store/watchmode.ts. Compare the first
        # dot-segment so those still pair up.
        return s.split(".")[0]
    return stem(a) == stem(b)


def same_go_package(a: str, b: str) -> bool:
    """Two .go files in one directory are one compilation unit.

    They share a package scope and therefore never import each other, so every
    such pair looks invisible by construction. skills-api/main.go and
    skills-api/privop.go ranked top on a real run for exactly this reason.
    """
    return (a.endswith(".go") and b.endswith(".go")
            and str(pathlib.PurePath(a).parent) == str(pathlib.PurePath(b).parent))


def concentration(touch_counts: list[int], top_n: int) -> float:
    """Share of all file-touches landing in the top N files, as a percent."""
    total = sum(touch_counts)
    if total == 0:
        return 0.0
    return 100.0 * sum(sorted(touch_counts, reverse=True)[:top_n]) / total


def fingerprint(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()[:12]


# --- detectors ------------------------------------------------------------

def measure_sloc(repo: pathlib.Path) -> dict:
    """The CONTROL series. Not a quality metric; the bar every other one must clear."""
    counts = {"prod": 0, "test": 0}
    files = [f for f in git(repo, "ls-files", "-z").split("\0") if f]
    for f in files:
        kind = classify(f)
        if kind == "other":
            continue
        try:
            n = sum(1 for _ in (repo / f).open("rb"))
        except OSError:
            continue
        counts[kind] += n
    return counts


def commit_files(repo: pathlib.Path, days: int, max_files: int = 20) -> list[list[str]]:
    """File lists per commit in the window, skipping sweeping commits.

    A commit touching 200 files creates 19,900 pairs and every one of them is
    noise, so wide commits are excluded from coupling rather than allowed to
    dominate it. max_files is the knob; the count that was skipped is reported.
    """
    raw = git(repo, "log", f"--since={days}.days", "--first-parent",
              "--name-only", "--format=%x00%H", check=False)
    out, skipped = [], 0
    for block in raw.split("\0"):
        lines = [l for l in block.splitlines() if l.strip()]
        if len(lines) < 2:
            continue
        files = [f for f in lines[1:] if classify(f) != "other"]
        if not files:
            continue
        if len(files) > max_files:
            skipped += 1
            continue
        out.append(sorted(set(files)))
    return out, skipped


def measure_coupling(repo: pathlib.Path, cfg: dict) -> dict:
    """Files that change together while referencing each other in no traceable way.

    The one detector that earned its place on evidence rather than tradition.
    A pair is "invisible" when neither file's text mentions the other's stem, so
    no import graph, type checker or linter could ever pair them. That is
    exactly the shape of a contract kept in sync by a comment.
    """
    days = cfg["windows"]["churn_days"]
    d = next(x for x in cfg["detectors"] if x["id"] == "invisible_coupling")
    commits, skipped = commit_files(repo, days)

    touches = collections.Counter()
    pairs = collections.Counter()
    for files in commits:
        for f in files:
            touches[f] += 1
        for i, a in enumerate(files):
            for b in files[i + 1:]:
                pairs[(a, b)] += 1

    found = []
    for (a, b), both in pairs.items():
        if both < d["min_cochanges"]:
            continue
        deg = coupling_degree(touches[a], touches[b], both)
        if deg < d["min_degree"]:
            continue
        if not (repo / a).exists() or not (repo / b).exists():
            continue
        if test_partner(a, b) or same_go_package(a, b):
            continue
        # Two tests of the same feature co-change for the obvious reason and
        # tell you nothing about a hidden contract, so only pairs with at least
        # one production file count.
        if classify(a) == "test" and classify(b) == "test":
            continue
        if references_each_other(repo, a, b):
            continue
        found.append({
            "a": a, "b": b, "cochanges": both, "degree": round(deg, 3),
            "cross_language": cross_language(a, b),
            "identical": files_identical(repo, a, b),
        })
    found.sort(key=lambda x: (-x["degree"], -x["cochanges"]))
    return {
        "pairs": found[:25],
        "pair_count": len(found),
        "max_degree": round(max((f["degree"] for f in found), default=0.0), 3),
        "identical_pairs": sum(1 for f in found if f["identical"]),
        "wide_commits_skipped": skipped,
        "commits_considered": len(commits),
    }


IMPORT_RE = re.compile(
    r"^\s*(?:import\b|from\s|export\s+.*\bfrom\s|require\s*\(|#include\b|use\s|source\s|\.\s)",
    re.I)


def references_each_other(repo: pathlib.Path, a: str, b: str) -> bool:
    """True when one file IMPORTS the other, so a tool can already see the link.

    The check is deliberately restricted to import-shaped lines. An earlier
    version searched the whole file and therefore counted a comment as a
    reference, which excluded the single best example this detector has:
    frontend-v2/src/telemetry/track.ts:16 says "TlEvent mirrors the Go catalog
    in telemetry/events.go" and nothing else connects them. A contract kept in
    sync by a sentence in a comment is exactly what we are hunting, so a comment
    must not count as a link.
    """
    a_stem, b_stem = pathlib.PurePath(a).stem, pathlib.PurePath(b).stem
    for src, needle in ((a, b_stem), (b, a_stem)):
        if len(needle) < 3:
            continue
        try:
            text = (repo / src).read_text(errors="ignore")
        except OSError:
            continue
        for line in text.splitlines():
            if IMPORT_RE.match(line) and needle in line:
                return True
    return False


def files_identical(repo: pathlib.Path, a: str, b: str) -> bool:
    try:
        return (repo / a).read_bytes() == (repo / b).read_bytes()
    except OSError:
        return False


def measure_concentration(repo: pathlib.Path, cfg: dict) -> dict:
    days = cfg["windows"]["churn_days"]
    d = next(x for x in cfg["detectors"] if x["id"] == "change_concentration")
    commits, _ = commit_files(repo, days, max_files=10_000)
    touches = collections.Counter(f for files in commits for f in files)
    top = touches.most_common(d["top_n"])
    return {
        "ratio_pct": round(concentration(list(touches.values()), d["top_n"]), 1),
        "files_touched": len(touches),
        "top": [{"file": f, "touches": n} for f, n in top],
    }


def measure_bug_magnets(repo: pathlib.Path, cfg: dict) -> dict:
    days = cfg["windows"]["defect_days"]
    d = next(x for x in cfg["detectors"] if x["id"] == "bug_magnets")
    pat = re.compile(d["fix_subject_pattern"], re.I)
    raw = git(repo, "log", f"--since={days}.days", "--first-parent",
              "--name-only", "--format=%x00%s", check=False)
    fixes = collections.Counter()
    for block in raw.split("\0"):
        lines = [l for l in block.splitlines() if l.strip()]
        if len(lines) < 2 or not pat.search(lines[0]):
            continue
        for f in lines[1:]:
            if classify(f) == "prod":
                fixes[f] += 1
    magnets = [{"file": f, "fixes": n} for f, n in fixes.most_common()
               if n >= d["min_fixes"]]
    return {"count": len(magnets), "files": magnets[:15]}


def measure_rework(repo: pathlib.Path, cfg: dict) -> dict:
    """Reverts, plus fixes landing within the window of the commit they fix.

    An outcome rather than a proxy: you cannot improve it by rewriting a
    function. Reported with its denominator, because commit density moving is
    the obvious way for the percentage to move without anything getting worse.
    """
    d = next(x for x in cfg["detectors"] if x["id"] == "rework_rate")
    days = cfg["windows"]["churn_days"]
    window = d["window_hours"] * 3600
    raw = git(repo, "log", f"--since={days}.days", "--first-parent", "--name-only",
              "--format=%x00%ct%x1f%s", check=False)

    commits = []
    for block in raw.split("\0"):
        lines = [l for l in block.splitlines() if l.strip()]
        if not lines or lines[0].count("\x1f") != 1:
            continue
        ts, subj = lines[0].split("\x1f")
        files = {f for f in lines[1:] if classify(f) != "other"}
        commits.append((int(ts), subj, files))
    if not commits:
        return {"pct": 0.0, "commits": 0, "reverts": 0, "quick_fixes": 0}

    reverts = sum(1 for _, s, _ in commits if s.lower().startswith("revert"))
    # A fix counts as rework only when it touches a file that a DIFFERENT commit
    # changed within the window. The first version asked whether any commit at
    # all preceded it, which on a repo doing 756 commits in 90 days is true for
    # nearly every fix: it measured commit density and reported 22.5%.
    quick = 0
    for ts, subj, files in commits:
        if not re.match(r"^fix", subj, re.I) or not files:
            continue
        if any(0 < ts - pts <= window and files & pfiles
               for pts, _, pfiles in commits):
            quick += 1
    n = len(commits)
    return {
        "pct": round(100.0 * (reverts + quick) / n, 1),
        "commits": n, "reverts": reverts, "quick_fixes": quick,
    }


def measure_suite(repo: pathlib.Path) -> dict:
    """Optional. Green, red or hung, per Go module and for the frontend."""
    results = {}
    for mod in sorted(p.parent for p in repo.glob("*/go.mod")):
        name = mod.relative_to(repo).as_posix()
        try:
            r = subprocess.run(["go", "test", "./..."], cwd=mod, capture_output=True,
                               text=True, timeout=300)
            results[name] = "pass" if r.returncode == 0 else "fail"
        except subprocess.TimeoutExpired:
            results[name] = "timeout"
        except FileNotFoundError:
            return {"available": False}
    return {"available": bool(results), "modules": results,
            "all_green": all(v == "pass" for v in results.values()) if results else None}


def measure_optional_tool(repo: pathlib.Path, tool: str) -> dict:
    if not shutil.which(tool):
        return {"available": False, "note": f"{tool} not installed; detector skipped"}
    return {"available": True, "note": "present but not yet wired; see open questions"}


# --- snapshot -------------------------------------------------------------

def collect(repo: pathlib.Path, cfg: dict, with_suite: bool) -> dict:
    snap = {
        "repo": repo_name(repo),
        "head": git(repo, "rev-parse", "HEAD", check=False).strip()[:12],
        "detectors_fingerprint": fingerprint(DETECTORS),
        "sloc": measure_sloc(repo),
        "invisible_coupling": measure_coupling(repo, cfg),
        "change_concentration": measure_concentration(repo, cfg),
        "bug_magnets": measure_bug_magnets(repo, cfg),
        "rework": measure_rework(repo, cfg),
        "duplication": measure_optional_tool(repo, "jscpd"),
        "layer_violations": measure_optional_tool(repo, "depcruise"),
    }
    if with_suite:
        snap["suite"] = measure_suite(repo)
    return snap


def series(snap: dict) -> dict:
    """Flat metric name -> value, for Prometheus and for diff."""
    s = {
        "sloc_prod": snap["sloc"]["prod"],
        "sloc_test": snap["sloc"]["test"],
        "invisible_coupling_pairs": snap["invisible_coupling"]["pair_count"],
        "max_coupling_degree": snap["invisible_coupling"]["max_degree"],
        "identical_file_pairs": snap["invisible_coupling"]["identical_pairs"],
        "change_concentration_pct": snap["change_concentration"]["ratio_pct"],
        "bug_magnet_files": snap["bug_magnets"]["count"],
        "rework_rate_pct": snap["rework"]["pct"],
        "commits_in_window": snap["rework"]["commits"],
    }
    if snap.get("suite", {}).get("available"):
        s["suite_all_green"] = 1 if snap["suite"]["all_green"] else 0
    return s


# Metrics whose movement is meaningless unless sloc held still. `diff` says so
# rather than letting a reader infer improvement from a shrinking codebase.
SIZE_SHAPED = {"invisible_coupling_pairs", "bug_magnet_files", "change_concentration_pct"}


def diff_series(old: dict, new: dict) -> list[dict]:
    rows = []
    sloc_old = old.get("sloc_prod", 0) + old.get("sloc_test", 0)
    sloc_new = new.get("sloc_prod", 0) + new.get("sloc_test", 0)
    sloc_move = 0.0 if sloc_old == 0 else 100.0 * (sloc_new - sloc_old) / sloc_old
    for k in sorted(set(old) | set(new)):
        o, n = old.get(k), new.get(k)
        if o is None or n is None:
            rows.append({"metric": k, "old": o, "new": n, "note": "new or dropped series"})
            continue
        delta = n - o
        note = ""
        # Only a move in the SAME direction as size is suspect. A count falling
        # while the codebase grew is the opposite of a size artifact, and
        # flagging it told the reader not to believe a real improvement.
        if (k in SIZE_SHAPED and abs(sloc_move) > 2 and delta != 0
                and (delta > 0) == (sloc_move > 0)):
            note = f"sloc moved {sloc_move:+.1f}%, so read this as size-shaped"
        elif k in SIZE_SHAPED and abs(sloc_move) > 2 and delta != 0:
            note = f"moved against sloc ({sloc_move:+.1f}%), so not size-shaped"
        rows.append({"metric": k, "old": o, "new": n, "delta": round(delta, 3), "note": note})
    return rows


# --- history and push -----------------------------------------------------

def snapshots() -> list[pathlib.Path]:
    return sorted(HISTORY.glob("*.json"))


def record(snap: dict, stamp: str) -> pathlib.Path:
    HISTORY.mkdir(parents=True, exist_ok=True)
    p = HISTORY / f"{snap['repo']}-{stamp}.json"
    snap["recorded_at"] = stamp
    p.write_text(json.dumps(snap, indent=2, sort_keys=True) + "\n")
    return p


def push(snap: dict) -> str:
    body = []
    for k, v in series(snap).items():
        body.append(f"# TYPE code_quality_{k} gauge")
        body.append(f'code_quality_{k}{{repo="{snap["repo"]}"}} {v}')
    body.append("# TYPE code_quality_detectors_info gauge")
    body.append(f'code_quality_detectors_info{{repo="{snap["repo"]}",'
                f'fingerprint="{snap["detectors_fingerprint"]}"}} 1')
    payload = ("\n".join(body) + "\n").encode()
    url = f"{PUSHGATEWAY}/metrics/job/{JOB}/repo/{snap['repo']}"
    try:
        req = urllib.request.Request(url, data=payload, method="POST")
        with urllib.request.urlopen(req, timeout=10) as r:
            return f"pushed ({r.status})"
    except (urllib.error.URLError, OSError) as e:
        return f"push skipped: {e}"


# --- commands -------------------------------------------------------------

def resolve_repos(args) -> list[pathlib.Path]:
    if args.repo:
        return [pathlib.Path(r).resolve() for r in args.repo]
    here = pathlib.Path.cwd()
    for p in [here, *here.parents]:
        if is_repo(p):
            return [p]
    raise SystemExit("not inside a git repo; pass a path or run from one")


def cmd_run(args) -> int:
    cfg = json.loads(DETECTORS.read_text())
    stamp = args.stamp or subprocess.run(
        ["date", "-u", "+%Y-%m-%dT%H%M%S"], capture_output=True, text=True
    ).stdout.strip()
    for repo in resolve_repos(args):
        if not is_repo(repo):
            print(f"{repo}: not a git repo, skipped")
            continue
        snap = collect(repo, cfg, with_suite=args.with_suite)
        path = record(snap, stamp)
        status = push(snap) if not args.no_push else "push disabled"
        print(f"\n=== {snap['repo']} @ {snap['head']} ===")
        for k, v in series(snap).items():
            print(f"  {k:32} {v}")
        ic = snap["invisible_coupling"]
        if ic["pairs"]:
            print(f"\n  invisible coupling, top {min(5, len(ic['pairs']))}:")
            for p in ic["pairs"][:5]:
                tag = " IDENTICAL FILES" if p["identical"] else (
                    " cross-language" if p["cross_language"] else "")
                print(f"    {p['degree']:.2f}  {p['a']}  <->  {p['b']}"
                      f"  ({p['cochanges']} co-changes){tag}")
        prev = [s for s in snapshots()
                if s.name.startswith(snap["repo"] + "-") and s != path]
        if prev:
            old = json.loads(prev[-1].read_text())
            if old.get("detectors_fingerprint") != snap["detectors_fingerprint"]:
                print("\n  detectors changed since the last run; not comparing")
            else:
                print(f"\n  vs {old['recorded_at']}:")
                for r in diff_series(series(old), series(snap)):
                    if r.get("delta"):
                        note = f"   [{r['note']}]" if r["note"] else ""
                        print(f"    {r['metric']:32} {r['old']} -> {r['new']}"
                              f"  ({r['delta']:+}){note}")
        print(f"\n  recorded {path.name}, {status}")
    return 0


def cmd_history(args) -> int:
    for p in snapshots():
        d = json.loads(p.read_text())
        print(f"{d.get('recorded_at','?'):22} {d.get('repo','?'):22} "
              f"{d.get('head','?'):14} {p.name}")
    return 0


def cmd_diff(args) -> int:
    snaps = snapshots()
    if args.repo:
        want = pathlib.Path(args.repo[0]).resolve().name
        snaps = [s for s in snaps if json.loads(s.read_text()).get("repo") == want]
    if len(snaps) < 2:
        print("need two runs to diff")
        return 1
    old, new = json.loads(snaps[-2].read_text()), json.loads(snaps[-1].read_text())
    if old["detectors_fingerprint"] != new["detectors_fingerprint"]:
        print("detectors.json changed between these runs; the comparison would be "
              "misleading, so it is refused. Re-run the older commit to compare.")
        return 1
    print(f"{old['recorded_at']}  ->  {new['recorded_at']}   ({new['repo']})\n")
    print(f"{'metric':34}{'before':>12}{'after':>12}{'delta':>10}")
    for r in diff_series(series(old), series(new)):
        d = r.get("delta", "")
        print(f"{r['metric']:34}{str(r['old']):>12}{str(r['new']):>12}{str(d):>10}"
              + (f"   {r['note']}" if r.get("note") else ""))
    return 0


def cmd_gate(args) -> int:
    """Exit non-zero when a gated metric regressed. For CI."""
    snaps = snapshots()
    if args.repo:
        want = pathlib.Path(args.repo[0]).resolve().name
        snaps = [s for s in snaps if json.loads(s.read_text()).get("repo") == want]
    if len(snaps) < 2:
        print("gate: need two runs; nothing to compare")
        return 0
    old, new = json.loads(snaps[-2].read_text()), json.loads(snaps[-1].read_text())
    if old["detectors_fingerprint"] != new["detectors_fingerprint"]:
        print("gate: detectors changed, not comparing")
        return 0
    bad = []
    o, n = series(old), series(new)
    if n["invisible_coupling_pairs"] > o["invisible_coupling_pairs"]:
        bad.append(f"invisible coupling pairs {o['invisible_coupling_pairs']} -> "
                   f"{n['invisible_coupling_pairs']}")
    if n["identical_file_pairs"] > o["identical_file_pairs"]:
        bad.append(f"identical file pairs {o['identical_file_pairs']} -> "
                   f"{n['identical_file_pairs']}")
    if n.get("suite_all_green", 1) < o.get("suite_all_green", 1):
        bad.append("test suite went red")
    for b in bad:
        print(f"gate FAILED: {b}")
    return 1 if bad else 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="quality", description=__doc__)
    sub = ap.add_subparsers(dest="cmd")
    for name in ("run", "diff", "history", "gate"):
        p = sub.add_parser(name)
        p.add_argument("repo", nargs="*")
        if name == "run":
            p.add_argument("--with-suite", action="store_true",
                           help="run test suites too; minutes rather than seconds")
            p.add_argument("--no-push", action="store_true")
            p.add_argument("--stamp", help="override the timestamp, for tests")
    args = ap.parse_args(argv)
    return {"run": cmd_run, "diff": cmd_diff, "history": cmd_history,
            "gate": cmd_gate}.get(args.cmd or "run", cmd_run)(args)


if __name__ == "__main__":
    sys.exit(main())
