#!/usr/bin/env python3
"""End-to-end smoke test for the POSITIVE path — what happens when a promotion
actually lands.

The unit tests cover the trigger logic; this covers the parts they cannot:
the real check.py driven through its CLI, reading a page over a URL, POSTing a
real HTTP request to a webhook, and persisting state between runs.

Why it exists: the live watcher may not see a qualifying deal for months
(Viktor buys roughly every 4 months), so "it will work when a sale comes" would
otherwise be an untested claim. This makes that claim reproducible on demand.

Slack is stood in for by a loopback capture server, so running this NEVER posts
a fabricated deal to the real #alerts channel. The genuine POST path to Slack is
exercised identically — same post_slack(), same HTTP, same 2xx check — only the
destination differs.

Run locally:     python3 smoke_test.py
Run in-cluster:  as a Job mounting the myprotein-watch-script ConfigMap, with
                 CHECK=/scripts/check.py
Exit 0 = every assertion passed.
"""

from __future__ import annotations

import http.server
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading

CHECK = os.environ.get("CHECK", str(pathlib.Path(__file__).with_name("check.py")))
WORK = pathlib.Path(tempfile.mkdtemp(prefix="mpw-smoke-"))
POSTS: list[dict] = []
failures: list[str] = []


class Capture(http.server.BaseHTTPRequestHandler):
    """Stands in for the Slack incoming webhook."""

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        POSTS.append(json.loads(body))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *_):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Capture)
WEBHOOK = f"http://127.0.0.1:{server.server_port}/hook"
threading.Thread(target=server.serve_forever, daemon=True).start()


def variant(sku, flavour, amount, price, rrp, in_stock=True):
    """One variant in MyProtein's real embedded-JSON shape."""
    return {
        "title": f"Impact Whey Protein Powder - {amount} - {flavour}",
        "sku": sku,
        "inStock": in_stock,
        "choices": [
            {"optionKey": "Flavour", "key": flavour},
            {"optionKey": "Amount", "key": amount},
        ],
        "price": {
            "price": {"currency": "GBP", "amount": price},
            "rrp": {"currency": "GBP", "amount": rrp},
        },
    }


def page(name, variants) -> str:
    body = ",".join(json.dumps(v, separators=(",", ":")) for v in variants)
    p = WORK / name
    p.write_text(f'<html><body><script>window.__D__={{"variants":[{body}]}}</script></body></html>')
    return f"file://{p}"


# --- the scenarios -----------------------------------------------------------
FULL = "97.49"        # list price of a 90-serving Original tub
SALE = "55.00"        # £26.57/kg protein — inside Viktor's buying band
DEEPER = "48.00"      # £23.19/kg — a new low AND >50% off

STRAWBERRY = lambda price: variant(900001, "Strawberry Cream", "2.7kg - 90servings", price, FULL)
COOKIES = lambda: variant(900002, "Cookies and Cream", "2.7kg - 90servings", FULL, FULL)
# Never on the old four-flavour watchlist. Under the all-flavours scope it is
# exactly what we now expect to hear about. Priced REALISTICALLY (£27.54/kg, just
# inside his £28 bar): it used to be £20.00 for a 2.7kg tub, a price MyProtein has
# never charged, and once the low trigger started measuring against the best price
# on the page that fake bargain set an unreachable bar and suppressed every other
# variant's new low. A fixture that cannot occur produces failures that cannot either.
OFFLIST = lambda: variant(900003, "Vanilla", "2.7kg - 90servings", "57.00", FULL)
# A licensed collab: no published protein figure, so its £/kg is not something
# we can assert. Priced to qualify on both counts if the guard were missing.
UNVERIFIED = lambda: variant(900004, "Twix®", "1.05kg - 30servings", "16.00", FULL)
# 250 g / 8 servings — structurally poor value per kg whatever it costs.
TASTER = lambda price: variant(900005, "Chocolate Brownie", "250G - 8servings", price, "13.99")

PROMO = page("promo.html", [STRAWBERRY(SALE), COOKIES(), OFFLIST()])
DEEP = page("deep.html", [STRAWBERRY(DEEPER), COOKIES(), OFFLIST()])
QUIET = page("quiet.html", [STRAWBERRY(FULL), OFFLIST()])   # no sale, C&C delisted again
UNKNOWN_PROTEIN = page("unverified.html", [STRAWBERRY(FULL), UNVERIFIED()])
# Genuinely nothing qualifying: list price only. QUIET is NOT this — it still
# carries the off-list Vanilla at £9.66/kg, which qualifies; QUIET is silent
# only because dedup already announced it.
FULL_PRICE = page("fullprice.html", [STRAWBERRY(FULL)])


def run(url, label, watch="", digest=False):
    """Invoke the real check.py exactly as the CronJob does.

    watch defaults to "" — the production setting, meaning every flavour.
    """
    before = len(POSTS)
    env = {
        **os.environ,
        "MYPROTEIN_URL": url,
        "SLACK_WEBHOOK_URL": WEBHOOK,
        "STATE_BACKEND": "file",
        "STATE_TARGET": str(WORK / "state.json"),
        "THRESHOLD_PER_KG_PROTEIN": "28",
        "DEEP_DISCOUNT_PCT": "40",
        "NEW_LOW_MARGIN": "0.01",
        "WATCH_FLAVOURS": watch,
        "DIGEST": "true" if digest else "",
    }
    env.pop("DRY_RUN", None)
    r = subprocess.run([sys.executable, CHECK], env=env, capture_output=True, text=True)
    new = POSTS[before:]
    print(f"\n=== {label}")
    print(f"    exit={r.returncode}  slack_posts={len(new)}")
    if r.returncode != 0:
        print(r.stdout[-1500:], r.stderr[-1500:])
    for p in new:
        for line in p["text"].split("\n"):
            print(f"    | {line}")
    return r, new


def expect(cond, msg):
    print(f"    [{'PASS' if cond else 'FAIL'}] {msg}")
    if not cond:
        failures.append(msg)


def kinds(posts):
    """Which trigger kinds appear across the posted messages."""
    text = "\n".join(p["text"] for p in posts)
    return {
        "deal": ":moneybag:" in text,
        "low": ":chart_with_downwards_trend:" in text,
        "discount": ":fire:" in text,
        "return": ":tada:" in text,
    }


def state():
    return json.loads((WORK / "state.json").read_text())


# 1. A promotion lands ---------------------------------------------------------
r, posts = run(PROMO, "1. a promotion appears (Strawberry Cream at £26.57/kg, C&C back)")
k = kinds(posts)
expect(r.returncode == 0, "run succeeds")
expect(len(posts) == 1, "exactly one Slack message (alerts are batched, not spammed)")
expect(k["deal"], "DEAL fires — the price is inside Viktor's band")
expect(k["discount"], "DISCOUNT fires — 44% off is past the 40% bar")
expect(k["return"], "RETURN fires — Cookies and Cream is back on the Original line")
expect(not k["low"], "no NEW LOW on first sighting (nothing to compare against yet)")
expect("Vanilla" in posts[0]["text"],
       "ALL FLAVOURS — Vanilla, never on the old watchlist, is reported now it is cheapest")
expect("£26.57/kg protein" in posts[0]["text"], "message leads with £/kg of protein")
expect(posts[0]["text"].startswith("*Cookies and Cream is back*"),
       "header leads with the C&C return — the bigger news when several triggers batch")
expect("low:900001" in state(), "cheapest-ever baseline seeded silently")

# 2. Nothing changed -----------------------------------------------------------
r, posts = run(PROMO, "2. same page on the next run (dedup)")
expect(r.returncode == 0, "run succeeds")
expect(len(posts) == 0, "SILENT — the same deal is not announced twice")

# 3. It gets cheaper -----------------------------------------------------------
r, posts = run(DEEP, "3. the sale deepens to £23.19/kg")
k = kinds(posts)
expect(r.returncode == 0, "run succeeds")
expect(len(posts) == 1, "one Slack message")
expect(k["deal"], "DEAL re-fires — it got cheaper")
expect(k["low"], "NEW LOW fires — cheapest we have ever recorded")
expect(not k["return"], "RETURN stays quiet — already announced")
expect(abs(state()["low:900001"] - 48.0 / (90 * 23) * 1000) < 0.01, "low ratchets down to the new price")

# 4. The sale ends -------------------------------------------------------------
r, posts = run(QUIET, "4. sale ends, C&C delisted again")
expect(r.returncode == 0, "run succeeds")
expect(len(posts) == 0, "SILENT — nothing qualifies")
expect("900001" not in state(), "deal state cleared so the next sale is announced afresh")
expect("low:900001" in state(), "but the cheapest-ever record is kept")

# 5. A later sale --------------------------------------------------------------
r, posts = run(PROMO, "5. a later, shallower sale returns")
k = kinds(posts)
expect(r.returncode == 0, "run succeeds")
expect(k["deal"], "DEAL fires again — a lapsed deal is re-announced")
expect(not k["low"], "no NEW LOW — £26.57/kg is not better than the £23.19/kg record")
expect(posts[0]["text"].startswith("*Impact Whey is at your buying price*"),
       "with no return in the batch, the header names the buying price")

# 6. A flavour whose protein figure is not published ---------------------------
# The failure this guards against is silent: a Twix tub at £16.00 for 30 servings
# looks like £23.19/kg protein IF you assume the 23 g ceiling, which would read
# as inside Viktor's band. We do not know its protein content, so it must not
# claim to be at his price — while still being reported as a big sale.
r, posts = run(UNKNOWN_PROTEIN, "6. a licensed collab flavour, cheap and 84% off")
k = kinds(posts)
expect(r.returncode == 0, "run succeeds")
expect(len(posts) == 1, "one Slack message")
expect(k["discount"], "DISCOUNT fires — a big sale is a big sale, no protein figure needed")
expect("Twix" in posts[0]["text"], "the Twix sale is named")
expect(not k["deal"], "DEAL does NOT fire — we cannot claim it is at his price per gram")
expect(not k["low"], "no NEW LOW — unverified flavours are kept out of the record")
expect("low:900004" not in state(), "and out of cheapest-ever state entirely")

# 7. The narrowing filter still works when set ---------------------------------
# Kept as a supported knob, so it has to keep working: same page as scenario 1,
# narrowed to one flavour.
r, posts = run(page("narrow.html", [STRAWBERRY(SALE), OFFLIST()]),
               "7. WATCH_FLAVOURS set to narrow back to one flavour",
               watch="Strawberry Cream")
expect(r.returncode == 0, "run succeeds")
expect("Vanilla" not in "\n".join(p["text"] for p in posts),
       "Vanilla is excluded again when a watchlist is explicitly configured")

# 8. The daily heartbeat ------------------------------------------------------
# The point of the digest is that it speaks when NOTHING is happening, which is
# precisely the case no other scenario covers: every alert path above needs
# something to qualify first. QUIET is the page where nothing does.
before = json.dumps(state(), sort_keys=True)
r, posts = run(FULL_PRICE, "8. daily digest, list prices only (the heartbeat)", digest=True)
expect(r.returncode == 0, "run succeeds")
expect(len(posts) == 1, "POSTS ANYWAY — a quiet market still produces a heartbeat")
expect("watcher OK" in posts[0]["text"], "it says the watcher is alive")
expect("\n" not in posts[0]["text"], "one line, as asked")
expect("nothing at or under" in posts[0]["text"], "and states nothing qualifies")
expect(json.dumps(state(), sort_keys=True) == before,
       "STATE UNTOUCHED — the digest cannot swallow an alert the next run owes")

# 9. The digest during a live deal ---------------------------------------------
r, posts = run(PROMO, "9. digest while a deal is running", digest=True)
expect(len(posts) == 1, "one message")
expect("a deal is live" in posts[0]["text"],
       "it flags the live deal instead of reading as all-clear")

# 10. The digest reports a deal the alerting run has gone quiet about ----------
# Scenario 4 proved the alerting run stays SILENT on a still-running deal it
# already announced. That is right for alerts and wrong for reassurance: days
# later Viktor would see nothing and could not tell a running sale from a dead
# job. The digest reads current reality, not the dedup state, so it keeps
# surfacing the offer for as long as it lasts.
r, posts = run(QUIET, "10. digest on a deal already announced days ago", digest=True)
expect(len(posts) == 1, "the digest still speaks")
expect("a deal is live" in posts[0]["text"],
       "and still reports the running offer that alerting has deduped away")

# 11. A personal best that is not worth hearing -------------------------------
# The 2026-08-28 alert Viktor actually received: a 250 g / 8-serving taster tub
# beat its own record and announced £54.35/kg protein while £33.33/kg sat on the
# same page. A record is worth keeping; it is not always worth saying.
TASTER_HIGH = page("taster_high.html", [STRAWBERRY(SALE), TASTER("13.99")])
TASTER_LOW = page("taster_low.html", [STRAWBERRY(SALE), TASTER("10.00")])

r, posts = run(TASTER_HIGH, "11a. seed the taster tub's record", watch="Strawberry Cream")
r, posts = run(TASTER_LOW, "11b. taster tub hits a personal best at a poor price")
expect(r.returncode == 0, "run succeeds")
expect(len(posts) == 0,
       "SILENT — a new low 63% worse than the best price on the page is not news")
expect(any(k.startswith("low:") for k in state()),
       "but the price record is still kept")

print("\n" + "=" * 70)
if failures:
    print(f"SMOKE TEST FAILED — {len(failures)} assertion(s):")
    for f in failures:
        print(f"  - {f}")
    raise SystemExit(1)
print(f"SMOKE TEST PASSED — positive path verified end to end ({len(POSTS)} webhook deliveries)")
