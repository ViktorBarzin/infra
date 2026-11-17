# Deal watches (price drops on changedetection.io)

A deal watch tells you in Slack when a product's price falls below a target.
It runs on the changedetection.io that the cluster already hosts
(`stacks/changedetection/`, `https://changedetection.viktorbarzin.me`). It
needs no new service and no code per product.

Anyone in the Authentik group **Deal Watchers** can say "monitor the price of
X" to their agent. `homelab how "monitor price"` sends the agent to
`homelab deals add <url>`. There is one shared list. The terms are in
`GLOSSARY.md` under "Deal watches".

## How it works

```
product page ──fetch every N h──> changedetection (restock_diff processor)
                                      │ price below price_change_min?
                                      ▼ yes
                      group "deals" notification URL ──> Slack #changenotifications
```

- Each watch uses the **restock_diff** processor ("Re-stock & Price detection"
  in the UI). It reads one price per page from JSON-LD or microdata, or from
  the element that the watch's include filter selects.
- Every deal watch belongs to the group **deals**. The group holds the Slack
  notification URL. Each watch holds its own one-line message, which names
  its target: title `{{watch_title}}`, body
  `Now {{restock.currency}}{{restock.price}}, target £35.67. {{watch_url}}`.
  changedetection resolves each notification field on its own, watch first,
  then group, then global.
- A watch title starts with the requester's Authentik short name, for
  example `[emil.barzin] ...`, so a shared channel shows who asked.
- With only `price_change_min` set, the watch is silent while the price is at
  or above the target. It posts on each change while the price is below it.
  To hear about any discount, set `price_change_min` to today's price; to
  hear only about a deep one, set it to the price you would pay.
- The watch list lives in changedetection's datastore on NFS
  (`/srv/nfs/changedetection`), not in this repo. The repo is public, and a
  shopping list is personal data.

| what | where |
|---|---|
| UI | `https://changedetection.viktorbarzin.me` (Authentik: Home Server Admins, Deal Watchers) |
| API | `https://changedetection-api.viktorbarzin.me/api/v1/` from home LANs only, header `x-api-key`; `http://localhost:5000/api/v1/` inside the pod |
| API key | Vault `secret/changedetection`, key `homepage_credentials`, field `.changedetection.api_key`; a copy for `homelab deals` at `secret/workstation/shared/deal-watches`, key `api_key` |
| Slack webhook of the group | Vault `secret/changedetection`, key `deals_slack_webhook` |
| Datastore | NFS `/srv/nfs/changedetection` (file-based JSON) |

## Add a watch

```sh
homelab deals add <product url> [--below PRICE] [--name NAME] [--every HOURS]
homelab deals list
homelab deals target <id-prefix> <price>
homelab deals remove <id-prefix|url>
```

`deals add` does these steps:

1. It picks the shop settings (next section) and cuts an Amazon link to
   `/dp/<ASIN>`. It refuses a URL that is already on the list.
2. It creates the watch muted, with a target of 0.01, so that setup never
   posts to Slack.
3. It waits for the first check, up to 150 s. If no price was read, it sets
   `fetch_backend` to `html_webdriver` (the sockpuppetbrowser sidecar) and
   checks once more. If that also reads no price, it deletes the watch and
   prints the last error. Every watch on the list has read a real price.
4. It sets the target: `--below`, or else today's price, which alerts on any
   drop. Then it unmutes the watch and sets the one-line message.
5. For Amazon, it prints Keepa's price history (below), so the agent can
   suggest a deeper target for `deals target`.

Checks run every 4 h at most, because every check is a request to someone
else's shop.

### Access

| who | how they reach the key |
|---|---|
| OIDC login in the Deal Watchers group | Vault external group `deal-watchers`, policy `deal-watchers` (`stacks/vault/main.tf`) |
| wizard on the devvm | `vault-admin` |
| emo on the devvm | `projects-emo`: a devvm periodic token carries no group, so the path is in his token policy too |

To add a member: add their `data "authentik_user"` to
`stacks/authentik/deal-watchers.tf`. If they use the devvm, add read on
`secret/data/workstation/shared/deal-watches` to the policy that their devvm
token carries, and invite them to Slack #changenotifications. The API host is
reachable from home LANs only; the API key is its only gate there.

### Keepa price history

Keepa sells its price data through a paid API, so we use neither the API nor
an account. `deals add` loads one Keepa product page
(`keepa.com/#!product/<site>-<ASIN>`, site 2 is amazon.co.uk and 3 is
amazon.de) in the cluster's real Chrome through `homelab browser run`.
Keepa blocks headless browsers ("Sorry, you have been blocked"). The page
receives the history over a websocket from `push.keepa.com`, in frames that
are JSON or zstd-compressed JSON. In the frame `basicProducts[].csv`, index 1
is the new-item price: pairs of (minutes since 2011-01-01, price in cents),
where -1 means no offer. The command prints the lowest new price over 90
days, 365 days and all time, with dates.

When that fails, it saves Keepa's public chart image instead, which needs
no browser: `https://graph.keepa.com/pricehistory.png?asin=<ASIN>&domain=co.uk&amazon=1&new=1&used=0&range=365`,
to `~/.cache/homelab/deals/`.

### By hand

The command is the supported path. To change a watch it cannot express, use
the API. The fields are those in the template below:

```json
POST /api/v1/watch
{
  "url": "<product page>",
  "title": "[<requester>] <what it is>",
  "processor": "restock_diff",
  "tags": ["<deals uuid, from GET /api/v1/tags>"],
  "time_between_check": {"hours": 4},
  "processor_config_restock_diff": {
    "in_stock_processing": "off",
    "follow_price_changes": true,
    "price_change_min": <target price>
  }
}
```

After the first check, `processor_state_restock_diff.price` must hold
today's price, and `last_error` must be `false`. `last_checked` changes when
a check starts, so wait for `check_count` to go up before you read the
result.

## Shops that need settings

**Amazon (amazon.co.uk, amazon.de).** `deals add` sets these headers and
the filter. Amazon has no JSON-LD price, and our egress is in Bulgaria, so
amazon.co.uk shows EUR by default. amazon.de uses `i18n-prefs=EUR;
lc-acbde=en_GB`. The amazon.co.uk settings are:

```json
"headers": {
  "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36",
  "Accept-Language": "en-GB",
  "Cookie": "i18n-prefs=GBP; lc-acbuk=en_GB"
},
"include_filters": ["xpath:(//div[@id='corePrice_feature_div'][not(ancestor::*[contains(@id,'used')])]//span[contains(@class,'apex-pricetopay-value')]/span[contains(@class,'a-offscreen')])[1]"]
```

The page can carry two `corePrice_feature_div` blocks, one for the new offer
(inside `newAccordionRow_0`) and one for a used offer (inside
`usedAccordionRow`). A CSS selector matches both, and the watch then fails
with "matched more than one price". The XPath skips every block inside a
`used` row and takes the first one left, so the watch reads only the price of
a new item. When Amazon lists no new offer, the filter matches nothing and the
watch errors (`DealWatchFailing`) instead of reporting a used price.

**camelcamelcamel.** It answers a plain fetch from our egress with a
Cloudflare challenge (HTTP 403), so changedetection cannot read it. Use its
own email alerts on an account.

**Other Amazon sites.** These are not in the command yet. To add one, add a
row to `amazonShops` in `cli/cmd_deals.go` with its currency cookie and Keepa
site number, then check it with a live watch.

**Pages with several products.** restock_diff reads one price per page. For
a page with many variants and per-variant rules, write a dedicated job, as
`stacks/myprotein-watch/` does.

## Alerts

changedetection posts only when a price drops, so a dead watch is silent too.
The `deal-watch-exporter` CronJob (`stacks/changedetection`, every 15 min,
script `deal_watch_exporter.py`) reads every watch in the group through the
API and pushes gauges to the Pushgateway (job `deal-watches`). It replaces the
whole group on each push, so a deleted watch drops out. Rules are in the
`Deal Watches` group of `stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl`:

| alert | fires when |
|---|---|
| `DealWatchExporterStale` | no push for 1 h: changedetection is down, the API key fails, or the push fails |
| `DealWatchExporterAbsent` | the success gauge has never existed for 1 h |
| `DealWatchNotChecked` | a watch that is not paused went 3 check intervals without a check |
| `DealWatchFailing` | a watch's `last_error` stayed set for 5 h, so it reads no price |
| `DealWatchNotificationFailing` | a watch recorded a Slack notification error |

Gauges, each labelled `uuid` and `title`: `deal_watch_last_checked_timestamp_seconds`,
`deal_watch_check_interval_seconds`, `deal_watch_check_failing`,
`deal_watch_notification_failing`, `deal_watch_paused`, `deal_watch_price`,
`deal_watch_target_price`; plus `deal_watches_total` and
`deal_watches_exporter_last_success_timestamp_seconds`. Tests:
`python3 -m pytest stacks/changedetection/test_deal_watch_exporter.py -q`.

## Troubleshooting

| symptom | cause and fix |
|---|---|
| `last_error`: "no filters were found" | The filter matched nothing. The shop changed its layout, or it served another page (a captcha, another currency). Fetch the page from the pod with the watch's headers and check the selector. |
| `last_error`: "matched more than one price" | Narrow the filter to one element, as for Amazon above. |
| Price is in the wrong currency | The shop localises by IP. Set its currency cookie or a country path in the URL. |
| No Slack post when the price fell | Check `last_notification_error` on the watch and the group's `notification_urls`. Test the URL from the pod with `apprise.Apprise().add(url)` then `.notify(...)`. |
| A watch you expected is missing | Watches with `paused: true` are skipped. Paused is a user setting, not a fault. |
