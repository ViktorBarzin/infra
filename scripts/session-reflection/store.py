"""The claude-sessions store pass of `homelab reflect`.

Reads the metrics in store_metrics.json from the ClickHouse session store
(ADR-0039) for one time window and one user, so a run is a handful of SQL
queries: no transcript files are read and no model tokens are spent. The specs
are data, like patterns.json, and fingerprinted the same way so `diff` can say
when the ruler changed.
"""
import hashlib
import json
import os
import re
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
SPECS = os.path.join(HERE, "store_metrics.json")

_USER = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
_TS = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$")
_PLACEHOLDER = re.compile(r"\{(\w+)\}")


def load_specs(path: str = SPECS) -> list:
    with open(path) as f:
        return json.load(f)["metrics"]


def fingerprint(path: str = SPECS) -> str:
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()[:12]


def render_sql(sql: str, start: str, end: str, user: str) -> str:
    """Fill {start}, {end} and {user} with quoted literals. The values are
    checked against strict patterns first, so nothing can close the quote."""
    if not _USER.match(user or ""):
        raise ValueError(f"not a valid OS user name: {user!r}")
    for v in (start, end):
        if not _TS.match(v):
            raise ValueError(f"not a 'YYYY-MM-DD HH:MM:SS' timestamp: {v!r}")
    values = {"start": f"'{start}'", "end": f"'{end}'", "user": f"'{user}'"}

    def sub(m):
        name = m.group(1)
        if name not in values:
            raise ValueError(f"unknown placeholder {{{name}}}")
        return values[name]
    return _PLACEHOLDER.sub(sub, sql)


def homelab_runner(sql: str) -> str:
    """Run one query through `homelab claude-sessions sql` (admin credentials)."""
    r = subprocess.run(["homelab", "claude-sessions", "sql", "--format", "JSONEachRow", "-"],
                       input=sql, capture_output=True, text=True, timeout=180)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout).strip()[:300])
    return r.stdout


def _num(v):
    if v is None:
        return 0
    f = float(v)
    return int(f) if f.is_integer() else round(f, 4)


def run_specs(specs: list, start: str, end: str, user: str, runner=homelab_runner) -> dict:
    """Run every spec. A failing query is recorded under errors with value None
    and the run carries on, so one broken metric never loses the rest."""
    out = {"window": {"start": start, "end": end, "user": user},
           "scalars": {}, "labelled": {}, "errors": {}}
    for s in specs:
        try:
            raw = runner(render_sql(s["sql"], start, end, user))
            rows = [json.loads(l) for l in raw.splitlines() if l.strip()]
            if s["kind"] == "scalar":
                out["scalars"][s["key"]] = _num(rows[0].get("value")) if rows else 0
            else:
                out["labelled"][s["key"]] = {str(r["label"]): _num(r["value"]) for r in rows}
        except Exception as e:  # record and continue
            out["errors"][s["key"]] = f"{type(e).__name__}: {e}"[:300]
            if s["kind"] == "scalar":
                out["scalars"][s["key"]] = None
            else:
                out["labelled"][s["key"]] = {}
    return out


def _flat(snap: dict) -> dict:
    flat = dict((snap or {}).get("scalars") or {})
    for key, rows in ((snap or {}).get("labelled") or {}).items():
        for label, v in rows.items():
            flat[f"{key}[{label}]"] = v
    return flat


def deltas(cur: dict, prev) -> list:
    """Movement against the previous run, biggest relative change first."""
    if not prev:
        return []
    a_all, b_all = _flat(prev), _flat(cur)
    rows = []
    for k, b in b_all.items():
        a = a_all.get(k)
        if not isinstance(a, (int, float)) or not isinstance(b, (int, float)) or a == b:
            continue
        pct = (b - a) / a * 100 if a else float("inf")
        rows.append((abs(pct) if pct != float("inf") else 1e9, k, a, b, pct))
    rows.sort(key=lambda r: -r[0])
    return [f"{k} {a}->{b} ({'new' if p == float('inf') else f'{p:+.0f}%'})"
            for _, k, a, b, p in rows]


def _fmt(v) -> str:
    return "-" if v is None else str(v)


def _delta(a, b) -> str:
    if not isinstance(a, (int, float)) or not isinstance(b, (int, float)):
        return ""
    if a == b:
        return "="
    if isinstance(a, int) and isinstance(b, int):
        return f"{b - a:+d}"
    return f"{round(b - a, 2):+}"


def render(cur: dict, prev, specs: list) -> str:
    w = cur.get("window", {})
    out = [f"  from the session store, {w.get('start', '')} to {w.get('end', '')} UTC, user {w.get('user', '')}"]
    ps = (prev or {}).get("scalars") or {}
    pl = (prev or {}).get("labelled") or {}
    out.append(f"  {'metric':<32}{'now':>12}{'prev':>12}{'delta':>10}")
    for s in specs:
        if s["kind"] != "scalar":
            continue
        b, a = cur["scalars"].get(s["key"]), ps.get(s["key"])
        out.append(f"  {s['key']:<32}{_fmt(b):>12}{_fmt(a):>12}{_delta(a, b):>10}")
    for s in specs:
        if s["kind"] != "labelled":
            continue
        rows = cur["labelled"].get(s["key"]) or {}
        out.append("")
        out.append(f"  {s['key']}: {s['description']}")
        if not rows:
            out.append("    (none)")
        for label, v in rows.items():
            a = (pl.get(s["key"]) or {}).get(label)
            mark = f"  ({_fmt(a)} before)" if a is not None and a != v else ""
            out.append(f"    {_fmt(v):>10}  {label}{mark}")
    for key, err in (cur.get("errors") or {}).items():
        out.append(f"\n  ! {key} failed: {err}")
    return "\n".join(out)


def metric_lines(cur: dict) -> list:
    """Prometheus exposition lines. No TYPE lines: Pushgateway rejects a type
    that disagrees with what other jobs already pushed under the same name."""
    lines = []
    for k, v in (cur.get("scalars") or {}).items():
        if isinstance(v, (int, float)):
            lines.append(f"session_reflection_store_{k} {v}")
    for k, rows in (cur.get("labelled") or {}).items():
        for label, v in rows.items():
            if isinstance(v, (int, float)):
                safe = label.replace('"', "").replace("\\", "").replace("\n", " ")
                lines.append(f'session_reflection_store_{k}{{label="{safe}"}} {v}')
    return lines
