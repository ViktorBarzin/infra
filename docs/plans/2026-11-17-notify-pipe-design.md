---
status: accepted
plan: true
---

# The notify pipe: infra events reach people on apps they already have

emo does not want to install new apps, and the Home Assistant Companion app is the only push channel on his phone. This plan adds one pipe: an alert with a Topic or a Recipient label reaches each person on HA push or email, as that person chooses on an Authentik page.

## In numbers

```numbers
caption: measured on 2026-11-17 from the repo and the live cluster
rows:
  - {label: senders that reach emo, before: "3 (one Alertmanager email route, two HA automations)", after: "every alert with a topic he subscribes to"}
  - {label: channels one alert can reach, before: "1 per receiver", after: "any of HA push or email, per person"}
  - {label: new apps on a phone, before: "0", after: "0"}
  - {label: new services, before: "0", after: "2 (apprise-api, notify-adapter)", better: false}
```

## The system, with the change on it

```topology
caption: the pipe in phase 1; Viktor is the only Recipient until he signs off the trial
direction: LR
groups:
  - {id: src, label: senders}
  - {id: notify, label: namespace notify}
  - {id: idp, label: Authentik}
  - {id: out, label: Channels}
nodes:
  - {id: am, label: Alertmanager, note: "2 routes, continue: true", group: src, state: changed, risk: medium}
  - {id: ad, label: notify-adapter, note: "alert group to Notification", group: notify, state: new, risk: low}
  - {id: ap, label: apprise-api 2.1.0, note: "config key notify, tags", group: notify, state: new, risk: medium}
  - {id: page, label: notify-settings page, note: "prompt + user_write", group: idp, state: new, risk: low}
  - {id: rule, label: Notification Rules, note: "user_write, User model_updated", group: idp, state: new, risk: medium}
  - {id: ha, label: ha-sofia / ha-london, note: "notify.mobile_app_*", group: out, state: same}
  - {id: smtp, label: mailserver, note: "as alertmanager@", group: out, state: same}
  - {id: email, label: email-emo receiver, note: "kept until phase 2", scope: out}
edges:
  - {from: am, to: ad, state: new, label: webhook}
  - {from: ad, to: ap, state: new, label: "tag topic-x or person-x"}
  - {from: page, to: rule, state: new, label: event}
  - {from: rule, to: ap, state: new, label: "/add/notify"}
  - {from: ap, to: ha, state: new}
  - {from: ap, to: smtp, state: new}
checks:
  - {node: ad, text: "25 unit tests; a test alert reaches Viktor's phone", status: open}
  - {node: rule, text: "a settings page save changes the tags Apprise holds", status: open}
  - {node: ap, text: "a direct send to person-vbarzin arrives by email", status: open}
left_out:
  - WhatsApp and iMessage (a paid business API, and a Mac we do not have)
  - household events, which stay in HA
  - issue updates, which Forgejo already emails
  - emo's own deploys and CI
  - an ingress (no v1 sender is outside the cluster)
```

## Decisions

```decision
- question: What routes a Notification to Channels?
  options:
    - {name: Apprise API, chosen: true}
    - {name: ntfy plus a bridge, note: "ntfy cannot push to HA"}
    - {name: a custom relay, note: "rebuilds what Apprise does"}
  why: maintained OSS that reaches HA push and email today
- question: How does a sender address people?
  options:
    - {name: "a Topic, or one Recipient by name", chosen: true}
    - {name: Topics only}
  why: shared services go to a Topic, a person's own things go to that person
- question: Where do the settings live?
  options:
    - {name: Authentik user attributes, chosen: true}
    - {name: a map in the notify stack, note: "an admin edits a file per change"}
    - {name: roster.yaml, note: "devvm accounts only"}
  why: people without a devvm account can be Recipients and edit their own settings
- question: Who sets a Recipient's Channels?
  options:
    - {name: the Recipient, chosen: true}
    - {name: an admin, note: "stops pointing a Channel at another phone"}
  why: Viktor accepts that risk in this household (ADR-0043)
- question: How does Apprise learn a change?
  options:
    - {name: an Authentik webhook renders and pushes the config, chosen: true}
    - {name: a 5-minute poll, note: "wasteful"}
    - {name: a sync service, note: "one more pod"}
  why: no polling and no new service; the config holds no secrets
- question: Which Channel gets a Notification?
  options:
    - {name: a choice per Topic, plus a default channel for direct sends, chosen: true}
    - {name: urgency picks it}
  why: Viktor's choice
- question: What sends outage Notifications?
  options:
    - {name: Alertmanager plus an adapter, chosen: true}
    - {name: Uptime Kuma, note: "its notification setup is outside the repo"}
  why: the rules are in Terraform
- question: Who limits repeats?
  options:
    - {name: the sender, chosen: true}
    - {name: the pipe}
  why: Alertmanager already groups and sets repeat intervals
```

## Order of work

```timeline
caption: every step reverts with a revert commit; phase 2 waits for Viktor's sign-off
steps:
  - {when: step 1, what: "stacks/notify, Alertmanager routes, topic=internet on the R730 rules", rollback: "revert; the routes are copies with continue: true"}
  - {when: step 2, what: "stacks/authentik/notify.tf: the settings page and the push", rollback: "revert; Apprise keeps its last config"}
  - {when: step 3, what: "trial: Viktor saves his settings and receives a test Notification on push and on email", rollback: "clear the settings page"}
  - {when: phase 2, what: "emo subscribes to internet himself; the R730 rules get notification_* Bulgarian text; email-emo is deleted", rollback: "restore the email-emo receiver", ponr: true}
```

## Configuration

```config
- {key: "Topic list", where: "stacks/notify/topics.json", old: "none", new: "internet"}
- {key: "Alertmanager routes", where: "prometheus_chart_values.tpl", old: "none", new: "topic or recipient label to notify-pipe, continue: true"}
- {key: "R730 uplink rule labels", where: "prometheus_chart_values.tpl", old: "notify_emo", new: "notify_emo, topic: internet"}
- {key: "Recipient settings", where: "Authentik attributes.notify", old: "none", new: "push_instance, push_service, email, default, topics.<topic>"}
- {key: "secrets in Apprise config", where: "apprise-api", old: "n/a", new: "none; APPRISE_TEMPLATE_* from Vault"}
```

The settings page is `https://authentik.viktorbarzin.me/if/flow/notify-settings/`. Each Recipient sets an HA instance and the notify service of their Companion app, an email address, a Channel for each Topic, and a default channel. A save records a `user_write` event, and the Notification Rule sends the new config to Apprise in seconds.

The adapter makes one Notification from each alert group. It reads `notification_title` and `notification_body` first, then `summary` and `description`. A resolved group gets a short "Resolved" Notification on the same Channel. A Topic with no Subscription sends nothing and counts as `no_recipients`, not as a failure.

The pipe does not report its own failure through itself. `NotifyPipeDown` and `NotifyDeliveryFailing` page on Slack #alerts. A cluster-wide outage stays with gatus on mx2.

## Commands

```sh
python3 -m unittest discover -s stacks/notify/files -p 'test_*.py'
python3 -m unittest discover -s stacks/authentik -p 'test_*.py'
homelab tf apply notify
homelab tf apply monitoring
homelab tf apply authentik
```
