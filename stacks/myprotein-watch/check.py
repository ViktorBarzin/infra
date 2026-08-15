#!/usr/bin/env python3
"""Watch Impact Whey prices on myprotein.com and post to Slack when one of
Viktor's flavours reaches his buying price.

Why this shape: the product page ships every variant as embedded JSON
(title, flavour, amount, sku, inStock, price, rrp), so a plain HTTP GET is
enough — no browser, no login, no anti-bot surface. Prices are public.

Thresholds come from what Viktor has actually paid for Impact Whey, not from
the headline discount percentage: his three Cookies and Cream orders landed at
£0.650, £0.569 and £0.628 per serving (35-43% off RRP). A "50% off" rule would
have blocked all three, so the trigger is £/serving.

Read-only: this fetches a public page and posts a message. It never signs in,
adds to a basket, or places an order.

Config (all via env):
  SLACK_WEBHOOK_URL       required unless DRY_RUN=true
  MYPROTEIN_URL           product page to poll
  STATE_BACKEND           "configmap" (in-cluster) or "file" (local runs)
  STATE_TARGET            ConfigMap name, or file path when STATE_BACKEND=file
  THRESHOLD_PER_SERVING   £/serving at or below which a deal is worth telling
  WATCH_FLAVOURS          comma-separated flavour substrings
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

# Lines whose serving is ~23 g of whey. The +Collagen line is deliberately
# absent: half of its 20 g "protein" is collagen peptides, so its £/serving is
# not comparable and must not trip the same trigger.
DEAL_LINES = ("Original", "Milkshake")

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
    flavour = variant.base_flavour.lower()
    return any(term.strip().lower() in flavour for term in watch if term.strip())


def find_deals(variants: list[Variant], watch: list[str], threshold: float) -> list[Variant]:
    """In-stock watched flavours, on a comparable line, at or under threshold."""
    return [
        v for v in variants
        if v.in_stock
        and v.line in DEAL_LINES
        and _watched(v, watch)
        and v.price_per_serving is not None
        and v.price_per_serving <= threshold
    ]


def find_returns(variants: list[Variant]) -> list[Variant]:
    """Plain Cookies and Cream is currently absent from the Original line.
    Viktor wants to hear the moment it is back, at any price."""
    return [
        v for v in variants
        if v.line == "Original" and v.base_flavour.lower() == "cookies and cream"
    ]


def decide(variants, state, watch, threshold):
    """Work out what is worth saying, given what we already said.

    Returns (alerts, new_state). A deal re-alerts only if it gets cheaper; once
    the price climbs back over the threshold its state is dropped, so the next
    sale is announced again.
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

    for v in find_returns(variants):
        key = f"return:{v.sku}"
        if key not in new_state:
            alerts.append(Alert("return", v))
            new_state[key] = v.price

    return alerts, new_state


def format_slack(alerts: list[Alert]) -> dict[str, Any]:
    lines: list[str] = []
    for a in alerts:
        v = a.variant
        if a.kind == "return":
            lines.append(
                f":tada: *Cookies and Cream is back* — {v.amount} at £{v.price:.2f} "
                f"(£{v.price_per_serving:.2f}/serving). It had been delisted from the "
                f"Original line."
            )
        else:
            lines.append(
                f":moneybag: *{v.base_flavour}* ({v.line}) — {v.servings} servings, "
                f"{v.amount.split(' - ')[0]} — *£{v.price:.2f}* "
                f"(was £{v.rrp:.2f}, {v.discount_pct}% off) = "
                f"*£{v.price_per_serving:.2f}/serving*"
            )
    header = "Impact Whey is at your buying price" if lines else ""
    return {
        "text": f"*{header}*\n" + "\n".join(lines),
        "unfurl_links": False,
    }


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


def main() -> int:
    url = os.environ.get(
        "MYPROTEIN_URL",
        "https://www.myprotein.com/p/sports-nutrition/impact-whey-protein-powder/10530943/",
    )
    backend = os.environ.get("STATE_BACKEND", "file")
    state_target = os.environ.get(
        "STATE_TARGET", "myprotein-watch-state" if backend == "configmap" else "/tmp/state.json"
    )
    threshold = float(os.environ.get("THRESHOLD_PER_SERVING", "0.65"))
    watch = os.environ.get(
        "WATCH_FLAVOURS", "Cookies and Cream,Cookie Crumble,Banana,Strawberry Cream"
    ).split(",")
    dry_run = os.environ.get("DRY_RUN", "").lower() == "true"
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

    watched = [v for v in variants if _watched(v, watch) and v.in_stock]
    print(f"parsed {len(variants)} variants; {len(watched)} in-stock watched:")
    for v in sorted(watched, key=lambda v: v.price_per_serving or 0):
        print(f"  {v.base_flavour} ({v.line}) {v.amount}: £{v.price:.2f} "
              f"= £{v.price_per_serving:.3f}/serving ({v.discount_pct}% off)")

    state = load_state(state_target, backend)
    alerts, new_state = decide(variants, state, watch, threshold)

    if not alerts:
        print(f"nothing at or under £{threshold:.2f}/serving — no alert")
        save_state(state_target, new_state, backend)
        return 0

    payload = format_slack(alerts)
    print(payload["text"])
    if dry_run:
        print("(dry run — not posting)")
        return 0

    post_slack(webhook, payload)
    save_state(state_target, new_state, backend)
    print(f"posted {len(alerts)} alert(s) to Slack")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
