# ADR-0034: Net worth reaches the Apple Watch through a ha-sofia sensor

- Status: accepted
- Date: 2026-10-15
- Related: `stacks/wealthfolio/net_worth_to_ha.tf`, `stacks/wealthfolio/files/net_worth_to_ha.py` (with tests), `images/job-runtime/Dockerfile`, Grafana dashboard `wealth` ("Net worth (current)" tile)

## Context

Viktor wants a daily look at his net worth on his Apple Watch (Series 12, paired
with an iPhone): the total and the day's change, glanceable on the watch face.

What exists today:

- Wealthfolio holds the accounts. A pg-sync sidecar mirrors its SQLite into the
  `wealthfolio_sync` Postgres database every hour at :07, and the
  `dav_corrected` view publishes one row per account per day in GBP.
- The `wealthfolio-daily-sync` CronJob (16:00 UTC) is what creates each day's
  valuation rows. It runs after the UK close and in the middle of the US
  session, so US holdings carry an intraday price that the next day's run
  revises. Its schedule serves a "Grafana fresh by 6pm BST" target.
- Weekend rows exist and carry Friday forward (measured: -£2 on Sat 10-10,
  -£17 on Sun 10-11).
- The Grafana `wealth` dashboard is admin-only.
- Viktor's iPhone runs the Home Assistant Companion app, registered with both
  ha-sofia and ha-london. The Companion app renders watch complications from
  Jinja templates over HA entities and refreshes them roughly every 15 minutes
  while the face is showing.
- The cluster already pushes sensors into ha-sofia through `POST /api/states`
  (`tuya-bridge/saksii-poller`).

Options considered: an HA Companion complication, a daily ntfy push, and a
native watchOS app. A native app signed with a free Apple ID expires every
7 days, and keeping it running needs a paid developer account, which the
zero-cost rule rules out. A push notification does not stay on the face. The
Companion app is already installed and needs no new account.

## Decision

1. **Path.** A CronJob in the wealthfolio stack (`net-worth-to-ha`, hourly at
   :15, after the :07 mirror) reads `dav_corrected` and POSTs
   `sensor.net_worth` to ha-sofia. ha-sofia was chosen for the existing push
   pattern and its 30-day recorder.
2. **Total.** The sum, over every account in `accounts`, of its last-known
   value on the latest valuation date. This is the Grafana "Net worth
   (current)" figure. Using each account's last-known value means an account
   whose row lands late stays in the sum.
3. **Daily change.** The total on the last weekday minus the total on the
   weekday before it, both from the data. Saturday, Sunday and Monday before
   the recalc show Friday's move. A market-holiday weekday shows roughly £0
   (FX only).
4. **Snapshot timing.** Unchanged: the 16:00 UTC recalc. The watch updates at
   about 16:15 UTC.
5. **Watch face.** A Graphic Corner complication with two text lines: the
   total on the inner line, rounded (`£1.22M`), and the change on the outer
   arc (`▼£9.1k`, `▲£640` under £1k, `±£0` when flat). The sensor carries both
   strings preformatted as `total_short` and `change_short`, so the Companion
   templates only read attributes.
6. **Staleness.** When the latest valuation is more than 3 days old the change
   reads `—` and `change_color` turns grey, so an old number is not mistaken
   for today's. No separate alert.
7. **Runtime.** The job runs on `ghcr.io/viktorbarzin/job-runtime`, which
   gains `postgresql-client`, so the pod installs nothing on start. The ha-sofia
   token comes from its canonical Vault entry (`secret/openclaw`,
   `skill_secrets.home_assistant_sofia_token`) through an ExternalSecret.

### Sensor contract

`sensor.net_worth`, state = total in whole GBP, attributes:

| Attribute | Example | Meaning |
|---|---|---|
| `total_short` | `£1.22M` | Inner line of the complication |
| `change` | `-9072.63` | Daily change in GBP, `null` with fewer than two weekdays of data |
| `change_short` | `▼£9.1k` | Outer arc of the complication |
| `change_color` | `#FF3B30` | Green up, red down, grey flat or stale |
| `as_of` / `compared_to` | `2026-10-15` / `2026-10-14` | The two weekdays compared |
| `latest_valuation` | `2026-10-15` | Newest row in `dav_corrected` |
| `stale` | `false` | Latest valuation older than 3 days |

## Consequences

- The total is visible on the watch face to anyone nearby, at the rounded
  precision chosen for that reason.
- Net worth history now also lives in ha-sofia's recorder (30 days).
- A state set through `/api/states` does not survive an HA restart. The hourly
  run restores it within an hour.
- US holdings on the watch carry the 16:00 UTC intraday price, as on the
  Grafana tile.

## Open questions

- With two HA servers in the Companion app, which server a complication reads
  from is not documented. If the corner complication only offers ha-london,
  the job also pushes there.
- The HA docs describe per-line colours set in the app. Whether a line's colour
  can follow a template (to use `change_color`) is unconfirmed; the arrows
  carry the direction either way.
