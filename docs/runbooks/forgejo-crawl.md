# Forgejo crawl

Alerts `ForgejoFilterCrawlReachingBackend` and `ForgejoExternalClientSurge`
(Loki ruler, group "Forgejo crawl" in
`stacks/monitoring/modules/monitoring/loki.tf`) fire when outside clients are
being served by the Forgejo backend itself, after the Turnstile gate and Anubis
(`stacks/turnstile-gate`) have let them through. Requests refused at the gate or
by CrowdSec do not count towards either alert.

| Alert | Counts over 6h | Fires above | Quiet baseline (2026-10-15 to 10-31) |
|---|---|---|---|
| `ForgejoFilterCrawlReachingBackend` | 200s on `/<owner>/<repo>/(issues\|pulls)?...` | 50 | 0, at most 8 |
| `ForgejoExternalClientSurge` | distinct outside addresses on any path | 300 | median 70, highest 110 |

Private, CGNAT (tailnet) and ULA sources are excluded from both.

## 1. Who is it?

Group the backend's outside traffic by user agent and path. Query a 2h window
at a time: metric queries over more than 12h of the traefik stream time out.

```sh
homelab logs query '{namespace="traefik",container="traefik"} |= "forgejo-forgejo-80@kubernetes" !~ `"ClientHost":"(10\.|192\.168\.|172\.|100\.|f[cd])`' --since 2h --limit 5000 > /tmp/fj.jsonl
python3 -c '
import json,collections,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.startswith("{")]
ua=collections.defaultdict(set)
for r in rows: ua[r.get("request_User-Agent","")[:80]].add(r["ClientHost"])
for k,v in sorted(ua.items(),key=lambda x:-len(x[1]))[:5]: print(len(v),"IPs",k)
print(collections.Counter(r["RequestPath"].split("?")[0][:50] for r in rows).most_common(8))
' /tmp/fj.jsonl
```

Many IPs sharing one user agent, each making about ten requests, is the
distributed-crawler shape. Our own tooling arrives from internal addresses and
is already excluded.

## 2. How is it getting past the gate?

The gate logs one JSON event per decision (`{namespace="turnstile-gate",container="gate"}`),
and Anubis logs its challenges in the same namespace (`container="anubis"`).
For one crawler address:

```sh
homelab logs query '{namespace="turnstile-gate"} |= "<ip>"' --since 6h --limit 50
```

| Gate event | Meaning |
|---|---|
| `decision` reason `challenge` | served the Turnstile page (403) |
| `verify_ok` | solved Turnstile; the `tsgate` pass cookie skips Anubis |
| `fallback_set` reason `no-callback-15s` / `verify-rejected` | Turnstile did not complete, so the page claimed the fallback cookie, which routes it to Anubis |
| Anubis `challenge accepted` | solved the Anubis proof of work |

Pass and fallback cookies are bound to the client's /16 (IPv4) or /48 (IPv6),
so a crawler that uses a fresh IP for every page has to solve again each time.
The 2026-11 crawler did exactly that and still got through: on 2026-11-08 it
solved Turnstile 727 times and took the Anubis fallback about 1,690 times.

## 3. Is it costing anything?

```sh
homelab metrics query 'sum(rate(container_cpu_usage_seconds_total{namespace="forgejo",container!=""}[5m]))' --since 6h --step 15m
```

For comparison, the 2026-11 filter crawl peaked at 0.24 cores and the 2026-10
commit crawl at 1.05.

## 4. Options

- **Banning addresses has nothing to act on** when each IP is used once. On
  2026-11-08 the median crawler IP lived 16s and made 11 requests, and 1 of
  1,113 fetched a second filter page. See `docs/architecture/security.md` on
  per-IP detection.
- **Refuse the request shape** at Traefik, for example by requiring sign-in
  for the crawled route, if the crawl is concentrated on one route.
- **CrowdSec manual ban** for a crawler that does reuse addresses or prefixes:
  `docs/runbooks/crowdsec-manual-bans.md`.

The alerts resolve about 6h after the crawl stops, because both count over a
6h window.
