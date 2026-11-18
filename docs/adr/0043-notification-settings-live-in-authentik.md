# ADR-0043: Notification settings live in Authentik, and Authentik pushes them to Apprise

- Status: accepted
- Date: 2026-11-17
- Related: `docs/plans/2026-11-17-notify-pipe-design.md` (the design), `stacks/notify` (apprise-api and the adapter), `stacks/authentik/notify.tf` (the settings page and the push), `GLOSSARY.md` ("Notifications")

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
