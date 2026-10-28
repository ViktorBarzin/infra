#!/usr/bin/env python3
"""Push net worth and its daily change into ha-sofia as sensor.net_worth.

The HA Companion app reads the sensor into an Apple Watch corner
complication: the total on the inner line, the change on the outer arc.
Design: docs/adr/0034-net-worth-reaches-the-watch-through-ha.md.

Totals come from the wealthfolio_sync mirror (view dav_corrected, GBP). Each
date's total is the sum of every account's last-known value on or before that
date, so an account whose row lands late can't drop out of the sum. The total
on the latest date matches the Grafana "Net worth (current)" tile.

The change compares the last weekday with the weekday before it. On a
weekday that is today's intraday value (recalculated every 15 min in market
hours) against yesterday's close. Weekend rows only carry Friday forward, so
Saturday, Sunday and Monday before Wealthfolio's first recalc all show
Friday's move.

Runs on the job-runtime image (python3 + psql); stdlib only.
Env:
  PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD - wealthfolio_sync DB
  HA_URL   - e.g. https://ha-sofia.viktorbarzin.me
  HA_TOKEN - ha-sofia long-lived access token
"""
import datetime as dt
import json
import os
import subprocess
import sys
import urllib.request
from decimal import ROUND_HALF_UP, Decimal

ENTITY_ID = "sensor.net_worth"
STALE_AFTER_DAYS = 3
GREEN = "#34C759"
RED = "#FF3B30"
GREY = "#8E8E93"

TOTALS_SQL = """
WITH dates AS (
  SELECT DISTINCT valuation_date AS d FROM dav_corrected
  WHERE valuation_date > (SELECT MAX(valuation_date) FROM dav_corrected) - 14
)
SELECT dates.d, SUM(v.total_value)
FROM dates
CROSS JOIN accounts a
LEFT JOIN LATERAL (
  SELECT x.total_value FROM dav_corrected x
  WHERE x.account_id = a.id AND x.valuation_date <= dates.d
  ORDER BY x.valuation_date DESC LIMIT 1
) v ON true
GROUP BY dates.d
ORDER BY dates.d
"""


def _round(value, places="1"):
    return value.quantize(Decimal(places), rounding=ROUND_HALF_UP)


def format_total(value):
    """£1.48M at or above a million, £988k below it."""
    if _round(value / 10000) * 10000 >= 1_000_000:
        return "£%sM" % _round(value / 1_000_000, "0.01")
    return "£%sk" % _round(value / 1000)


def format_change(value):
    """Arrow and amount for the outer arc, plus the colour to draw it in."""
    pounds = _round(abs(value))
    if pounds == 0:
        return "±£0", GREY
    arrow, color = ("▲", GREEN) if value > 0 else ("▼", RED)
    if pounds >= 1000:
        return "%s£%sk" % (arrow, _round(abs(value) / 1000, "0.1")), color
    return "%s£%s" % (arrow, pounds), color


def parse_totals(psql_output):
    totals = {}
    for line in psql_output.splitlines():
        if line.strip():
            day, total = line.split("|")
            totals[dt.date.fromisoformat(day)] = Decimal(total)
    return totals


def build_state(totals, today):
    """The HA state payload for a {date: total} map, judged as of `today`."""
    if not totals:
        raise ValueError("no valuation rows")
    latest = max(totals)
    weekdays = sorted(d for d in totals if d.weekday() < 5)
    stale = (today - latest).days > STALE_AFTER_DAYS

    change = as_of = compared_to = None
    if len(weekdays) >= 2:
        as_of, compared_to = weekdays[-1], weekdays[-2]
        change = totals[as_of] - totals[compared_to]

    if change is None or stale:
        change_short, change_color = "—", GREY
    else:
        change_short, change_color = format_change(change)

    total = totals[latest]
    return {
        "state": str(_round(total)),
        "attributes": {
            "friendly_name": "Net worth",
            "unit_of_measurement": "GBP",
            "icon": "mdi:finance",
            "total_short": format_total(total),
            "change": None if change is None else float(_round(change, "0.01")),
            "change_short": change_short,
            "change_color": change_color,
            "as_of": as_of and as_of.isoformat(),
            "compared_to": compared_to and compared_to.isoformat(),
            "latest_valuation": latest.isoformat(),
            "stale": stale,
        },
    }


def fetch_totals():
    out = subprocess.run(
        ["psql", "-v", "ON_ERROR_STOP=1", "-At", "-F", "|", "-c", TOTALS_SQL],
        check=True, capture_output=True, text=True,
    ).stdout
    return parse_totals(out)


def push(payload):
    req = urllib.request.Request(
        "%s/api/states/%s" % (os.environ["HA_URL"].rstrip("/"), ENTITY_ID),
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": "Bearer %s" % os.environ["HA_TOKEN"],
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        return resp.status


def main():
    payload = build_state(fetch_totals(), dt.datetime.now(dt.timezone.utc).date())
    status = push(payload)
    a = payload["attributes"]
    print("pushed %s=%s (%s %s, as of %s) -> HTTP %s" % (
        ENTITY_ID, payload["state"], a["total_short"], a["change_short"], a["as_of"], status))


if __name__ == "__main__":
    sys.exit(main())
