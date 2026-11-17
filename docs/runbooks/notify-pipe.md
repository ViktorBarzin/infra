# Notify pipe

The notify pipe sends infra events to people on Channels they already have: Home Assistant Companion push and email. Design: `docs/plans/2026-11-17-notify-pipe-design.md`. Why it is built this way: ADR-0043. Terms: `GLOSSARY.md`, "Notifications".

## How it works

```
Alertmanager --webhook--> notify-adapter --tag--> apprise-api --> HA notify.mobile_app_* / SMTP
Authentik settings page --user_write--> Notification Rule --webhook--> apprise-api /add/notify
```

- `stacks/notify`: apprise-api (`caronc/apprise`, config key `notify`, on the `apprise-config` NFS volume) and `notify-adapter` (`files/adapter.py`, tests in `files/test_adapter.py`).
- `stacks/authentik/notify.tf`: the settings page and the push. The renderer is `files/notify_render.py` (tests in `test_notify_render.py`).
- Topics: `stacks/notify/topics.json`. Today: `internet` (the R730 uplink alerts).

## Send to a Topic or a Recipient

Add a label to an Alertmanager rule in `stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl`:

- `topic: <name>` reaches everyone subscribed to that Topic. The name must be in `topics.json`, or the adapter rejects the alert.
- `recipient: <authentik username>` reaches that person's default channel.

The pipe is an extra copy: the alert still follows its other routes. The Notification uses these annotations, in this order:

| | firing | resolved |
|---|---|---|
| title | `notification_title`, `summary` | `notification_resolved_title`, "Resolved: " + the firing title |
| body | `notification_body`, `description`, `summary` | `notification_resolved_body`, "This is no longer happening." |

A new Topic: add it to `topics.json` in the same commit as its first rule, then apply `notify` and `authentik` (the settings page gets a field for it).

## Change your settings

Open https://authentik.viktorbarzin.me/if/flow/notify-settings/. The phone notify service is the Companion app's `notify.mobile_app_*` service on your HA instance, without `notify.`. List them with `curl -s -H "Authorization: Bearer $(homelab ha token --instance sofia)" https://ha-sofia.viktorbarzin.me/api/services | jq -r '.[] | select(.domain=="notify") | .services | keys[]' | grep mobile_app`.

## Check it

- Metrics: `notify_notifications_total{result="sent|failed|no_recipients|rejected"}` on the adapter. Alerts `NotifyPipeDown` and `NotifyDeliveryFailing` page on Slack #alerts, outside the pipe.
- Logs: `kubectl -n notify logs deploy/notify-adapter` prints one line per alert group with its result and tag.
- What Apprise holds (tags only, no secrets): `kubectl -n notify exec deploy/apprise -- sh -c 'curl -s -u "$APPRISE_USER:$APPRISE_PASSWORD" "http://localhost:8000/json/urls/notify?privacy=1"'`.
- Send a test Notification without Alertmanager: the same `exec`, with `curl -s -u "$APPRISE_USER:$APPRISE_PASSWORD" -H 'Content-Type: application/json' -d '{"tag":"person-<username>","title":"Test","body":"Test"}' http://localhost:8000/notify/notify`.

## When it breaks

- `failed` with HTTP 424 in the adapter log: a Channel refused it. A wrong notify service gives HA 400; an expired HA token gives 401 (the tokens are in Vault `secret/openclaw` -> `skill_secrets`). Apprise's own log names the URL: `kubectl -n notify logs deploy/apprise`.
- `no_recipients` for a Topic someone did subscribe to: Apprise does not hold their Channel. The config is rebuilt on the next User change: save the settings page again. If that does not help, check the Authentik worker log for the `notify-apprise-config` transport (`kubectl -n authentik logs deploy/goauthentik-worker | grep -i notify`).
- Apprise lost its config (the volume was replaced): save any Recipient's settings page once.
