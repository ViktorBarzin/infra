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


def page(name, variants, extra="") -> str:
    body = ",".join(json.dumps(v, separators=(",", ":")) for v in variants)
    p = WORK / name
    p.write_text(f'<html><body><script>window.__D__={{"variants":[{body}]}}</script>'
                 f'{extra}</body></html>')
    return f"file://{p}"


# --- the scenarios -----------------------------------------------------------
FULL = "97.49"        # list price of a 90-serving Original tub
SALE = "55.00"        # £26.57/kg protein — inside Viktor's buying band
DEEPER = "48.00"      # £23.19/kg — a new low AND >50% off, which alone says nothing

STRAWBERRY = lambda price: variant(900001, "Strawberry Cream", "2.7kg - 90servings", price, FULL)
COOKIES = lambda: variant(900002, "Cookies and Cream", "2.7kg - 90servings", FULL, FULL)
# Never on the old four-flavour watchlist. Under the all-flavours scope it is
# exactly what we now expect to hear about. Priced REALISTICALLY (£27.54/kg, just
# inside his £28 bar): it used to be £20.00 for a 2.7kg tub, a price MyProtein has
# never charged. A fixture that cannot occur produces failures that cannot either.
OFFLIST = lambda: variant(900003, "Vanilla", "2.7kg - 90servings", "57.00", FULL)
# A licensed collab: no published protein figure, so its £/kg is not something
# we can assert. Priced to qualify on both counts if the guard were missing.
UNVERIFIED = lambda: variant(900004, "Twix®", "1.05kg - 30servings", "16.00", FULL)
# Milk Tea, 2026-11-24: the 250 g tester is a 31.25 g scoop and passes the scoop
# check alone, but its 840 g pack is a 28 g scoop, so the flavour's protein is
# not known and neither pack may be priced.
MILK_TEA_250 = lambda: variant(900005, "Milk Tea", "250G - 8servings", "5.00", "13.99")
MILK_TEA_840 = lambda: variant(900006, "Milk Tea", "840g - 30servings", "28.99", "34.99")
# A Milkshake tub under the bar, cheaper per gram than the whey one beside it.
SHAKE = lambda: variant(900007, "Banana (Milkshake)", "2610g - 90servings", "45.00", "105.99")

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
expect(not k["discount"], "no 40%-off alert — that trigger is retired, only protein price speaks")
expect(k["return"], "RETURN fires — Cookies and Cream is back on the Original line")
expect(not k["low"], "no record-low alert — that trigger is retired")
expect("Vanilla" in posts[0]["text"],
       "ALL FLAVOURS — Vanilla, never on the old watchlist, is reported now it is cheapest")
expect("£26.57/kg protein" in posts[0]["text"], "message leads with £/kg of protein")
expect(posts[0]["text"].startswith("*Cookies and Cream is back*"),
       "header leads with the C&C return — the bigger news when several triggers batch")
expect(not any(k.startswith(("low:", "disc:")) for k in state()),
       "no state for the retired triggers")

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
expect(not k["low"] and not k["discount"], "only the deal speaks, not a record or a % off")
expect(not k["return"], "RETURN stays quiet — already announced")

# 4. The sale ends -------------------------------------------------------------
r, posts = run(QUIET, "4. sale ends, C&C delisted again")
expect(r.returncode == 0, "run succeeds")
expect(len(posts) == 0, "SILENT — nothing qualifies")
expect("900001" not in state(), "deal state cleared so the next sale is announced afresh")

# 5. A later sale --------------------------------------------------------------
r, posts = run(PROMO, "5. a later, shallower sale returns")
k = kinds(posts)
expect(r.returncode == 0, "run succeeds")
expect(k["deal"], "DEAL fires again — a lapsed deal is re-announced")
expect(posts[0]["text"].startswith("*Impact Whey is at your buying price*"),
       "with no return in the batch, the header names the buying price")

# 6. A flavour whose protein figure is not published ---------------------------
# A Twix tub at £16.00 for 30 servings looks like £23.19/kg protein IF you assume
# the 23 g ceiling. We do not know its protein content, and an 84% discount is
# not a protein price, so it says nothing (Viktor, 2026-11-24).
r, posts = run(UNKNOWN_PROTEIN, "6. a licensed collab flavour, cheap and 84% off")
expect(r.returncode == 0, "run succeeds")
expect(len(posts) == 0, "SILENT — no protein figure, so no protein deal")

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

# 11. A tester tub whose bigger packs give the flavour away --------------------
# The 2026-11-24 false deal: Milk Tea 250 g at £5.00 read as £27.17/kg protein.
r, posts = run(page("milktea.html", [STRAWBERRY(FULL), MILK_TEA_250(), MILK_TEA_840()]),
               "11. Milk Tea tester at £5.00, its 840 g pack off-standard")
expect(r.returncode == 0, "run succeeds")
expect(len(posts) == 0, "SILENT — one off-standard pack holds out the whole flavour")
expect("held out" in r.stdout and "Milk Tea" in r.stdout, "the run log names it")

# 12. A code that only applies in the basket ---------------------------------
# 2026-10-27: code EXTRA took 15% off Impact Whey that no shelf price showed.
# £68.99 is £33.33/kg on the shelf and £26.66 with 20% off, inside the £28 bar.
CODE_EVENT = ('<script type="application/ld+json">{"@type":"SaleEvent","name":'
              '"FLASH SALE. <b>EXTRA 20% OFF ALMOST EVERYTHING.</b> USE CODE <b>BOOST</b>."}'
              '</script>')
WITH_CODE = page("code.html", [STRAWBERRY("68.99")], CODE_EVENT)
CODE_ENDED = page("code_ended.html", [STRAWBERRY("68.99")])

r, posts = run(WITH_CODE, "12a. a code takes the shelf price under the bar")
expect(r.returncode == 0, "run succeeds")
expect(len(posts) == 1 and "BOOST" in posts[0]["text"]
       and "£26.66/kg protein" in posts[0]["text"],
       "ALERTS — names the code and the price with it")
r, posts = run(WITH_CODE, "12b. same code, next run")
expect(len(posts) == 0, "SILENT — already announced")
r, posts = run(WITH_CODE, "12c. digest while the code runs", digest=True)
expect(len(posts) == 1 and "BOOST" in posts[0]["text"]
       and "a deal is live" in posts[0]["text"],
       "the digest reports the code deal")
r, posts = run(CODE_ENDED, "12d. the code ends")
expect(not any(k.startswith("code:") for k in state()), "its state is dropped")
r, posts = run(WITH_CODE, "12e. the code comes back")
expect(len(posts) == 1 and "BOOST" in posts[0]["text"], "ALERTS again")

# 13. Whey first ---------------------------------------------------------------
# Viktor 2026-11-24: whey is what he wants, Milkshake will do. Both are said,
# whey first, even when the Milkshake tub is cheaper per gram.
r, posts = run(page("both.html", [SHAKE(), STRAWBERRY(SALE)]), "13. whey and Milkshake deals together")
text = "\n".join(p["text"] for p in posts)
expect(len(posts) == 1 and "(Milkshake)" in text and "(Original)" in text, "both are reported")
expect(text.index("(Original)") < text.index("(Milkshake)"), "whey is listed first")

print("\n" + "=" * 70)
if failures:
    print(f"SMOKE TEST FAILED — {len(failures)} assertion(s):")
    for f in failures:
        print(f"  - {f}")
    raise SystemExit(1)
print(f"SMOKE TEST PASSED — positive path verified end to end ({len(POSTS)} webhook deliveries)")
