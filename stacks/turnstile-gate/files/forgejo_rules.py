"""Forgejo site rules for the Turnstile gate (ADR-0040, docs/adr/0040-site-rules-in-the-turnstile-gate.md).

Everything here is knowledge about Forgejo's own URLs and pages, kept out of
gate.py on purpose. The gate runs it only for an ingress that opts in with
`turnstile_site = "forgejo"` (middleware turnstile-gate-auth-forgejo).

The one rule, the cold filter open: a filtered issue or pull request list that
did not arrive from one of our own pages. It rests on two Forgejo facts, both
checked on 2026-11-09 against Forgejo 17:

  - Forgejo renders its list links with every filter at a default value
    (labels empty, milestone/project/assignee/poster 0), so a visitor only
    reaches a filtered list by choosing a filter on a Forgejo page.
  - Forgejo pages carry <meta name="referrer" content="same-origin">, so that
    click always sends a Forgejo Referer.

A request for a filtered list with no Referer from our sites was therefore not
clicked. The crawler that walked these lists from 2026-11-01 opened every one
of them cold, from a fresh IP, with a forged google.com Referer or none.
"""

import html
import re
import urllib.parse
from dataclasses import dataclass

COLD_FILTER_REASON = "forgejo-cold-filter"

# /<owner>/<repo>/issues or /<owner>/<repo>/pulls, the list page itself.
LIST_PATH = re.compile(r"^/(?!api/)[^/]+/[^/]+/(issues|pulls)$")

# Filters whose default Forgejo writes as "" or "0". Anything else (a label id,
# -1 for "none", a user or milestone id) means the visitor chose a filter.
ID_FILTERS = ("milestone", "project", "assignee", "poster")


@dataclass
class Refusal:
    reason: str
    body: str


def is_filtered_list(uri: str) -> bool:
    path, _, query = uri.partition("?")
    if not LIST_PATH.match(path):
        return False
    params = urllib.parse.parse_qs(query.replace("\\u0026", "&"), keep_blank_values=True)

    def first(name: str) -> str:
        return params.get(name, [""])[0].strip()

    return first("labels") != "" or any(first(name) not in ("", "0") for name in ID_FILTERS)


def cold_filter_open(uri: str, referred_by_us: bool) -> "Refusal | None":
    if referred_by_us or not is_filtered_list(uri):
        return None
    list_path = uri.partition("?")[0]
    return Refusal(COLD_FILTER_REASON,
                   PAGE.replace("__LIST__", html.escape(list_path)).replace("__VIEW__", html.escape(uri)))


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="same-origin">
<title>Open this view from the list</title>
<style>
:root{color-scheme:light dark}
body{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;max-width:36rem;margin:3rem auto;padding:0 16px;line-height:1.5;background:#fff;color:#1a1a1a}
@media (prefers-color-scheme:dark){body{background:#16181c;color:#e6e6e6}}
a{color:#2f6fdb}
</style>
</head><body><main>
<h1>Open this view from the list</h1>
<p>Filtered issue and pull request lists open from the list itself. Links to them from other sites are refused,
because crawlers request these filter combinations by the thousand.</p>
<p><a href="__LIST__">Go to the list</a> &middot; <a href="__VIEW__">Continue to this view</a></p>
</main></body></html>
"""
