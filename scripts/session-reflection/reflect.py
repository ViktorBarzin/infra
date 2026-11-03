#!/usr/bin/env python3
"""Run the session-reflection detectors, record the result, and diff it.

The point of a repeat run is the TREND, not the absolute number. A single run
answers "how often do we reach past our own tooling"; two runs answer "is the
last fix working". So every run writes a metrics snapshot into history/ (which
is committed, so the before/after is a git diff), pushes the same numbers to
Prometheus for a trend line, and prints the delta against the previous run.

  reflect.py run [--no-push] [--no-memory] [--json] [--work-dir D]
  reflect.py diff [--from A] [--to B]
  reflect.py history [--json]

The deterministic half is cheap: no model tokens, a couple of minutes over the
whole corpus. The expensive agent-judging half is a separate, on-demand
workflow — see workflow.js in this directory and the README.

Comparability rule: a number here must mean the same thing next time. When you
change what a detector counts, that is a NEW key, not a redefinition of an old
one — otherwise the trend silently lies. Adding patterns to patterns.json does
change the counts, which is why every snapshot records patterns_fingerprint;
`diff` warns when two runs were measured with different patterns.
"""
import argparse
import datetime
import hashlib
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
HISTORY = os.path.join(HERE, "history")

# Pushgateway is reachable from the devvm on the NodePort; several nodes are
# tried because any one of them can be draining. The in-cluster DNS name that
# other pushers use does not resolve from here.
PUSH_NODES = ["10.0.20.100", "10.0.20.101", "10.0.20.102", "10.0.20.103"]
PUSH_PORT = 30091
PUSH_JOB = "session-reflection"

# Flat gauges worth a trend line. Nested maps (d2_by_verb) are pushed as a
# labelled series instead.
SCALARS = [
    "turns", "sessions_real", "d1_corrections", "d2_anomalies", "d2_redline",
    "d3_turns_with_recall", "d4_wins",
]


def run_detectors(work_dir: str) -> dict:
    """Run the three scripts in work_dir and return the metrics they produce."""
    os.makedirs(work_dir, exist_ok=True)
    for script in ("inventory.py", "digest.py", "detect.py"):
        r = subprocess.run([sys.executable, os.path.join(HERE, script)],
                           cwd=work_dir, capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit(f"{script} failed:\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}")
    path = os.path.join(work_dir, "metrics.json")
    if not os.path.exists(path):
        raise SystemExit(f"detect.py produced no metrics.json in {work_dir}")
    return json.load(open(path))


def patterns_fingerprint() -> str:
    """Short hash of patterns.json, so a diff can say the ruler changed."""
    return hashlib.sha256(
        open(os.path.join(HERE, "patterns.json"), "rb").read()).hexdigest()[:12]


def snapshots() -> list:
    """Every recorded run, oldest first."""
    if not os.path.isdir(HISTORY):
        return []
    out = []
    for name in sorted(os.listdir(HISTORY)):
        if name.endswith(".json"):
            out.append(json.load(open(os.path.join(HISTORY, name))))
    return out


def record(metrics: dict, now: str) -> str:
    os.makedirs(HISTORY, exist_ok=True)
    snap = dict(metrics)
    snap["recorded_at"] = now
    snap["patterns_fingerprint"] = patterns_fingerprint()
    path = os.path.join(HISTORY, f"{now[:19].replace(':', '')}.json")
    json.dump(snap, open(path, "w"), indent=1, sort_keys=True)
    return path


def push(metrics: dict) -> str:
    """Send the scalars to Pushgateway. Best-effort: a run is still valid if
    the push fails, so this reports rather than raises."""
    lines = []
    for k in SCALARS:
        v = metrics.get(k)
        if isinstance(v, (int, float)):
            lines.append(f"# TYPE session_reflection_{k} gauge")
            lines.append(f"session_reflection_{k} {v}")
    for verb, n in (metrics.get("d2_by_verb") or {}).items():
        safe = verb.replace('"', "").replace("\\", "")
        lines.append(f'session_reflection_d2_by_verb{{verb="{safe}"}} {n}')
    body = ("\n".join(lines) + "\n").encode()
    last = ""
    for node in PUSH_NODES:
        url = f"http://{node}:{PUSH_PORT}/metrics/job/{PUSH_JOB}"
        try:
            req = urllib.request.Request(url, data=body, method="POST")
            with urllib.request.urlopen(req, timeout=10) as r:
                if r.status in (200, 202):
                    return f"pushed to {node}:{PUSH_PORT} (job={PUSH_JOB})"
                last = f"{node} -> HTTP {r.status}"
        except (urllib.error.URLError, OSError) as e:
            last = f"{node} -> {type(e).__name__}"
    return f"push FAILED ({last}) — the run is still recorded"


def remember(metrics: dict, delta_lines: list) -> str:
    """One memory per run, so a future session recalls the trend without
    running anything. Best-effort, like the push."""
    head = ", ".join(f"{k}={metrics.get(k)}" for k in
                     ("turns", "d1_corrections", "d2_anomalies", "d4_wins"))
    body = (f"session-reflection run {metrics.get('recorded_at', '')[:10]}: {head}. "
            + ("Movement vs previous run: " + "; ".join(delta_lines[:6]) if delta_lines
               else "First recorded run, no baseline to compare.")
            + " Tooling: docs/agents/session-reflection (homelab reflect).")
    try:
        r = subprocess.run(
            ["homelab", "memory", "store", body[:1400],
             "--category", "facts", "--tags", "session-reflection,metrics,trend",
             "--importance", "0.5",
             "--keywords", "session reflection,detector,trend,tooling,homelab reflect"],
            capture_output=True, text=True, timeout=60)
        return "memory stored" if r.returncode == 0 else f"memory store failed: {r.stderr.strip()[:80]}"
    except Exception as e:  # never fail a run over bookkeeping
        return f"memory store skipped: {type(e).__name__}"


def deltas(cur: dict, prev: dict) -> list:
    """Human-readable movement, worst regressions first."""
    if not prev:
        return []
    rows = []
    for k in SCALARS:
        a, b = prev.get(k), cur.get(k)
        if not isinstance(a, (int, float)) or not isinstance(b, (int, float)):
            continue
        if a == b:
            continue
        pct = (b - a) / a * 100 if a else float("inf")
        rows.append((abs(pct if pct != float("inf") else 999), k, a, b, pct))
    rows.sort(reverse=True)
    return [f"{k} {a}->{b} ({pct:+.0f}%)" for _, k, a, b, pct in rows]


def render(cur: dict, prev: dict, notes: list) -> str:
    out = []
    out.append(f"session-reflection — {cur.get('recorded_at', '')[:19]}")
    if prev:
        out.append(f"  compared against {prev.get('recorded_at', '')[:19]}")
        if prev.get("patterns_fingerprint") != cur.get("patterns_fingerprint"):
            out.append("  ! patterns.json CHANGED between these runs — counts are not "
                       "strictly comparable; a jump may be a new detector, not a regression")
    else:
        out.append("  no previous run — this is the baseline")
    out.append("")
    out.append(f"  {'metric':<26}{'now':>9}{'prev':>9}{'delta':>10}")
    for k in SCALARS:
        b = cur.get(k)
        a = prev.get(k) if prev else None
        if not isinstance(b, (int, float)):
            continue
        d = ""
        if isinstance(a, (int, float)):
            d = f"{b - a:+d}" if b != a else "="
        out.append(f"  {k:<26}{b:>9}{(a if a is not None else '-'):>9}{d:>10}")

    verbs = cur.get("d2_by_verb") or {}
    pverbs = (prev or {}).get("d2_by_verb") or {}
    if verbs:
        out.append("")
        out.append("  built-in chosen over the homelab verb, worst first:")
        for verb, n in sorted(verbs.items(), key=lambda kv: -kv[1])[:10]:
            was = pverbs.get(verb)
            mark = "" if was is None else (f"  ({n - was:+d})" if n != was else "  (=)")
            out.append(f"    {n:>6}  {verb}{mark}")
    for n in notes:
        out.append(f"\n  {n}")
    return "\n".join(out)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")

    r = sub.add_parser("run", help="run the detectors, record and diff")
    r.add_argument("--work-dir", default=os.path.join("/tmp", "session-reflection-run"))
    r.add_argument("--no-push", action="store_true")
    r.add_argument("--no-memory", action="store_true")
    r.add_argument("--no-record", action="store_true", help="do not write to history/")
    r.add_argument("--json", action="store_true")

    d = sub.add_parser("diff", help="compare two recorded runs")
    d.add_argument("--from", dest="a", default=None)
    d.add_argument("--to", dest="b", default=None)

    h = sub.add_parser("history", help="list recorded runs")
    h.add_argument("--json", action="store_true")

    a = ap.parse_args()
    if a.cmd in (None, "run"):
        opts = a if a.cmd else ap.parse_args(["run"])
        # Date.now equivalent, stamped once so the record and the memory agree.
        now = datetime.datetime.now(datetime.timezone.utc).isoformat()
        metrics = run_detectors(opts.work_dir)
        prev = snapshots()[-1] if snapshots() else None
        metrics["recorded_at"] = now
        metrics["patterns_fingerprint"] = patterns_fingerprint()
        notes = []
        if not opts.no_record:
            notes.append("recorded " + os.path.relpath(record(metrics, now), HERE))
        if not opts.no_push:
            notes.append(push(metrics))
        dl = deltas(metrics, prev or {})
        if not opts.no_memory:
            notes.append(remember(metrics, dl))
        if opts.json:
            print(json.dumps({"metrics": metrics, "deltas": dl, "notes": notes}, indent=1))
        else:
            print(render(metrics, prev, notes))
        return

    if a.cmd == "history":
        snaps = snapshots()
        if a.json:
            print(json.dumps(snaps, indent=1))
            return
        if not snaps:
            print("no recorded runs yet — `homelab reflect run` makes the first")
            return
        for s in snaps:
            print(f"  {s.get('recorded_at','')[:19]}  turns={s.get('turns'):<6} "
                  f"d1={s.get('d1_corrections'):<5} d2={s.get('d2_anomalies'):<6} "
                  f"wins={s.get('d4_wins')}  patterns={s.get('patterns_fingerprint','')}")
        return

    if a.cmd == "diff":
        snaps = snapshots()
        if len(snaps) < 2 and not (a.a and a.b):
            raise SystemExit("need at least two recorded runs to diff "
                             f"(have {len(snaps)}) — run `homelab reflect run` again later")
        def pick(sel, default):
            if sel is None:
                return default
            for s in snaps:
                if s.get("recorded_at", "").startswith(sel):
                    return s
            raise SystemExit(f"no recorded run matching {sel!r}")
        cur = pick(a.b, snaps[-1])
        prev = pick(a.a, snaps[-2])
        print(render(cur, prev, []))


if __name__ == "__main__":
    main()
