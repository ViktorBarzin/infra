#!/usr/bin/env python3
"""Watch Impact Whey prices on myprotein.com and post to Slack when a flavour
reaches Viktor's buying price.

Every flavour is in scope. It started as a four-flavour watchlist, which meant a
genuine bargain on a fifth would pass unmentioned; taste is a reason to skip
buying, not a reason not to be told. What bounds the net now is whether we can
stand behind a flavour's protein figure — see LICENSED_RE and STANDARD_SCOOP_G.

Why this shape: the product page ships every variant as embedded JSON
(title, flavour, amount, sku, inStock, price, rrp), so a plain HTTP GET is
enough — no browser, no login, no anti-bot surface. Prices are public.

Thresholds come from what Viktor has actually paid, not from the headline
discount percentage: his three Cookies and Cream orders landed at £0.650,
£0.569 and £0.628 per serving (35-43% off RRP), i.e. £28.26, £24.74 and £27.30
per kg of protein. A "50% off" rule would have blocked all three.

The threshold is per KG OF PROTEIN, not per serving, because a serving is not a
fixed amount of protein: Original 23 g, Milkshake 20 g, +Collagen 10 g of whey.
Comparing £/serving across those lines silently overpays on the smaller ones.

Read-only: this fetches a public page and posts a message. It never signs in,
adds to a basket, or places an order.

Config (all via env):
  SLACK_WEBHOOK_URL       required unless DRY_RUN=true
  MYPROTEIN_URL           product page to poll
  STATE_BACKEND           "configmap" (in-cluster) or "file" (local runs)
  STATE_TARGET            ConfigMap name, or file path when STATE_BACKEND=file
  THRESHOLD_PER_KG_PROTEIN  £/kg of protein at or below which a deal is worth
                          telling (£28 = the dearest Viktor has actually paid)
  DEEP_DISCOUNT_PCT       displayed discount that counts as a big sale
  NEW_LOW_MARGIN          how much better than the record a new low must be
  WATCH_FLAVOURS          optional comma-separated flavour substrings to narrow
                          to. Empty (the default) means every flavour.
  DIGEST                  "true" posts the one-line daily heartbeat instead of
                          evaluating triggers. Touches no state.
  DRY_RUN                 "true" prints instead of posting
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any

# Tolerates whitespace around the JSON punctuation: the live page ships compact
# JSON, but that is a serialiser detail we should not depend on.
VARIANT_ANCHOR = re.compile(r'\{\s*"title"\s*:\s*"Impact Whey Protein Powder')
SERVINGS_RE = re.compile(r"(\d+)\s*servings", re.I)
LINE_SUFFIX_RE = re.compile(r"\s*\(([^)]+)\)\s*$")
AMOUNT_G_RE = re.compile(r"([\d.]+)\s*(kg|g)\b", re.I)

# Lines whose serving is ~23 g of whey. The +Collagen line is deliberately
# absent: half of its 20 g "protein" is collagen peptides, so its £/serving is
# not comparable and must not trip the same trigger.
DEAL_LINES = ("Original", "Milkshake")

# Grams of COMPLETE protein per serving, from the product page's own claims
# (checked 2026-08-15). These differ by line, so £/serving is NOT a like-for-like
# price and every threshold here is expressed per kg of protein instead.
#   Original            "delivering 23g of protein per serving"
#   Milkshake           "Every serving delivers 20g of protein" (whey concentrate
#                       + milk protein isolate — both complete)
#   Original + crunch   the biscuit pieces displace protein; these print 20g
#   +Collagen           20g on the label, but 10g of it is collagen peptides,
#                       which are tryptophan-free and do not support MPS
PROTEIN_G_DEFAULT = 23.0
PROTEIN_G_MILKSHAKE = 20.0
PROTEIN_G_CRUNCH = 20.0
PROTEIN_G_COLLAGEN_WHEY = 10.0
CRUNCH_RE = re.compile(r"crunch|biscuit pieces", re.I)

# Every flavour is in scope, so the 23 g figure now has to carry flavours it was
# never checked against. The page advertises "up to 23g protein per serving" — a
# ceiling — and publishes no per-flavour macros at all (they sit behind an 'i'
# icon, off this page). Assuming the ceiling for a flavour that carries
# chocolate-bar pieces would overstate its protein, and therefore understate its
# £/kg, presenting a worse deal as a better one. So where the figure is an
# assumption rather than a published claim, the flavour is left out of the value
# triggers and covered by the big-sale trigger instead, which needs no protein
# figure to be true.
#
# Two signals mark a figure as an assumption:
#
# 1. Licensed collaborations are separately formulated and make no claim here.
LICENSED_RE = re.compile(
    r"snickers|\bmars\b|\btwix\b|\bbounty\b|hotel chocolat|jimmy'?s coffee", re.I
)
# 2. The 23 g claim belongs to the standard 30 g scoop. Where a flavour's own
#    scoop is materially off that, its protein content is not something we know:
#    a 27 g scoop cannot hold what a 30 g one does, and mass above 30 g is more
#    likely inclusions than whey. Flavours whose bigger scoop IS explained by a
#    published claim (the biscuit-pieces 20 g) are exempt.
STANDARD_SCOOP_G = 30.0
SCOOP_TOLERANCE = 0.05

# A "big sale" on MyProtein's own reckoning. Note their RRP is their number and
# it drifts upward over time, which is why this supplements the £/serving
# trigger rather than replacing it.
DEEP_DISCOUNT_PCT = 40

# How much better than the previous record a price must be before a new low is
# worth saying out loud. Guards against announcing a rounding-level dip.
NEW_LOW_MARGIN = 0.01

USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"
)


@dataclass(frozen=True)
class Variant:
    title: str
    sku: int
    in_stock: bool
    flavour: str
    amount: str
    servings: int
    price: float
    rrp: float

    @property
    def line(self) -> str:
        m = LINE_SUFFIX_RE.search(self.flavour)
        if not m:
            return "Original"
        suffix = m.group(1).strip().lstrip("+").lower()
        if suffix == "collagen":
            return "Collagen"
        if suffix == "milkshake":
            return "Milkshake"
        return "Original"

    @property
    def base_flavour(self) -> str:
        return LINE_SUFFIX_RE.sub("", self.flavour).strip()

    @property
    def price_per_serving(self) -> float | None:
        return self.price / self.servings if self.servings else None

    @property
    def pack_size(self) -> str | None:
        """The pack weight as the page states it — when it states one.

        Not guaranteed: on 2026-08-22 a 120-serving Milkshake shipped with the
        amount "120servings" and no weight at all, and it was the cheapest
        variant on the page, so it is what a message would name. Servings and
        protein per serving are both known there, so pricing is unaffected —
        only the size we can show a human.
        """
        m = AMOUNT_G_RE.search(self.amount)
        return m.group(0).strip() if m else None

    @property
    def scoop_g(self) -> float | None:
        """Grams of powder in one serving, from the pack size and serving count.

        The page states no scoop weight, but it states both of these, and their
        ratio is what tells us whether a flavour is built like the standard one.
        """
        m = AMOUNT_G_RE.search(self.amount)
        if not m or not self.servings:
            return None
        grams = float(m.group(1)) * (1000 if m.group(2).lower() == "kg" else 1)
        return grams / self.servings

    @property
    def protein_verified(self) -> bool:
        """Whether whey_g_per_serving rests on a published claim or an assumption.

        Only the value triggers require this. See the notes on LICENSED_RE and
        STANDARD_SCOOP_G for why each signal marks a figure as unknown.
        """
        # These three lines each publish their own per-serving figure, so their
        # scoop size does not have to match the plain Original one.
        if self.line in ("Milkshake", "Collagen"):
            return True
        if CRUNCH_RE.search(self.base_flavour):
            return True
        if LICENSED_RE.search(self.base_flavour):
            return False
        if self.scoop_g is None:
            return False
        return abs(self.scoop_g - STANDARD_SCOOP_G) <= STANDARD_SCOOP_G * SCOOP_TOLERANCE

    @property
    def whey_g_per_serving(self) -> float:
        """Grams of COMPLETE protein in one serving.

        Kept separate from the label figure because the +Collagen line's 20 g
        includes 10 g of collagen peptides, which are tryptophan-free and do
        not support muscle protein synthesis.
        """
        if self.line == "Collagen":
            return PROTEIN_G_COLLAGEN_WHEY
        if self.line == "Milkshake":
            return PROTEIN_G_MILKSHAKE
        if CRUNCH_RE.search(self.base_flavour):
            return PROTEIN_G_CRUNCH
        return PROTEIN_G_DEFAULT

    @property
    def price_per_kg_protein(self) -> float | None:
        """The only basis on which two variants can be honestly compared."""
        if not self.servings:
            return None
        return self.price / (self.servings * self.whey_g_per_serving) * 1000

    @property
    def discount_pct(self) -> int:
        if not self.rrp:
            return 0
        return round((1 - self.price / self.rrp) * 100)


@dataclass(frozen=True)
class Alert:
    kind: str  # "deal" | "return"
    variant: Variant


def _json_objects(html: str, anchor: re.Pattern[str]):
    """Yield each complete JSON object in `html` whose start matches `anchor`.

    Brace-matching rather than a field-order regex: MyProtein reorders keys
    between variants, and a regex that assumes an order silently drops rows.
    """
    for match in anchor.finditer(html):
        start = match.start()
        depth, in_str, escaped = 0, False, False
        for i in range(start, len(html)):
            c = html[i]
            if in_str:
                if escaped:
                    escaped = False
                elif c == "\\":
                    escaped = True
                elif c == '"':
                    in_str = False
            elif c == '"':
                in_str = True
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    yield html[start:i + 1]
                    break


def _choice(obj: dict[str, Any], key: str) -> str | None:
    for c in obj.get("choices") or []:
        if c.get("optionKey") == key:
            return c.get("key") or c.get("title")
    return None


def parse_variants(html: str) -> list[Variant]:
    """Extract every purchasable variant from the product page HTML."""
    out: list[Variant] = []
    seen: set[int] = set()
    for blob in _json_objects(html, VARIANT_ANCHOR):
        try:
            obj = json.loads(blob)
            sku = int(obj["sku"])
            flavour = _choice(obj, "Flavour")
            amount = _choice(obj, "Amount")
            price_block = obj["price"]
            price = float(price_block["price"]["amount"])
            rrp = float(price_block.get("rrp", price_block["price"])["amount"])
            servings_match = SERVINGS_RE.search(amount or "")
            if not (flavour and amount and servings_match):
                continue
        except (ValueError, KeyError, TypeError):
            continue  # a shape we do not recognise is not a reason to fail the run
        if sku in seen:
            continue
        seen.add(sku)
        out.append(Variant(
            title=obj.get("title", ""),
            sku=sku,
            in_stock=bool(obj.get("inStock")),
            flavour=flavour,
            amount=amount,
            servings=int(servings_match.group(1)),
            price=price,
            rrp=rrp,
        ))
    return out


def _watched(variant: Variant, watch: list[str]) -> bool:
    """Whether a flavour passes the optional narrowing filter.

    No terms means no narrowing — every flavour is in scope, which is the
    production default. Blank terms are ignored rather than matching nothing, so
    an env var set to "" or "," widens instead of silencing the whole job.
    """
    terms = [t.strip().lower() for t in watch if t.strip()]
    if not terms:
        return True
    flavour = variant.base_flavour.lower()
    return any(term in flavour for term in terms)


def comparable(variants: list[Variant], watch: list[str]) -> list[Variant]:
    """In-stock variants whose £/kg of protein means the same thing.

    Two exclusions, for different reasons:

    The +Collagen line, because half of its 20 g "protein" is collagen peptides.
    Its £/kg is normalised to the whey half, but Viktor's threshold came from
    whole-whey purchases, so it is not the same product being priced.

    Flavours whose protein per serving we would be guessing at — see
    Variant.protein_verified. Guessing high is what turns a worse deal into an
    apparent bargain, so those are covered by the big-sale trigger instead.
    """
    return [
        v for v in variants
        if v.in_stock
        and v.line in DEAL_LINES
        and v.protein_verified
        and _watched(v, watch)
        and v.price_per_kg_protein is not None
    ]


def find_deals(variants: list[Variant], watch: list[str], threshold: float) -> list[Variant]:
    """Comparable variants at or under the £/kg-of-protein threshold.

    Deliberately NOT £/serving: the Original line puts 23 g in a serving and
    the Milkshake line 20 g, so the same £/serving is ~15% worse value on the
    Milkshake line. Viktor's threshold came from Original-line purchases, so
    applying it per-serving to a 20 g line would alert him on a worse deal
    than he actually buys.
    """
    return [v for v in comparable(variants, watch)
            if v.price_per_kg_protein <= threshold]


def find_deep_discounts(variants: list[Variant], watch: list[str], min_pct: int) -> list[Variant]:
    """Anything where MyProtein's own displayed discount is unusually deep.

    This one deliberately covers EVERY line and every flavour — +Collagen and the
    flavours whose protein figure we are unsure of included. The question it
    answers is "is a big sale running", not "is this good value per gram of
    whey", so it needs no protein figure to be true. The Collagen caveat is
    carried in the message instead.
    """
    return [
        v for v in variants
        if v.in_stock and _watched(v, watch) and v.discount_pct >= min_pct
    ]


def find_returns(variants: list[Variant]) -> list[Variant]:
    """Plain Cookies and Cream is currently absent from the Original line.
    Viktor wants to hear the moment it is back, at any price."""
    return [
        v for v in variants
        if v.line == "Original" and v.base_flavour.lower() == "cookies and cream"
    ]


def decide(variants, state, watch, threshold, deep_pct=DEEP_DISCOUNT_PCT,
           low_margin=NEW_LOW_MARGIN):
    """Work out what is worth saying, given what we already said.

    Returns (alerts, new_state). Four triggers, each de-duplicated on its own
    key so one can fire without silencing the others:

      deal     — at or under the £/serving Viktor actually pays
      low      — cheapest we have ever recorded for that variant
      discount — MyProtein's own displayed discount is unusually deep
      return   — plain Cookies and Cream is back in the Original line

    A deal or a discount re-announces only if it gets better; when it lapses its
    state is dropped so the next sale is announced afresh. A low is permanent —
    it only ever ratchets down.
    """
    new_state = dict(state)
    alerts: list[Alert] = []

    deals = {v.sku: v for v in find_deals(variants, watch, threshold)}
    for v in variants:
        key = str(v.sku)
        if v.sku in deals:
            previous = new_state.get(key)
            if previous is None or v.price < float(previous):
                alerts.append(Alert("deal", v))
                new_state[key] = v.price
        else:
            new_state.pop(key, None)

    # Cheapest-ever, on the comparable lines only. A first sighting seeds the
    # record silently — we have no history to call it a low against.
    for v in comparable(variants, watch):
        key = f"low:{v.sku}"
        pps = v.price_per_kg_protein
        previous = new_state.get(key)
        if previous is None:
            new_state[key] = pps
        elif pps < float(previous):
            if pps <= float(previous) * (1 - low_margin):
                alerts.append(Alert("low", v))
            new_state[key] = pps

    deep = {v.sku: v for v in find_deep_discounts(variants, watch, deep_pct)}
    for v in variants:
        key = f"disc:{v.sku}"
        if v.sku in deep:
            previous = new_state.get(key)
            if previous is None or v.price < float(previous):
                alerts.append(Alert("discount", v))
                new_state[key] = v.price
        else:
            new_state.pop(key, None)

    for v in find_returns(variants):
        key = f"return:{v.sku}"
        if key not in new_state:
            alerts.append(Alert("return", v))
            new_state[key] = v.price

    return alerts, new_state


COLLAGEN_CAVEAT = (
    " _(+Collagen line — half its 20 g protein is collagen peptides, "
    "so this is not comparable per gram of whey)_"
)

UNVERIFIED_CAVEAT = (
    " _(protein per serving is not published for this flavour, so this is a sale "
    "worth knowing about rather than a verified price per gram of protein)_"
)

# Ordered by how much they should draw the eye.
HEADERS = {
    "return": "Cookies and Cream is back",
    "deal": "Impact Whey is at your buying price",
    "low": "Cheapest we have seen it",
    "discount": "Big discount running",
}


def _detail(v: Variant) -> str:
    """The price facts. Quotes £/kg of protein only where that figure is real.

    A flavour can reach here through the big-sale trigger without a published
    protein figure. Printing an inferred £/kg for it would put back exactly the
    claim the value triggers declined to make, in the more convincing place.
    """
    size = f", {v.pack_size}" if v.pack_size else ""
    head = (f"{v.servings} servings{size} — *£{v.price:.2f}* "
            f"(was £{v.rrp:.2f}, {v.discount_pct}% off)")
    if not v.protein_verified:
        return f"{head} = *£{v.price_per_serving:.2f}/serving*"
    return (f"{head} = *£{v.price_per_kg_protein:.2f}/kg protein* "
            f"(£{v.price_per_serving:.2f}/serving at {v.whey_g_per_serving:.0f}g)")


# How many flavours to name before summarising the rest as a count. Six fits a
# Slack line; the remainder is counted rather than dropped.
MAX_FLAVOURS_NAMED = 6


def _group_key(v: Variant) -> tuple:
    """What makes two variants the same offer, differing only by flavour.

    Deliberately not the pack size string: a 150-serving tub is 4350g in one
    flavour and 4500g in another, yet it is one price and one deal. The protein
    figure is in the key because it changes £/kg — a biscuit-pieces flavour at
    the same shelf price is genuinely a different offer.
    """
    return (v.line, v.servings, round(v.price, 2), v.whey_g_per_serving)


def _flavour_list(variants: list[Variant]) -> str:
    names = list(dict.fromkeys(v.base_flavour for v in variants))
    shown = names[:MAX_FLAVOURS_NAMED]
    rest = len(names) - len(shown)
    return ", ".join(shown) + (f" +{rest} more" if rest else "")


def format_slack(alerts: list[Alert]) -> dict[str, Any]:
    lines: list[str] = []
    for kind in ("return", "deal", "low", "discount"):
        groups: dict[tuple, list[Variant]] = {}
        for a in [x for x in alerts if x.kind == kind]:
            groups.setdefault(_group_key(a.variant), []).append(a.variant)
        for members in groups.values():
            v = members[0]
            flavours = _flavour_list(members)
            if kind == "return":
                lines.append(
                    f":tada: *Cookies and Cream is back* — {v.amount} at £{v.price:.2f} "
                    f"(£{v.price_per_serving:.2f}/serving). It had been delisted from "
                    f"the Original line."
                )
            elif kind == "deal":
                lines.append(f":moneybag: *{flavours}* ({v.line}) — {_detail(v)}")
            elif kind == "low":
                lines.append(
                    f":chart_with_downwards_trend: *{flavours}* ({v.line}) "
                    f"— cheapest recorded — {_detail(v)}"
                )
            else:
                caveat = ""
                if v.line == "Collagen":
                    caveat = COLLAGEN_CAVEAT
                elif not v.protein_verified:
                    caveat = UNVERIFIED_CAVEAT
                lines.append(
                    f":fire: *{flavours}* ({v.line}) — *{v.discount_pct}% off* "
                    f"— {_detail(v)}{caveat}"
                )

    present = [k for k in ("return", "deal", "low", "discount")
               if any(a.kind == k for a in alerts)]
    header = HEADERS[present[0]] if present else ""
    return {
        "text": f"*{header}*\n" + "\n".join(lines),
        "unfurl_links": False,
    }


# How many of the cheapest variants to spell out per run. All ~90 comparable
# variants would be six screens of near-identical lines every six hours; the
# count of what is left out is printed so the listing is never mistaken for all
# of it.
LOG_CHEAPEST_N = 12


def print_scope(variants: list[Variant], watch: list[str], out=None) -> None:
    """Say what was in scope this run, and what was deliberately left out.

    Worth the lines: with every flavour in scope, "no alert" is only meaningful
    if you can see how much was actually weighed.
    """
    say = print if out is None else out
    cmp_ = sorted(comparable(variants, watch), key=lambda v: v.price_per_kg_protein)
    unverified = sorted({
        v.base_flavour for v in variants
        if v.in_stock and v.line in DEAL_LINES and not v.protein_verified
        and _watched(v, watch)
    })
    in_stock = sum(1 for v in variants if v.in_stock)

    say(f"parsed {len(variants)} variants ({in_stock} in stock); "
        f"{len(cmp_)} comparable on £/kg protein")
    shown = cmp_[:LOG_CHEAPEST_N]
    if len(cmp_) > len(shown):
        say(f"cheapest {len(shown)} of {len(cmp_)} (the rest are dearer, not skipped):")
    for v in shown:
        say(f"  {v.base_flavour} ({v.line}) {v.amount}: £{v.price:.2f} "
            f"= £{v.price_per_kg_protein:.2f}/kg protein "
            f"(£{v.price_per_serving:.3f}/serving at {v.whey_g_per_serving:.0f}g, "
            f"{v.discount_pct}% off)")
    if unverified:
        say(f"{len(unverified)} flavour(s) held out of the value triggers — protein "
            f"per serving not published for them, big-sale trigger still covers "
            f"them: {', '.join(unverified)}")


def digest_line(variants: list[Variant], watch: list[str], threshold: float) -> str:
    """One line saying the watcher is alive and where the market sits.

    Exists because this job's normal state is silence: it alerts only when a
    price qualifies, which can be months apart, so no-news was indistinguishable
    from a broken job. This posts on a schedule regardless, which is the whole
    point — it must NOT be conditional on anything being interesting.

    Read-only by construction: it takes no state and returns a string. The
    alerting run owns the dedup state, and a digest that touched it could
    swallow an alert Viktor was owed.
    """
    cmp_ = sorted(comparable(variants, watch), key=lambda v: v.price_per_kg_protein)
    in_scope = len(cmp_)
    if not cmp_:
        # Nothing priceable per gram of protein — still a heartbeat, but do not
        # invent a figure for it.
        return (f":eyes: *MyProtein watcher OK* — {len(variants)} variants parsed, "
                f"none of them comparable on protein price right now.")

    noun = "variant" if in_scope == 1 else "variants"
    best = cmp_[0]
    size = f"{best.pack_size}" if best.pack_size else f"{best.servings} servings"
    where = f"{best.base_flavour} ({best.line}), {size}, {best.discount_pct}% off"
    if best.price_per_kg_protein <= threshold:
        # A deal is live as the digest fires. Saying "nothing qualifies" here
        # would contradict the alert that went out hours earlier.
        return (f":moneybag: *MyProtein watcher OK — a deal is live* — cheapest "
                f"*£{best.price_per_kg_protein:.2f}/kg protein* ({where}), "
                f"at or under your £{threshold:.2f}. {in_scope} {noun} in scope.")
    return (f":eyes: *MyProtein watcher OK* — {in_scope} {noun} in scope, cheapest "
            f"*£{best.price_per_kg_protein:.2f}/kg protein* ({where}); "
            f"nothing at or under £{threshold:.2f}.")


def format_digest(line: str) -> dict[str, Any]:
    return {"text": line, "unfurl_links": False}


def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={
        "User-Agent": USER_AGENT,
        "Accept": "text/html,application/xhtml+xml",
        "Accept-Language": "en-GB,en;q=0.9",
    })
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read().decode("utf-8", errors="replace")


def post_slack(webhook: str, payload: dict[str, Any]) -> None:
    req = urllib.request.Request(
        webhook,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        resp.read()


# --- state -------------------------------------------------------------------
# The state is ~200 bytes, so it lives in a ConfigMap rather than a volume:
# no PV to provision, no NFS export to create out of band, and the job stays
# self-contained. A file backend is kept for local runs and dry runs.

STATE_KEY = "state.json"
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"


def state_from_configmap(api_response: dict[str, Any]) -> dict[str, Any]:
    raw = (api_response.get("data") or {}).get(STATE_KEY)
    if not raw:
        return {}
    try:
        loaded = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return loaded if isinstance(loaded, dict) else {}


def configmap_patch_body(state: dict[str, Any]) -> dict[str, Any]:
    return {"data": {STATE_KEY: json.dumps(state, sort_keys=True)}}


def _sa_read(name: str) -> str:
    with open(f"{SA_DIR}/{name}", encoding="utf-8") as fh:
        return fh.read().strip()


def _configmap_request(name: str, method: str, body: dict | None = None):
    namespace = _sa_read("namespace")
    token = _sa_read("token")
    host = os.environ.get("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc")
    port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
    url = f"https://{host}:{port}/api/v1/namespaces/{namespace}/configmaps/{name}"
    headers = {"Authorization": f"Bearer {token}"}
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/merge-patch+json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    import ssl
    ctx = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")
    with urllib.request.urlopen(req, timeout=30, context=ctx) as resp:
        return json.loads(resp.read().decode("utf-8"))


def load_state(target: str, backend: str) -> dict[str, Any]:
    if backend == "configmap":
        try:
            return state_from_configmap(_configmap_request(target, "GET"))
        except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
            print(f"state read failed ({exc}) — treating as empty", file=sys.stderr)
            return {}
    try:
        with open(target, encoding="utf-8") as fh:
            return json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_state(target: str, state: dict[str, Any], backend: str) -> None:
    if backend == "configmap":
        _configmap_request(target, "PATCH", configmap_patch_body(state))
        return
    tmp = f"{target}.tmp"
    os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=1, sort_keys=True)
    os.replace(tmp, target)


def persist_after_alert(save, target, state, backend, on_error) -> int:
    """Save state once the alert is already out, and never fail the run over it.

    Ordering matters here. post_slack() runs first because a delivered alert is
    the point of the job; state is only bookkeeping. But that means a raised
    exception at this stage would exit non-zero AFTER a successful post, and the
    Job controller would retry and post the SAME alert again — backoffLimit=2,
    so up to three copies of one deal.

    A lost state write instead costs at most a single duplicate on the next
    scheduled run, six hours later. The error is printed so a failed write is
    still visible in the logs rather than silently swallowed.
    """
    try:
        save(target, state, backend)
    except Exception as exc:                      # noqa: BLE001 - deliberately broad
        on_error(f"state write failed after alerting ({exc}) — alert WAS sent; "
                 f"the next run may repeat it")
    return 0


def main() -> int:
    url = os.environ.get(
        "MYPROTEIN_URL",
        "https://www.myprotein.com/p/sports-nutrition/impact-whey-protein-powder/10530943/",
    )
    backend = os.environ.get("STATE_BACKEND", "file")
    state_target = os.environ.get(
        "STATE_TARGET", "myprotein-watch-state" if backend == "configmap" else "/tmp/state.json"
    )
    threshold = float(os.environ.get("THRESHOLD_PER_KG_PROTEIN", "28"))
    deep_pct = int(os.environ.get("DEEP_DISCOUNT_PCT", str(DEEP_DISCOUNT_PCT)))
    low_margin = float(os.environ.get("NEW_LOW_MARGIN", str(NEW_LOW_MARGIN)))
    # Empty by default: every flavour is in scope. Set it to narrow.
    watch = os.environ.get("WATCH_FLAVOURS", "").split(",")
    dry_run = os.environ.get("DRY_RUN", "").lower() == "true"
    digest = os.environ.get("DIGEST", "").lower() == "true"
    webhook = os.environ.get("SLACK_WEBHOOK_URL", "")

    if not webhook and not dry_run:
        print("SLACK_WEBHOOK_URL is unset and DRY_RUN is not true", file=sys.stderr)
        return 2

    try:
        html = fetch(url)
    except (urllib.error.URLError, TimeoutError) as exc:
        print(f"fetch failed: {exc}", file=sys.stderr)
        return 1

    variants = parse_variants(html)
    if not variants:
        print("parsed 0 variants — the page shape probably changed", file=sys.stderr)
        return 1

    print_scope(variants, watch)

    # The digest deliberately returns before any state is read or written. It is
    # a heartbeat, not a second alerting path: sharing the dedup state would let
    # it mark a deal as "already announced" and silence the real alert.
    if digest:
        payload = format_digest(digest_line(variants, watch, threshold))
        print(payload["text"])
        if dry_run:
            print("(dry run — not posting)")
            return 0
        post_slack(webhook, payload)
        print("posted the daily digest to Slack")
        return 0

    state = load_state(state_target, backend)
    alerts, new_state = decide(variants, state, watch, threshold, deep_pct, low_margin)

    if not alerts:
        print(f"nothing at or under £{threshold:.2f}/kg protein, no new low, "
              f"nothing at {deep_pct}%+ off — no alert")
        save_state(state_target, new_state, backend)
        return 0

    payload = format_slack(alerts)
    print(payload["text"])
    if dry_run:
        print("(dry run — not posting)")
        return 0

    post_slack(webhook, payload)
    print(f"posted {len(alerts)} alert(s) to Slack")
    return persist_after_alert(save_state, state_target, new_state, backend,
                               lambda m: print(m, file=sys.stderr))


if __name__ == "__main__":
    raise SystemExit(main())
