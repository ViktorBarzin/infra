# Notify pipe

The notify pipe is the only way an alert reaches a person. Every alert goes from Alertmanager to the notify adapter, which sends it to the people who chose it, on Phone (Home Assistant Companion push), Email or Slack. Designs: `docs/plans/2026-11-17-notify-pipe-design.md` and `docs/plans/2026-11-20-notify-one-flow-design.md`. Why it is built this way: ADR-0043. Terms: `GLOSSARY.md`, "Notifications". The settings page has a "How it works" page with the diagram: https://notify.viktorbarzin.me/how.

## How it works

```
Alertmanager --every alert--> notify-adapter --u-<user>-push / -email--> apprise-api --> HA notify.mobile_app_* / SMTP
                                    \--chat.postMessage (bot)--> Slack: a DM, or #alerts for Viktor
Alertmanager --6 root-cause alerts--> slack-fallback --webhook--> #alerts
person --> notify.viktorbarzin.me (adapter :8081) --PATCH as notify-settings--> Authentik user attributes.notify
Authentik User model_updated --> Notification Rule --webhook--> apprise-api /add/notify (Phone and Email only)
```

- `stacks/notify/files`: `adapter.py` (webhook and delivery), `subs.py` (choices, the Authentik and rules-API clients), `slack.py` (Slack posts), `page.py` (the settings page), `preview.py` (test notifications). Tests: `test_*.py`; run `python3 -m unittest` in that folder.
- `stacks/notify/ingress.tf`: the page's ingress. Forward auth admits Home Server Admins and Home Users. The ingress adds `X-Notify-Ingress-Proof`; the page refuses requests without it.
- `stacks/notify/main.tf`: the Slack bot token (ExternalSecret `notify-slack`, from `secret/viktor` `slack_bot_token`), the state volume `notify-adapter-state` (proxmox-lvm-encrypted), and `SLACK_LIVE`.
- `stacks/authentik/notify.tf`: the service account `notify-settings` (global `view_user` and `change_user`; token in the Secret `notify-authentik-token`) and the push of Phone and Email Channels to Apprise. Renderer: `files/notify_render.py`.
- Alertmanager (`stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl`): receivers `notify-pipe`, `notify-pipe-noresolve` (event lane) and `slack-fallback`. The child routes only set timings: security 10s/1m/1h, event no resolved, Trivy 30m/24h, `UPSOnBatteryEmail` every 10m, critical re-ping every 6h, info 5m/30m.

## What a person chooses

Each person's `attributes.notify` holds their Channels (`push_instance`, `push_service`, `email`, `slack_target`), and their choices as lists of Channels: `default` (sent to them by name), `groups` (rule group name -> list) and `alerts` (alertname -> list, `[]` for off). A choice on an alert wins over its groups. The inventory is every alerting rule in Prometheus's and Loki's rules APIs; groups with the same name merge.

- `slack_target` is a Slack member ID (a DM from the bot "claude"), or, for a Home Server Admin, a channel such as `#alerts`. The bot lacks `users:read.email`, so people paste their member ID once.
- The page sends only the rows that changed, with the value it showed. A save of a row someone changed meanwhile is refused (409) and asks for a reload.
- Each save logs the person and the before and after values: `kubectl -n notify logs deploy/notify-adapter | grep "save by"`.

## Delivery and retries

- The adapter sends Slack first, then Phone, then Email. A send that may work later (Slack rate limit, Apprise or Authentik down) answers 503 and Alertmanager sends the group again. Sends that already went out for that notification are skipped on the retry, for an hour.
- A permanent refusal (a wrong HA service, a Slack `channel_not_found`, an Apprise tag that is missing) counts as `failed` and fires `NotifyDeliveryFailing`.
- When Authentik does not answer, routing uses the last read of everyone's settings: in memory, else `/state/subscribers.json` (mode 0600). The gauge `notify_snapshot_in_use` is 1 while it does.
- A critical or security alert that reaches nobody posts one line to `#alerts`, once per alertname (`/state/unrouted.json`).
- `NotifyPipeDown`, `NotifyDeliveryFailing`, `NodeDown`, `NFSServerUnresponsive`, `AuthentikDown` and `PowerOutage` also post straight to #alerts through `slack-fallback`, so they appear twice while the pipe works.

## Add an alert rule

Write the rule as usual, without any routing label: `scripts/check-no-notify-page.py` fails a stack that still uses `notify: page`. Then switch it on for the people who need it at https://notify.viktorbarzin.me/a/<alertname>. For a rule meant for one person, add `recipient: <authentik username>`: it reaches that person's default Channels and nobody else. The Notification uses these annotations, in this order:

| | firing | resolved |
|---|---|---|
| title | `notification_title`, `summary` | `notification_resolved_title`, "Resolved: " + the firing title |
| body | `notification_body`, `description`, `summary` | `notification_resolved_body`, "This is no longer happening." |

Slack posts keep the old Alertmanager layout and use `summary` (and, in the security lane, `description` and `runbook`).

## Test an alert

Each row's **Test** button sends the signed-in person one Notification built like a real one, with "Test: " in front of the title, on the row's Channels. A test never posts into a Slack channel, only to a DM. The values come from the best source available (`files/preview.py`): the alert firing now; the rule evaluated at the last time `ALERTS` shows it firing, within 26 weeks; for a plain `A > N` rule, A's current series and a value past N; else label values from the rule's metrics. Six tests a minute per person.

## Check it

- Metrics: `notify_notifications_total{result}`, `notify_deliveries_total{channel,result}` (channel push, email, slack, unrouted; result sent, failed, unavailable, skipped), `notify_snapshot_in_use`.
- Logs: `kubectl -n notify logs deploy/notify-adapter` prints one line per alert group with its targets, and one per Slack, Apprise or Authentik problem.
- What Apprise holds (tags only): `kubectl -n notify exec deploy/apprise -- sh -c 'curl -s -u "$APPRISE_USER:$APPRISE_PASSWORD" "http://localhost:8000/json/urls/notify?privacy=1"'`.
- Before a risky change, set `slack_live = "false"` in `stacks/notify/main.tf`: the adapter then logs `slack shadow: would post ...` and posts nothing to Slack.

## When it breaks

- `NotifyPipeDown` or `NotifyDeliveryFailing` in #alerts (they arrive through `slack-fallback`): check the adapter log first.
- `failed` with HTTP 424 from Apprise: a Phone or Email Channel refused it. HA 400 means an extra JSON field (the push URL must keep `:version`, `:type` and `:attachments`); 401 means an expired HA token (`secret/openclaw` -> `skill_secrets`).
- "apprise holds no channel for ...": Apprise lost or never got that person's Channel. Any User change runs the renderer again: save the person's settings page once. If that does not help, check the Authentik worker log for `notify-apprise-config`.
- Slack `not_in_channel` or `channel_not_found`: the target is wrong, or the channel is private and the bot is not in it.
- 503 to every alert and no snapshot: Authentik is down and the adapter has never read anyone. The six fallback alerts still post.
- Rotate the Authentik token: taint `authentik_token.notify_settings` in `stacks/authentik`. Rotate the ingress proof: taint `random_password.ingress_proof` in `stacks/notify`. The Slack token follows Vault through the ExternalSecret. The adapter reads all three files on every call.
