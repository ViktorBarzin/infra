---
status: draft
plan: true
---

# Uptime probes for the login-free paths on pages.viktorbarzin.me

The only check on pages today, Uptime Kuma's `[External] pages`, follows the 302 to the Authentik login page and accepts any 200-499, so it watches Authentik and never reaches the learn pod; a broken `/p/`, `/c/` or `/assets/` handle would go unnoticed. This plan adds five blackbox probes against a canary Bundle and the vendored assets, alerting to Slack through the Alertmanager route that already pages for `StatusPageDown`.

## In numbers

```numbers
caption: measured 2026-11-12 from the Uptime Kuma DB and live curl against pages.viktorbarzin.me
rows:
  - {label: checks that reach the learn pod on pages, before: "0", after: "5"}
  - {label: login-free paths probed, before: "0 of 3", after: "3 of 3"}
  - {label: pages checks bound to a notifier, before: "0", after: "1 alert rule"}
  - {label: probe requests per hour, before: "12 (Kuma)", after: "162", better: false}
```

## The system, with the change on it

```topology
caption: in-cluster probes go straight to Traefik; pages.viktorbarzin.me resolves to 10.0.20.203 inside the cluster
direction: TD
groups:
  - {id: mon, label: monitoring namespace}
  - {id: edge, label: Traefik}
  - {id: learn, label: learn pod}
nodes:
  - {id: prom, label: Prometheus, note: "new job blackbox-pages-public, alert PagesPublicPathDown", group: mon, state: changed, risk: low}
  - {id: bb, label: blackbox-exporter, note: 3 new modules, group: mon, state: changed, risk: low}
  - {id: am, label: Alertmanager to slack-warning, group: mon, state: same}
  - {id: ing, label: "ingress carve-outs /assets/ /c/ /p/", group: edge, state: same}
  - {id: caddy, label: Caddy handles, group: learn, state: same}
  - {id: tree, label: git-sync tree of viktor/pages, group: learn, state: same}
  - {id: canary, label: canary Bundle, note: "wizard/pages-canary, --public --expires never", group: learn, state: new, risk: low}
  - {id: kuma, label: "Kuma [External] pages", scope: out}
  - {id: cf, label: Cloudflare edge, scope: out}
edges:
  - {from: prom, to: bb, state: new, label: /probe every 2m}
  - {from: bb, to: ing, state: new, label: HTTPS GET}
  - {from: ing, to: caddy}
  - {from: caddy, to: tree}
  - {from: tree, to: canary, state: new}
  - {from: prom, to: am, state: new, label: PagesPublicPathDown}
checks:
  - {node: prom, text: "probe_success{job=\"blackbox-pages-public\"} is 1 for all 5 targets after apply", status: open}
  - {node: bb, text: "/probe with a bogus /p/ token and with a non-shell URL each returns probe_success 0", status: open}
  - {node: canary, text: "/p/<token>/ and /c/<cap>/canary.json return pages-canary-ok with the sandbox CSP", status: open}
left_out:
  - Uptime Kuma keyword monitors
  - an outside vantage through Cloudflare
  - adding these paths to the Authentik walling-off guard
```

What each probe asserts:

| service label | URL | module | passes when |
|---|---|---|---|
| pages-assets-css | `/assets/page.css` | `http_pages_asset` | 200, no redirect, `Access-Control-Allow-Origin: *` |
| pages-assets-lib | `/assets/chart-4.6.1/chart.umd.min.js` | `http_pages_asset` | same |
| pages-public-link | `/p/<canary token>/` | `http_pages_public` | 200, CSP starts `sandbox `, CORS `*`, body has `pages-canary-ok` |
| pages-public-shell | `/p/<canary token>/` with `Sec-Fetch-Dest: document` | `http_pages_shell` | 200, body has `SANDBOX =` (the shell, not the page) |
| pages-bundle | `/c/<canary cap>/canary.json` | `http_pages_public` | as pages-public-link |

A walled-off carve-out (302 to Authentik), a missing symlink or an empty git-sync tree (404), a lost sandbox or CORS header, and a broken shell each fail a different row.

## Decisions

```decision
- question: Which tool runs the checks?
  options:
    - {name: blackbox-exporter job in Prometheus, chosen: true}
    - {name: Uptime Kuma keyword monitors, note: "not in Prometheus, cannot assert response headers, the pages monitor notifies nobody today"}
    - {name: CronJob pushing to Pushgateway, note: per-run installs and disk writes; the pattern that got status-page-pusher disabled}
  why: the exporter is already deployed in monitoring, takes headers and body regexes per module, and its alerts reach Slack.
- question: What do the /p/ and /c/ probes fetch?
  options:
    - {name: "a dedicated canary Bundle, --public --expires never", chosen: true}
    - {name: the existing pages-demo link, note: a real page that gets republished and expires 90 days after its last share}
    - {name: a bogus token expecting 404, note: proves Caddy answers but not that a link resolves}
  why: a real token is the only way to prove the symlink lookup and sandbox headers work end to end.
- question: Assert headers, or status codes only?
  options:
    - {name: "status, CSP sandbox and CORS headers", chosen: true}
    - {name: status only, note: a lost sandbox header would stay green while every page loses its isolation}
  why: the headers are what make these paths safe and usable without a login, so losing one is an outage.
- question: Where do the probes run from?
  options:
    - {name: inside the cluster, chosen: true}
    - {name: outside through Cloudflare, note: needs a host off the cluster; see open questions}
  why: every failure mode above lives in Traefik or the learn pod, and the in-cluster path tests both.
```

## Order of work

```timeline
caption: every step is undone by a revert; no data changes
steps:
  - {when: 1. canary, what: "publish wizard/pages-canary/ (index.html + canary.json) with --public --expires never; record token and cap", rollback: homelab pages unpublish pages-canary}
  - {when: 2. code, what: "stacks/monitoring: 3 modules in blackbox.yml, job blackbox-pages-public, alert PagesPublicPathDown; homelab tf plan", rollback: revert the commit}
  - {when: 3. apply, what: "homelab tf apply monitoring from the main checkout, or merge and let CI apply", rollback: revert and re-apply}
  - {when: 4. verify, what: "all 5 targets at probe_success 1; negative /probe calls return 0; alert rule loaded", rollback: n/a}
  - {when: 5. docs, what: "docs/agents/monitoring.md, the /c/ and /p/ comment block in stacks/learn/main.tf, ADR-0042 design doc", rollback: revert}
```

## Configuration

```config
- {key: modules.http_pages_asset, where: "stacks/monitoring/.../authentik_walloff_probe.tf blackbox.yml", old: "-", new: "GET, no_follow_redirects, valid_status_codes [200], fail_if_header_not_matches ACAO ^\\*$"}
- {key: modules.http_pages_public, where: same, old: "-", new: "as above + CSP ^sandbox  + fail_if_body_not_matches_regexp pages-canary-ok"}
- {key: modules.http_pages_shell, where: same, old: "-", new: "header Sec-Fetch-Dest document, [200], body SANDBOX ="}
- {key: "job blackbox-pages-public", where: prometheus_chart_values.tpl extraScrapeConfigs, old: "-", new: "5 targets, scrape_interval 2m, __param_module per target"}
- {key: alert PagesPublicPathDown, where: prometheus_chart_values.tpl alerting rules, old: "-", new: "probe_success{job=\"blackbox-pages-public\"} == 0 for 10m, severity warning, by service"}
- {key: locals.pages_canary_token / pages_canary_cap, where: monitoring module, old: "-", new: "32-hex values from step 1, plaintext: they open a page that says pages-canary-ok"}
```

The alert description names the likely cause per row: all five down means the learn pod or Traefik; only the two `/p/` rows means the link symlink; only `pages-bundle` means the cap rotated because someone republished the canary, in which case update `pages_canary_cap`.

## Open questions

- An outside vantage through Cloudflare would catch an edge cache or WAF rule on these paths. gatus already runs on mx2 for the status page; Viktor decides whether that is worth a phase 2.
- `authentik_walloff_probe.tf` asks every new carve-out to add one URL to its #security-lane guard, and the three pages carve-outs from ADR-0042 are not there. The new probes already fail on an Authentik 302; adding them there as well is Viktor's call.
- `[External] pages` keeps watching the login page. Pointing it somewhere useful is out of scope here.
- I have not confirmed that a two-file directory is published as a Bundle with a cap; step 1 settles it.

## Commands

```sh
homelab pages publish ~/pages-canary/ --public --expires never
homelab tf plan monitoring
homelab tf apply monitoring
homelab metrics query 'probe_success{job="blackbox-pages-public"}'
kubectl -n monitoring port-forward svc/blackbox-exporter 19115:9115
curl -s 'http://127.0.0.1:19115/probe?module=http_pages_public&target=https://pages.viktorbarzin.me/p/00000000000000000000000000000000/' | grep probe_success
```
