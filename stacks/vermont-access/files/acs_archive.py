#!/usr/bin/env python3
"""Weekly archive of the Vermont complex access-control events (infra#176).

The six entrance panels (DS-KD9203-E6, 10.77.1.111-116) and the back-door
terminal (DS-K1T805MBFWX, 10.77.1.117) keep their event log in a ring buffer
with no storage card: about two weeks on the busiest panel. This job reads each
device's log over ISAPI and appends it to the vermont_access database, where it
is kept for two years.

Usage:
  acs_archive.py run              pull every device and insert the new events
  acs_archive.py load FILE...     insert a saved copy (gzip JSON lines, one
                                  {"device", "key", "event"} object per line)

Environment: PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD (psql), PANEL_USER,
PANEL_PASSWORD, and optionally DEVICES ("111,...,117"), DEVICE_HOST
("10.77.1.{}"), OVERLAP_DAYS (3), RETENTION ("2 years"), PUSHGATEWAY_URL.

Deduplication. The panels return no serialNo, and some of their events are
identical down to the second, so the key is
sha256(device | canonical JSON of the event | how many identical events came
before it in this pull). The event time is part of the content, so identical
events always fall into the same pull window together and get the same
indexes on every pull. Each run re-reads OVERLAP_DAYS before the newest
archived event and inserts with ON CONFLICT (key) DO NOTHING.

Gap detection. The window starts before the newest archived event, so a device
that still holds that event returns at least one row the archive already has.
If every pulled row is new (or none came back), the device has overwritten
events the archive never saw; the run reports vermont_acs_gap=1.
"""
import collections
import gzip
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import uuid

SCHEMA = r"""
CREATE TABLE IF NOT EXISTS acs_event (
  key          text PRIMARY KEY,
  device       smallint NOT NULL,
  event_time   timestamptz NOT NULL,
  major        integer,
  minor        integer,
  employee_no  text,
  card_no      text,
  name         text,
  event        jsonb NOT NULL,
  archived_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS acs_event_device_time ON acs_event (device, event_time);
CREATE INDEX IF NOT EXISTS acs_event_time ON acs_event (event_time);
CREATE INDEX IF NOT EXISTS acs_event_card ON acs_event (card_no, event_time) WHERE card_no IS NOT NULL;
CREATE INDEX IF NOT EXISTS acs_event_employee ON acs_event (employee_no, event_time) WHERE employee_no IS NOT NULL;
"""

# Panels write local time with no offset ("2026-11-10 17:44:22"); the
# terminal writes ISO 8601 with one ("2026-11-10T18:13:30+02:00").
EVENT_TIME_SQL = r"""CASE WHEN j->'event'->>'time' ~ '([+-]\d\d(:?\d\d)?|Z)$'
       THEN (j->'event'->>'time')::timestamptz
       ELSE (j->'event'->>'time')::timestamp AT TIME ZONE 'Europe/Sofia' END"""

INSERT_SQL = f"""
WITH ins AS (
  INSERT INTO acs_event (key, device, event_time, major, minor, employee_no, card_no, name, event)
  SELECT j->>'key', (j->>'device')::smallint, {EVENT_TIME_SQL},
         (j->'event'->>'major')::integer, (j->'event'->>'minor')::integer,
         NULLIF(j->'event'->>'employeeNoString', ''), NULLIF(j->'event'->>'cardNo', ''),
         NULLIF(j->'event'->>'name', ''), j->'event'
  FROM (SELECT line::jsonb AS j FROM staging) s
  ON CONFLICT (key) DO NOTHING
  RETURNING 1)
SELECT count(*) FROM ins;
"""


# --- pure parts (tested in test_acs_archive.py) ---------------------------

def canonical(event):
    return json.dumps(event, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def keyed_rows(device, events):
    """One {"device", "key", "event"} row per event, in order."""
    seen = collections.Counter()
    rows = []
    for e in events:
        c = canonical(e)
        key = hashlib.sha256(f"{device}|{c}|{seen[c]}".encode()).hexdigest()
        seen[c] += 1
        rows.append({"device": device, "key": key, "event": e})
    return rows


def is_gap(had_rows, pulled, inserted):
    return bool(had_rows) and inserted == pulled


def device_time(pg_time):
    """psql's to_char(..., 'OF') gives "+02"; ISAPI wants "+02:00"."""
    head, sign, off = pg_time[:19], pg_time[19:20], pg_time[20:]
    if ":" not in off:
        off += ":00"
    return f"{head}{sign}{off}"


def pull_events(post, start, end, page_size=30, max_pages=3000):
    """Page through AcsEvent from start to end. post(body) returns the parsed JSON."""
    search_id = uuid.uuid4().hex[:16]
    events, pos = [], 0
    for _ in range(max_pages):
        body = {"AcsEventCond": {"searchID": search_id, "searchResultPosition": pos,
                                 "maxResults": page_size, "major": 0, "minor": 0,
                                 "startTime": start, "endTime": end}}
        page = post(body)["AcsEvent"]
        chunk = page.get("InfoList") or []
        events += chunk
        pos += len(chunk)
        if not chunk or page.get("responseStatusStrg") != "MORE":
            return events
    raise RuntimeError(f"still MORE after {max_pages} pages ({pos} events)")


def metrics_text(results, now):
    out = []

    def gauge(name, help_text, field):
        out.append(f"# HELP {name} {help_text}")
        out.append(f"# TYPE {name} gauge")
        for dev in sorted(results):
            v = results[dev].get(field)
            if v is not None:
                out.append(f'{name}{{device="{dev}"}} {v}')

    gauge("vermont_acs_device_up", "1 if the device answered the event search this run.", "up")
    gauge("vermont_acs_pulled_events", "Events the device returned for the pull window.", "pulled")
    gauge("vermont_acs_inserted_events", "Events new to the archive this run.", "inserted")
    gauge("vermont_acs_gap", "1 if the device had already overwritten events the archive never saw.", "gap")
    gauge("vermont_acs_newest_event_timestamp_seconds", "Time of the newest archived event.", "newest")
    out.append("# HELP vermont_acs_last_run_timestamp_seconds When the archive job last finished.")
    out.append("# TYPE vermont_acs_last_run_timestamp_seconds gauge")
    out.append(f"vermont_acs_last_run_timestamp_seconds {int(now)}")
    return "\n".join(out) + "\n"


def read_copy(path):
    """Rows of a saved copy, each key checked against its event."""
    rows = []
    with gzip.open(path, "rt", encoding="utf-8") as f:
        lines = [json.loads(line) for line in f if line.strip()]
    by_device = collections.defaultdict(list)
    for r in lines:
        by_device[r["device"]].append(r)
    for dev, dev_rows in by_device.items():
        expected = keyed_rows(dev, [r["event"] for r in dev_rows])
        for got, want in zip(dev_rows, expected):
            if got["key"] != want["key"]:
                raise ValueError(f"{path}: key {got['key'][:12]} does not match its event on device {dev}")
        rows += dev_rows
    return rows


# --- database (psql, which job-runtime ships) -----------------------------

def psql(sql, *extra):
    r = subprocess.run(["psql", "-XAtq", "-v", "ON_ERROR_STOP=1", *extra, "-c", sql],
                       capture_output=True, text=True, timeout=600)
    if r.returncode != 0:
        raise RuntimeError(f"psql: {r.stderr.strip()[:500]}")
    return r.stdout.strip()


def insert_rows(rows):
    """Insert rows; returns how many were new."""
    if not rows:
        return 0
    with tempfile.TemporaryDirectory() as d:
        data = os.path.join(d, "rows.jsonl")
        with open(data, "w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        script = os.path.join(d, "load.sql")
        with open(script, "w", encoding="utf-8") as f:
            # CSV with control characters as quote and delimiter keeps each
            # JSON line intact, backslashes included.
            f.write("BEGIN;\nCREATE TEMP TABLE staging (line text) ON COMMIT DROP;\n")
            f.write(f"\\copy staging FROM '{data}' WITH (FORMAT csv, QUOTE E'\\x01', DELIMITER E'\\x02')\n")
            f.write(INSERT_SQL)
            f.write("COMMIT;\n")
        r = subprocess.run(["psql", "-XAtq", "-v", "ON_ERROR_STOP=1", "-f", script],
                           capture_output=True, text=True, timeout=600)
        if r.returncode != 0:
            raise RuntimeError(f"psql load: {r.stderr.strip()[:500]}")
        return int(r.stdout.split()[-1])


def newest(device):
    """(time to start the pull from, newest event epoch), or (None, None)."""
    out = psql(
        "SET TIME ZONE 'Europe/Sofia'; "
        f"SELECT to_char(max(event_time) - make_interval(days => {int(os.environ.get('OVERLAP_DAYS', '3'))}), "
        "'YYYY-MM-DD\"T\"HH24:MI:SSOF'), extract(epoch FROM max(event_time))::bigint "
        f"FROM acs_event WHERE device = {int(device)}")
    start, epoch = (out.splitlines()[-1].split("|") + ["", ""])[:2]
    return (device_time(start), int(epoch)) if start else (None, None)


def now_device_time(days_ahead=1):
    return device_time(psql(
        "SET TIME ZONE 'Europe/Sofia'; "
        f"SELECT to_char(now() + interval '{int(days_ahead)} day', 'YYYY-MM-DD\"T\"HH24:MI:SSOF')").splitlines()[-1])


# --- devices ---------------------------------------------------------------

def make_post(host):
    import requests
    from requests.auth import HTTPDigestAuth
    user, password = os.environ.get("PANEL_USER", "admin"), os.environ["PANEL_PASSWORD"]
    url = f"http://{host}/ISAPI/AccessControl/AcsEvent?format=json"

    def post(body):
        # A fresh digest handshake per request, as curl --digest does. Reusing
        # one HTTPDigestAuth across pages sent a stale nonce that the devices
        # answered with a bare 401 (no new challenge), tested 2026-11-11.
        r = requests.post(url, json=body, auth=HTTPDigestAuth(user, password), timeout=40)
        if r.status_code != 200:
            raise RuntimeError(f"{host}: HTTP {r.status_code} {r.text[:200]}")
        return r.json()
    return post


def push(text):
    url = os.environ.get("PUSHGATEWAY_URL")
    if not url:
        print(text, end="")
        return
    import requests
    r = requests.put(url, data=text.encode(), timeout=20)
    r.raise_for_status()


def run():
    psql(SCHEMA)
    devices = [int(d) for d in os.environ.get("DEVICES", "111,112,113,114,115,116,117").split(",")]
    host_fmt = os.environ.get("DEVICE_HOST", "10.77.1.{}")
    end = now_device_time()
    results, failed = {}, []
    for dev in devices:
        res = {"up": 0, "pulled": 0, "inserted": 0, "gap": 0, "newest": None}
        try:
            start, _ = newest(dev)
            had_rows = start is not None
            events = pull_events(make_post(host_fmt.format(dev)), start or "2020-01-01T00:00:00+02:00", end)
            res["up"], res["pulled"] = 1, len(events)
            res["inserted"] = insert_rows(keyed_rows(dev, events))
            res["gap"] = int(is_gap(had_rows, res["pulled"], res["inserted"]))
            res["newest"] = newest(dev)[1]
            print(f".{dev}: from {start or 'the start'}: pulled {res['pulled']}, new {res['inserted']}"
                  f"{', GAP: the device no longer holds the newest archived event' if res['gap'] else ''}", flush=True)
        except Exception as exc:  # one device down must not stop the others
            failed.append(dev)
            print(f".{dev}: FAILED: {exc}", file=sys.stderr, flush=True)
        results[dev] = res
    retention = os.environ.get("RETENTION", "2 years")
    deleted = psql(f"WITH d AS (DELETE FROM acs_event WHERE event_time < now() - interval '{retention}' RETURNING 1) "
                   "SELECT count(*) FROM d")
    print(f"retention {retention}: deleted {deleted}", flush=True)
    push(metrics_text(results, time.time()))
    if failed:
        sys.exit(f"failed devices: {', '.join(map(str, failed))}")


def load(paths):
    psql(SCHEMA)
    for p in paths:
        rows = read_copy(p)
        print(f"{p}: {len(rows)} rows, new {insert_rows(rows)}", flush=True)


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "load":
        load(sys.argv[2:])
    elif len(sys.argv) == 2 and sys.argv[1] == "run":
        run()
    else:
        sys.exit(__doc__)
