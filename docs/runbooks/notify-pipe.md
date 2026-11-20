# Notify pipe

The notify pipe sends infra alerts to people on Channels they already have: Home Assistant Companion push and email. Each person picks which alert rules reach them. Design: `docs/plans/2026-11-17-notify-pipe-design.md`. Why it is built this way: ADR-0043. Terms: `GLOSSARY.md`, "Notifications".

## How it works

```
Alertmanager --every alert--> notify-adapter --u-<user>-push / -email--> apprise-api --> HA notify.mobile_app_* / SMTP
person --> notify.viktorbarzin.me (adapter :8081) --PATCH as notify-settings--> Authentik user attributes.notify
Authentik User model_updated --> Notification Rule --webhook--> apprise-api /add/notify (Channels only)
```

- `stacks/notify`: apprise-api (`caronc/apprise`, config key `notify`, on the `apprise-config` NFS volume) and `notify-adapter`: `files/adapter.py` (webhook), `files/subs.py` (Subscriptions, the Authentik and Prometheus clients), `files/page.py` (the settings page). Tests: `files/test_*.py`, run `python3 -m unittest` in `files/`.
- `stacks/notify/ingress.tf`: the page's ingress. Forward auth admits Home Server Admins and Home Users (`stacks/authentik/forward-auth-apps.json`). The ingress adds `X-Notify-Ingress-Proof`; the page refuses requests without it, so a pod that opens the Service directly cannot pose as someone.
- `stacks/authentik/notify.tf`: the service account `notify-settings` (global `view_user` and `change_user`; its token is the Secret `notify-authentik-token` in `notify`) and the push of Channels to Apprise. The renderer is `files/notify_render.py` (tests in `test_notify_render.py`).

For each alert group, the adapter reads everyone's `attributes.notify` (cached 60 s) and the alert's Prometheus rule groups (`/api/v1/rules`, cached 5 min, read again at most once a minute for an alertname it does not know). A choice on the alert rule wins over its rule group. Push and email go as two Apprise calls; the email ends with a link to the alert's page.

## Subscribe

- From Slack: every #alerts post ends with "Notify me about this". It opens https://notify.viktorbarzin.me/a/<alertname>, with the alert and its rule group.
- Everything: https://notify.viktorbarzin.me lists every alert rule by rule group, with a search box, and the Channel settings. A rule group choice also covers alert rules added to that group later.
- The phone notify service is the Companion app's `notify.mobile_app_*` service on your HA instance, without `notify.`. List them with `curl -s -H "Authorization: Bearer $(homelab ha token --instance sofia)" https://ha-sofia.viktorbarzin.me/api/services | jq -r '.[] | select(.domain=="notify") | .services | keys[]' | grep mobile_app`.
- Loki ruler alerts are not in Prometheus's rule list. A person subscribes to one through its `/a/<alertname>` link.

## Send to one person

Add `recipient: <authentik username>` to the rule's labels in `stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl`. It reaches that person's default channel and no one else. Usernames here are usually email addresses.

The Notification uses these annotations, in this order:

| | firing | resolved |
|---|---|---|
| title | `notification_title`, `summary` | `notification_resolved_title`, "Resolved: " + the firing title |
| body | `notification_body`, `description`, `summary` | `notification_resolved_body`, "This is no longer happening." |

## Check it

- Metrics: `notify_notifications_total{result="sent|failed|no_recipients|rejected"}` on the adapter. `no_recipients` is the usual result: most alerts have no subscriber. Alerts `NotifyPipeDown` and `NotifyDeliveryFailing` page on Slack #alerts, outside the pipe.
- Logs: `kubectl -n notify logs deploy/notify-adapter` prints one line per alert group with its result and tags, and one per saved settings page.
- What Apprise holds (tags only, no secrets): `kubectl -n notify exec deploy/apprise -- sh -c 'curl -s -u "$APPRISE_USER:$APPRISE_PASSWORD" "http://localhost:8000/json/urls/notify?privacy=1"'`.
- Send a test Notification without Alertmanager: the same `exec`, with `curl -s -u "$APPRISE_USER:$APPRISE_PASSWORD" -H 'Content-Type: application/json' -d '{"tag":"u-<username with symbols as ->-push","title":"Test","body":"Test"}' http://localhost:8000/notify/notify`.

## When it breaks

- `failed` with HTTP 424 in the adapter log: a Channel refused it. A wrong notify service, or an extra field in the JSON body, gives HA 400 ("Unsupported Parameters": the push URL must keep `:version`, `:type` and `:attachments`); an expired HA token gives 401 (the tokens are in Vault `secret/openclaw` -> `skill_secrets`). Apprise's own log names the URL: `kubectl -n notify logs deploy/apprise`.
- "apprise holds no channel for ..." in the adapter log: the person's settings name a Channel the renderer refused or that Apprise lost. Saving the settings page with any change rebuilds Apprise's config. If it does not, check the Authentik worker log for the `notify-apprise-config` transport (`kubectl -n authentik logs deploy/goauthentik-worker | grep -i notify`).
- The page or every alert answers "upstream unavailable" / 503: the adapter cannot reach Authentik, or the token is missing or refused. The Secret `notify-authentik-token` comes from `stacks/authentik`; apply it.
- Apprise lost its config (the volume was replaced), or the renderer changed: any User change runs the renderer again, so save any person's settings page once.
- Rotate the service account token: taint `authentik_token.notify_settings` in `stacks/authentik` and apply. Rotate the ingress proof: taint `random_password.ingress_proof` in `stacks/notify` and apply. The adapter reads both files on every call.
