# Deal watches (price drops on changedetection.io)

A deal watch tells you in Slack when a product's price falls below a target.
It runs on the changedetection.io that the cluster already hosts
(`stacks/changedetection/`, `https://changedetection.viktorbarzin.me`). It
needs no new service and no code per product.

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
  notification URL, so a new watch needs no notification settings of its own.
- With only `price_change_min` set, the watch is silent while the price is at
  or above the target. It posts on each change while the price is below it.
- The watch list lives in changedetection's datastore on NFS
  (`/srv/nfs/changedetection`), not in this repo. The repo is public, and a
  shopping list is personal data.

| what | where |
|---|---|
| UI | `https://changedetection.viktorbarzin.me` (Authentik) |
| API | `http://localhost:5000/api/v1/` inside the pod, header `x-api-key` |
| API key | Vault `secret/changedetection`, key `homepage_credentials`, field `.changedetection.api_key` |
| Slack webhook of the group | Vault `secret/changedetection`, key `deals_slack_webhook` |
| Datastore | NFS `/srv/nfs/changedetection` (file-based JSON) |

## Add a watch

1. Find the group UUID: `GET /api/v1/tags`, title `deals`.
2. Create the watch:

   ```json
   POST /api/v1/watch
   {
     "url": "<product page>",
     "title": "<what it is> (<shop>)",
     "processor": "restock_diff",
     "tags": ["<deals uuid>"],
     "time_between_check": {"hours": 4},
     "processor_config_restock_diff": {
       "in_stock_processing": "off",
       "follow_price_changes": true,
       "price_change_min": <target price>
     }
   }
   ```

3. Read the watch back after the first check (about 10 s):
   `processor_state_restock_diff.price` must hold today's price, and
   `last_error` must be `false`. A price of `null` means the page needs a
   filter (next section).

Run the API calls from inside the pod, for example
`kubectl -n changedetection exec -i deploy/changedetection -c changedetection -- python3 -`
with `urllib.request`. Keep checks at 4 h or longer: every check is a request
to someone else's shop.

## Shops that need settings

**Amazon UK.** Amazon has no JSON-LD price, and our egress is in Bulgaria, so
it shows EUR by default. Set both on the watch:

```json
"headers": {
  "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36",
  "Accept-Language": "en-GB",
  "Cookie": "i18n-prefs=GBP; lc-acbuk=en_GB"
},
"include_filters": ["xpath:(//div[@id='corePrice_feature_div']//span[contains(@class,'apex-pricetopay-value')]/span[contains(@class,'a-offscreen')])[1]"]
```

The page can carry two `corePrice_feature_div` blocks, one for the new offer
and one for a used offer. A CSS selector matches both, and the watch then
fails with "matched more than one price". The XPath takes the first block,
which is the new offer.

**camelcamelcamel.** It answers a plain fetch from our egress with a
Cloudflare challenge (HTTP 403), so changedetection cannot read it. Use its
own email alerts on an account.

**Pages with several products.** restock_diff reads one price per page. For
a page with many variants and per-variant rules, write a dedicated job, as
`stacks/myprotein-watch/` does.

## Troubleshooting

| symptom | cause and fix |
|---|---|
| `last_error`: "no filters were found" | The filter matched nothing. The shop changed its layout, or it served another page (a captcha, another currency). Fetch the page from the pod with the watch's headers and check the selector. |
| `last_error`: "matched more than one price" | Narrow the filter to one element, as for Amazon above. |
| Price is in the wrong currency | The shop localises by IP. Set its currency cookie or a country path in the URL. |
| No Slack post when the price fell | Check `last_notification_error` on the watch and the group's `notification_urls`. Test the URL from the pod with `apprise.Apprise().add(url)` then `.notify(...)`. |
| A watch you expected is missing | Watches with `paused: true` are skipped. Paused is a user setting, not a fault. |
