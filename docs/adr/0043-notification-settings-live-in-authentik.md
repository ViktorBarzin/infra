# ADR-0043: Notification settings live in Authentik, and Authentik pushes them to Apprise

- Status: accepted, revised twice on 2026-11-20 (see the two "Revision" sections)
- Date: 2026-11-17
- Related: `docs/plans/2026-11-17-notify-pipe-design.md` (the design), `stacks/notify` (apprise-api, the adapter and the settings page), `stacks/authentik/notify.tf` (the service account and the push), `GLOSSARY.md` ("Notifications")

## Context

emo does not want to install new apps. The Home Assistant Companion app is the only push channel on his phone, and email is the other. Before this, Alertmanager emailed him directly for two R730 uplink alerts (the `email-emo` receiver), and nothing else from the cluster reached him. No code sent one event to several channels.

The pipe needs per-person settings: which Channels a Recipient has, which Topics they want and on which Channel. Four places could hold them: a map in the notify stack, `roster.yaml` (devvm accounts only, today two people), Authentik user attributes, or a database of a new service.

## Decision

1. **Settings are Authentik user attributes under `attributes.notify`**, edited by each Recipient on a self-service page (`/if/flow/notify-settings/`): a prompt stage and a never-create user_write stage. Recipients need no devvm account, and nobody edits a file to subscribe.
2. **Channels are self-service too**, including the HA instance and the notify service. Viktor chose this over admin-set Channels. The renderer limits a Channel to the two HA hosts and a `[a-z0-9_]+` service name, and an email address to a plain address, so a value cannot change the rest of the URL.
3. **Authentik pushes; nothing polls.** Notification Rules on `user_write` and on User `model_updated` call a webhook transport. Its body mapping (`files/notify_render.py`) renders the Apprise config of every Recipient and POSTs it to apprise-api `/add/notify`, which replaces the stored config. Admin edits record no `user_write`, so the `model_updated` rule catches them. Other User saves, such as logins, also fire it; each one rewrites the same config.
4. **The rendered config holds no secrets.** HA tokens and the SMTP password are Apprise template values (`${ha_sofia_token}`), filled from apprise-api's `APPRISE_TEMPLATE_*` environment, which an ExternalSecret reads from Vault.

## Consequences

- Anyone who can sign in to Authentik can point their push Channel at another person's phone, by naming that phone's notify service on the same HA instance. In this household that is accepted. A stricter design would move Channels to the admin side.
- A config change reaches Apprise within seconds of a save. If Apprise loses its stored config, it comes back on the next User change. The config lives on a small NFS volume, so a pod restart keeps it.
- The renderer is a Python expression inside Authentik. Its tests run it against fake users (`test_notify_render.py`), but a mistake shows only when Authentik runs it: the webhook then fails and Apprise keeps the previous config.
- Each Recipient's list of Topics is limited to the fixed list in `stacks/notify/topics.json`; a new Topic is a commit that adds it next to its first sender.

## Revision 2026-11-20: subscribe to alert rules, on a page of our own

Viktor wanted an inventory of every alert and the easiest way to subscribe to new ones. A fixed Topic list could not give that: every new Topic was a commit. What changed:

1. **Subscriptions name alert rules and Prometheus rule groups**, not Topics. The adapter reads the rule groups from Prometheus's rules API, so no rule needs a new label, and a rule group choice covers rules added to it later. A choice on an alert rule wins over its rule group. Topics and `topics.json` are gone.
2. **The settings page moved out of Authentik's flow executor** to https://notify.viktorbarzin.me, served by the adapter behind forward auth. A prompt stage cannot search or show 550 rows. Every Slack post links to the page of its alert.
3. **Settings still live in Authentik attributes.** The page writes them through a service account, `notify-settings`, whose role holds global `view_user` and `change_user`. That token can edit any account through the API. Viktor chose this over moving the settings to a store of the notify stack, which would have kept such a token out of the cluster. The token is mounted only into the adapter pod, and the page writes only the signed-in person's `notify` key.
4. **The adapter routes; Apprise only holds Channels.** The renderer tags each Channel `u-<username>-push` or `u-<username>-email`, and the adapter picks the tags for each alert from everyone's attributes. The `user_write` rule went with the flow; the `model_updated` rule catches the page's saves. That rule never fired before this revision: its matcher also required `app = authentik.core`, and a `model_updated` event's app is `authentik.events.middleware`. Every sync until then came from `user_write`.

Consequence: alert routing now also depends on Authentik answering. When it does not, the adapter answers 503 and Alertmanager retries.

## Revision 2026-11-20 (2): one flow for every alert

Viktor asked for one flow for alerts, fully configurable on the page (`docs/plans/2026-11-20-notify-one-flow-design.md`). What changed:

1. **Every alert goes through the pipe.** The five Slack receivers, `email-viktor`, `email-emo` and `silent` are gone. The `notify: page` label is retired, and `scripts/check-no-notify-page.py` rejects it. Today's 222 paged alerts became Viktor's Slack choices; his UPS email and emo's two R730 alerts became their choices.
2. **Choices are lists of Channels**, so one alert can go to Phone, Email and Slack at once. Old single words still read.
3. **Slack is a per-person Channel**, chosen by Viktor over one shared #alerts switch. A person's Slack is a DM from the homelab bot; a Home Server Admin may name a channel instead, and Viktor's is #alerts. The adapter posts it itself, in the old Alertmanager layout, so Apprise and its NFS volume are not on the Slack path.
4. **Safety nets**, after two challenger reviews: six root-cause alerts also go straight to #alerts; a failed send makes Alertmanager retry without repeating what went out; routing falls back to a snapshot on a local encrypted volume when Authentik does not answer; a critical or security alert that reaches nobody posts one line to #alerts.

Consequences: a Slack post now depends on the adapter as well as Alertmanager. The fallback receiver, `NotifyPipeDown` and `NotifyDeliveryFailing` cover that. A new rule reaches nobody until someone switches it on, unless it is critical or security, which reports itself once.

