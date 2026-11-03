#!/usr/bin/env python3
"""Turn a detector run's output into the args the agent workflow expects.

Without this the expensive half needs a hand-built JSON blob, which is exactly
the kind of remembered step that stops happening. Usage:

    homelab reflect run --work-dir /tmp/sr --no-record
    python3 workflow_args.py /tmp/sr > /tmp/sr/wf_args.json
"""
import collections
import json
import os
import sys

work = sys.argv[1] if len(sys.argv) > 1 else "/tmp/session-reflection-run"
need = ("metrics.json", "d2_anomalies.json", "manifest.json")
missing = [f for f in need if not os.path.exists(os.path.join(work, f))]
if missing:
    raise SystemExit(f"{work} is missing {missing} — run `homelab reflect run "
                     f"--work-dir {work}` first")

metrics = json.load(open(os.path.join(work, "metrics.json")))
d2 = json.load(open(os.path.join(work, "d2_anomalies.json")))
manifest = json.load(open(os.path.join(work, "manifest.json")))
buckets = collections.Counter(x["verb"] for x in d2)
spans = [m.get("first_ts") for m in manifest if m.get("first_ts")]

print(json.dumps({
    "scratch": os.path.abspath(work),
    "corpus": {
        "sessions": len(manifest),
        "human_turns": metrics.get("turns"),
        "tool_calls": sum(m.get("n_tools", 0) for m in manifest),
        "span": f"{min(spans)[:10]}..{max(spans)[:10]}" if spans else "unknown",
    },
    "d2_buckets": [{"verb": v, "count": c} for v, c in buckets.most_common()],
}, indent=1))
