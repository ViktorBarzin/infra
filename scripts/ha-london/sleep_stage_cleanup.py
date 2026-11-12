#!/usr/bin/env python3
"""Repair double-counted sleep stages in Home Assistant's recorder database.

Runs on ha-london inside the Home Assistant container, hourly, as the command of
the `command_line` sensor `sensor.sleep_stage_cleanup` (see
docs/architecture/london-site.md, "Sleep stage cleanup").

Why: the iOS companion app (2026.10.3) builds each sleep stage sensor by merging
that stage's samples across every source. When the Apple Watch and Sleep Cycle
both stage a night, a minute one calls core and the other deep counts in both,
so core + deep + REM exceeds Sleep Duration (662 vs 488 min on 2026-11-12).
Sleep Duration merges every asleep stage together and stays right.

What it does, per phone update in the lookback window:
- clean: |core + deep + REM - Sleep Duration| <= 2 min (each sensor is rounded).
- inflated, and the same values as the update before: the same answer as before.
- inflated: the stages of the last clean update of the same night, meaning at
  most 12 h earlier with Sleep Duration grown by 0 to 90 min; otherwise the
  stages are set to `unknown`, because HA never held the right values.
It rewrites the stage sensors' state rows and recomputes their hourly and
5-minute statistics from the corrected states.

Safety:
- The schema is checked first; a missing column stops the run (`schema_changed`).
- Before writing, it recomputes every statistics row it does not touch and
  compares it with HA's. Any difference stops the run (`self_check_failed`),
  since the model of HA's statistics compiler no longer holds.
- Each run that writes saves the original rows to an undo file first.
- It always prints one JSON line and exits 0, so the sensor shows the status.

Standard library only: the HA container has Python but nothing else we control.
"""
import argparse
import contextlib
import datetime as dt
import io
import json
import os
import sqlite3
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

TOTAL = "sleep_duration"
STAGES = ("core_sleep", "deep_sleep", "rem_sleep", "awake")
ASLEEP = ("core_sleep", "deep_sleep", "rem_sleep")
TOLERANCE_MIN = 2.0
SAME_NIGHT_S = 12 * 3600
SAME_NIGHT_GROWTH_MIN = 90.0
UPDATE_GAP_S = 10.0
BLANK = "unknown"
STAT_TABLES = (("statistics", 3600), ("statistics_short_term", 300))
UNDO_KEEP_DAYS = 30

REQUIRED_COLUMNS = {
    "states": {"state_id", "state", "last_updated_ts", "last_changed_ts", "metadata_id"},
    "states_meta": {"metadata_id", "entity_id"},
    "statistics_meta": {"id", "statistic_id"},
    "statistics": {"id", "metadata_id", "start_ts", "mean", "min", "max"},
    "statistics_short_term": {"id", "metadata_id", "start_ts", "mean", "min", "max"},
}


def as_number(state):
    try:
        return float(state)
    except (TypeError, ValueError):
        return None


def time_weighted(points, start, length):
    """Mean, min and max of a step function over [start, start+length), numeric time only.

    `points` is [(ts, value or None)] sorted by ts; each value lasts until the next point.
    Returns None when no numeric value covers any of the period.
    """
    end = start + length
    carry = None
    inside = []
    for ts, value in points:
        if ts <= start:
            carry = value
        elif ts < end:
            inside.append((ts, value))
    steps = [(start, carry)] + inside
    covered = weighted = 0.0
    values = []
    for i, (ts, value) in enumerate(steps):
        nxt = steps[i + 1][0] if i + 1 < len(steps) else end
        if value is None or nxt <= ts:
            continue
        covered += nxt - ts
        weighted += value * (nxt - ts)
        values.append(value)
    if not covered:
        return None
    return weighted / covered, min(values), max(values)


def carried(points):
    """HA's compiler drops non-numeric states, so the last number carries across them."""
    out, last = [], None
    for ts, value in points:
        if value is not None:
            last = value
        out.append((ts, last))
    return out


@dataclass
class Row:
    state_id: int
    state: str
    ts: float
    changed_ts: float | None


@dataclass
class Plan:
    states: dict = field(default_factory=dict)       # state_id -> (state, last_changed_ts)
    stat_updates: list = field(default_factory=list)  # (table, id, mean, min, max)
    stat_deletes: list = field(default_factory=list)  # (table, id)
    checked: int = 0
    mismatches: list = field(default_factory=list)


def check_schema(conn):
    for table, wanted in REQUIRED_COLUMNS.items():
        have = {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}
        missing = wanted - have
        if missing:
            return f"{table} lacks {sorted(missing)}"
    return None


def load_rows(conn, entity_id, since):
    """State rows from `since`, plus the one in effect at `since`."""
    sql_before = """SELECT s.state_id, s.state, s.last_updated_ts, s.last_changed_ts
        FROM states s JOIN states_meta m USING (metadata_id)
        WHERE m.entity_id = ? AND s.last_updated_ts < ? ORDER BY s.last_updated_ts DESC LIMIT 1"""
    sql_after = """SELECT s.state_id, s.state, s.last_updated_ts, s.last_changed_ts
        FROM states s JOIN states_meta m USING (metadata_id)
        WHERE m.entity_id = ? AND s.last_updated_ts >= ? ORDER BY s.last_updated_ts"""
    rows = list(conn.execute(sql_before, (entity_id, since))) + list(conn.execute(sql_after, (entity_id, since)))
    return [Row(*r) for r in rows]


def updates(rows_by_entity):
    """Group state rows into phone updates: rows less than UPDATE_GAP_S apart."""
    stamps = sorted({r.ts for rows in rows_by_entity.values() for r in rows})
    groups = []
    for ts in stamps:
        if groups and ts - groups[-1][-1] < UPDATE_GAP_S:
            groups[-1].append(ts)
        else:
            groups.append([ts])
    return [(g[0], g[-1]) for g in groups]


def in_effect(rows, ts):
    current = None
    for r in rows:
        if r.ts <= ts:
            current = r
        else:
            break
    return current


def decide(rows_by_entity):
    """New state per stage row: {state_id: new_state}."""
    out = {}
    baseline = None          # (ts, total, {stage: value})
    previous = None          # (raw stage tuple, decision)
    for first, last in updates(rows_by_entity):
        snap = {}
        for name, rows in rows_by_entity.items():
            row = in_effect(rows, last)
            snap[name] = as_number(row.state) if row else None
        total = snap[TOTAL]
        if total is None or any(snap[s] is None for s in ASLEEP):
            previous = None
            continue
        raw = tuple(snap[s] for s in STAGES)
        if abs(sum(snap[s] for s in ASLEEP) - total) <= TOLERANCE_MIN:
            baseline = (last, total, dict(zip(STAGES, raw)))
            previous = (raw, None)
            continue
        if previous and previous[0] == raw and previous[1] is not None:
            decision = previous[1]
        elif (
            baseline
            and last - baseline[0] <= SAME_NIGHT_S
            and 0 <= total - baseline[1] <= SAME_NIGHT_GROWTH_MIN
        ):
            decision = baseline[2]
        else:
            decision = {s: None for s in STAGES}
        previous = (raw, decision)
        for name in STAGES:
            for r in rows_by_entity[name]:
                if first <= r.ts <= last:
                    value = decision[name]
                    out[r.state_id] = BLANK if value is None else format_number(value)
    return out


def format_number(value):
    return str(int(value)) if float(value).is_integer() else repr(float(value))


def plan_entity(conn, entity_id, rows, new_states, since, now, plan):
    """Fill `plan` with the state and statistics changes for one stage entity."""
    old_points = [(r.ts, as_number(r.state)) for r in rows]
    new_rows = [(r, new_states.get(r.state_id, r.state) if r.ts >= since else r.state) for r in rows]
    new_points = [(r.ts, as_number(s)) for r, s in new_rows]

    # last_changed is rewritten only where a value changed, or right after one: null when the
    # value differs from the row before, else the time the row before last changed.
    prev_state = prev_changed = None
    prev_rewritten = False
    changed_spans = []
    for i, (r, state) in enumerate(new_rows):
        rewritten = state != r.state
        changed = r.changed_ts
        if rewritten or prev_rewritten:
            changed = prev_changed if state == prev_state else None
            if changed != r.changed_ts or rewritten:
                plan.states[r.state_id] = (state, changed)
        if rewritten:
            nxt = rows[i + 1].ts if i + 1 < len(rows) else now
            changed_spans.append((r.ts, nxt))
        prev_state, prev_rewritten = state, rewritten
        prev_changed = changed if changed is not None else r.ts

    meta = conn.execute("SELECT id FROM statistics_meta WHERE statistic_id = ?", (entity_id,)).fetchone()
    if not meta:
        return
    blank_stamps = [ts for ts, v in old_points if v is None]
    for table, length in STAT_TABLES:
        for sid, start, mean, lo, hi in conn.execute(
            f"SELECT id, start_ts, mean, min, max FROM {table} WHERE metadata_id = ? AND start_ts >= ?",
            (meta[0], since),
        ):
            end = start + length
            touched = any(a < end and b > start for a, b in changed_spans)
            if not touched:
                near_blank = any(start - length <= ts < end + length for ts in blank_stamps)
                if near_blank:
                    continue
                expect = time_weighted(carried(old_points), start, length)
                plan.checked += 1
                if expect is None or any(not close(a, b) for a, b in zip(expect, (mean, lo, hi))):
                    plan.mismatches.append({"table": table, "entity": entity_id, "start": start,
                                            "have": [mean, lo, hi], "model": expect})
                continue
            new = time_weighted(new_points, start, length)
            if new is None:
                plan.stat_deletes.append((table, sid))
            elif any(not close(a, b) for a, b in zip(new, (mean, lo, hi))):
                plan.stat_updates.append((table, sid, *new))


def close(a, b):
    return b is not None and abs(a - b) <= 1e-6 * max(1.0, abs(a))


def write_undo(conn, plan, undo_dir, now):
    """Save every row the plan changes as INSERT OR REPLACE statements."""
    path = Path(undo_dir)
    path.mkdir(parents=True, exist_ok=True)
    for old in path.glob("undo-*.sql"):
        if now - old.stat().st_mtime > UNDO_KEEP_DAYS * 86400:
            old.unlink()
    lines = []

    def dump(table, key, ids):
        if not ids:
            return
        cols = [r[1] for r in conn.execute(f"PRAGMA table_info({table})")]
        marks = ",".join("?" * len(ids))
        for row in conn.execute(f"SELECT * FROM {table} WHERE {key} IN ({marks})", list(ids)):
            values = ",".join(sql_literal(v) for v in row)
            lines.append(f"INSERT OR REPLACE INTO {table} ({','.join(cols)}) VALUES ({values});")

    dump("states", "state_id", list(plan.states))
    for table, _ in STAT_TABLES:
        ids = [u[1] for u in plan.stat_updates if u[0] == table] + [d[1] for d in plan.stat_deletes if d[0] == table]
        dump(table, "id", ids)
    stamp = dt.datetime.fromtimestamp(now, dt.UTC).strftime("%Y%m%dT%H%M%SZ")
    target = path / f"undo-{stamp}.sql"
    target.write_text("BEGIN;\n" + "\n".join(lines) + "\nCOMMIT;\n")
    return str(target)


def sql_literal(value):
    if value is None:
        return "NULL"
    if isinstance(value, (bytes, bytearray)):
        return "X'" + value.hex() + "'"
    if isinstance(value, (int, float)):
        return repr(value)
    return "'" + str(value).replace("'", "''") + "'"


def run(db_path, prefix, now=None, undo_dir="/config/sleep_stage_cleanup", lookback_hours=72, dry_run=False):
    now = time.time() if now is None else now
    since = now - lookback_hours * 3600
    conn = sqlite3.connect(db_path, timeout=30)
    try:
        problem = check_schema(conn)
        if problem:
            return {"status": "schema_changed", "detail": problem}
        rows = {name: load_rows(conn, f"{prefix}_{name}", since - 24 * 3600) for name in (TOTAL, *STAGES)}
        new_states = decide(rows)
        plan = Plan()
        for name in STAGES:
            plan_entity(conn, f"{prefix}_{name}", rows[name], new_states, since, now, plan)
        summary = {
            "changed_states": len(plan.states),
            "changed_stats": len(plan.stat_updates) + len(plan.stat_deletes),
            "checked": plan.checked,
        }
        if plan.mismatches:
            return {"status": "self_check_failed", **summary, "mismatches": plan.mismatches[:5]}
        if not plan.states and not plan.stat_updates and not plan.stat_deletes:
            return {"status": "ok", **summary}
        if dry_run:
            planned = {sid: state for sid, (state, _) in plan.states.items()}
            return {"status": "dry_run", **summary, "states": planned}
        conn.execute("BEGIN IMMEDIATE")
        undo = write_undo(conn, plan, undo_dir, now)
        for state_id, (state, changed) in plan.states.items():
            conn.execute("UPDATE states SET state = ?, last_changed_ts = ? WHERE state_id = ?",
                         (state, changed, state_id))
        for table, sid, mean, lo, hi in plan.stat_updates:
            conn.execute(f"UPDATE {table} SET mean = ?, min = ?, max = ? WHERE id = ?", (mean, lo, hi, sid))
        for table, sid in plan.stat_deletes:
            conn.execute(f"DELETE FROM {table} WHERE id = ?", (sid,))
        conn.commit()
        return {"status": "ok", **summary, "undo": undo}
    finally:
        conn.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--db", default="/config/home-assistant_v2.db")
    parser.add_argument("--prefix", required=True, help="entity id prefix, e.g. sensor.viktor_barzins_iphone_17")
    parser.add_argument("--undo-dir", default="/config/sleep_stage_cleanup")
    parser.add_argument("--lookback-hours", type=float, default=72)
    parser.add_argument("--dry-run", action="store_true", help="report the changes, write nothing")
    args = parser.parse_args(argv)
    started = time.time()
    try:
        out = run(args.db, args.prefix, undo_dir=args.undo_dir, lookback_hours=args.lookback_hours,
                  dry_run=args.dry_run)
    except Exception as exc:  # the sensor must always get a status line
        out = {"status": "error", "detail": f"{type(exc).__name__}: {exc}"}
    out["run_at"] = dt.datetime.fromtimestamp(started, dt.UTC).isoformat(timespec="seconds")
    out["seconds"] = round(time.time() - started, 2)
    print(json.dumps(out))
    return 0


def main_for_test(argv):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = main(argv)
    return code, buf.getvalue().strip()


if __name__ == "__main__":
    sys.exit(main())
