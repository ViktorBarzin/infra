---
status: approved
plan: true
---

# One flow for every alert: Slack and the two emails move into the notify pipe

Today an alert reaches people by four separate paths: Slack routes picked by a `notify: page` label in code, two email routes, and the notify pipe. This plan moves all of them into the notify pipe, so each person decides on https://notify.viktorbarzin.me which alerts reach them, on any mix of Phone, Email and Slack.

## In numbers

```numbers
caption: measured on 2026-11-20 from the live Prometheus and Loki rules APIs and the Alertmanager config
rows:
  - {label: paths an alert can take to a person, before: "4 (Slack, 2 email routes, pipe)", after: "1 (the pipe), plus 6 root-cause alerts sent direct to #alerts"}
  - {label: Alertmanager receivers, before: "9", after: "3"}
  - {label: alerts listed on the page, before: "550 (Prometheus)", after: "625 (Prometheus and Loki)"}
  - {label: alerts that post to Slack because of labels in code, before: "222 (181 Prometheus, 41 Loki)", after: "0 (the same 222 become Viktor's Slack choices)"}
  - {label: Channels per choice, before: "1", after: "any of Phone, Email, Slack"}
  - {label: "services between an alert and #alerts", before: "Alertmanager", after: "Alertmanager and notify-adapter; Authentik only on a cache miss", better: false}
```

## The system, with the change on it

```topology
caption: every alert goes through the adapter; Slack is a per-person Channel like Phone and Email
direction: LR
groups:
  - {id: src, label: sources}
  - {id: pipe, label: notify pipe}
  - {id: out, label: Channels}
nodes:
  - {id: rules, label: Prometheus + Loki rules, group: src, state: same}
  - {id: am, label: Alertmanager, note: one pipe route with today's per-severity timings, group: src, state: changed, risk: high}
  - {id: ad, label: notify-adapter, note: routes every alert; posts Slack itself; snapshot on a local volume, group: pipe, state: changed, risk: high}
  - {id: page, label: settings page, note: Phone Email Slack chips; How it works page, group: pipe, state: changed, risk: medium}
  - {id: ak, label: Authentik, note: each person's choices and Slack target, group: pipe, state: same}
  - {id: ap, label: Apprise, note: Phone and Email only, group: pipe, state: same}
  - {id: phone, label: Phone (HA), group: out, state: same}
  - {id: mail, label: Email, group: out, state: same}
  - {id: slack, label: Slack, note: "#alerts for Viktor, a DM for anyone else", group: out, state: changed}
  - {id: fb, label: slack-fallback receiver, note: 6 root-cause alerts, group: src, state: new, risk: low}
  - {id: old, label: 5 Slack receivers + email-viktor + email-emo + silent, group: src, state: removed, risk: high}
edges:
  - {from: rules, to: am, state: same}
  - {from: am, to: ad, state: changed, label: every alert}
  - {from: ad, to: ap, state: same, label: tags}
  - {from: ap, to: phone, state: same}
  - {from: ap, to: mail, state: same}
  - {from: ad, to: slack, state: new, label: bot chat.postMessage}
  - {from: am, to: fb, state: new}
  - {from: fb, to: slack, state: new, label: webhook}
  - {from: page, to: ak, state: same, label: save}
  - {from: am, to: old, state: removed}
checks:
  - {node: am, text: "amtool routes test: critical, security, event, Trivy and UPS alerts reach notify-pipe with today's timings; the 6 root-cause alerts also reach slack-fallback", status: open}
  - {node: ad, text: "unit tests; the seed holds exactly the 222 paged alertnames before step 4", status: open}
  - {node: ad, text: "a synthetic critical posts to #alerts in today's format, and health check 49 still parses it", status: open}
  - {node: ad, text: "with Authentik unreachable and the pod restarted, routing uses the snapshot", status: open}
  - {node: fb, text: "NotifyPipeDown posts with the adapter scaled to zero", status: open}
left_out:
  - "Looking people up in Slack by email: the bot lacks users:read.email, so each person pastes their member ID once."
  - "A shadow week: step 3 keeps Slack sending off while the pipe computes it, and logs any difference from the old routes."
```

## Decisions

```decision
- question: Who chooses which alerts post to Slack?
  options:
    - {name: "One shared #alerts value anyone can switch", note: lost updates, no audit}
    - {name: "Per person: Viktor's Slack is #alerts, anyone else's is a DM", chosen: true}
  why: Viktor, 2026-11-20. Keeps every choice personal.
- question: What decides whether a rule posts to Slack?
  options:
    - {name: The page only; seed today's 222 once and drop the label, chosen: true}
    - {name: "The label as a default the page can override", note: two sources}
  why: Viktor, 2026-11-20.
- question: Keep today's timings (criticals re-ping every 6 h, Trivy daily, no resolved for events)?
  options:
    - {name: Keep, on every Channel, chosen: true}
    - {name: Notify once everywhere}
  why: Viktor, 2026-11-20.
- question: Move the UPS email and emo's email now?
  options:
    - {name: Both now, chosen: true}
    - {name: Slack only now}
  why: Viktor, 2026-11-20. emo's two alerts become his subscriptions, with Bulgarian notification text.
- question: Which alerts bypass the pipe?
  options:
    - {name: "6: NotifyPipeDown, NotifyDeliveryFailing, NodeDown, NFSServerUnresponsive, AuthentikDown, PowerOutage", chosen: true}
    - {name: Only the 2 pipe-health alerts}
  why: Viktor, 2026-11-20. They may arrive twice; they still arrive when the pipe is hurt.
- question: What if a critical or security alert reaches nobody?
  options:
    - {name: "One line in #alerts: it fired and reached nobody, with the link", chosen: true}
    - {name: Stay silent}
  why: Viktor, 2026-11-20. Once per alertname.
- question: How does Slack reach people?
  options:
    - {name: Through Apprise, note: puts Apprise and its NFS volume on the Slack path}
    - {name: The adapter calls chat.postMessage with the existing bot, chosen: true}
  why: Fewer parts on the path, and today's message format stays.
```

## How it works

- **Choices are lists.** A group or alert choice lists Channels, such as `["push", "slack"]`. An alert choice wins over its group; an empty list means off. Old one-word values read as one-item lists.
- **Slack target.** Each person sets a Slack member ID for DMs. A Home Server Admin may set a channel instead; Viktor's is #alerts.
- **Slack format stays.** Posts keep `[CRITICAL] Name (n)`, colours and the security layout, plus the "Notify me about this" link.
- **Delivery.** The adapter sends Slack first. A failed or rate-limited Slack post answers 503, so Alertmanager retries. A retry skips Channels that already got that notification.
- **Snapshot.** Each read of everyone's choices is saved on a small local volume. When Authentik does not answer, the adapter routes from it.
- **Safe edits.** Each changed row carries its old value; the save refuses a row someone else changed meanwhile.
- **Test** never posts to a channel, only to Phone, Email or a DM.
- **Guard.** A CI check rejects `notify: page` in rule files.

## Order of work

```timeline
caption: every step reverts with git revert and an apply; the seed stays in Authentik and only matters once step 4 routes Slack
steps:
  - {when: step 1, what: "adapter reads list values; no other change", rollback: revert}
  - {when: step 2, what: "chips, Slack target, Loki rules, snapshot, How it works page; Slack sending off", rollback: revert}
  - {when: step 3, what: "seed Viktor's 222 Slack choices, UPS email, emo's two alerts; adapter logs what it would post", rollback: clear the attributes}
  - {when: step 4, what: "Alertmanager: one pipe route, slack-fallback, old receivers and labels removed; Slack sending on", rollback: revert and apply monitoring and notify}
  - {when: step 5, what: "checks above, docs, runbook, memories", rollback: none needed}
```

## Configuration

```config
- {key: Alertmanager receivers, where: prometheus_chart_values.tpl, old: "9 (silent, notify-pipe, email-viktor, email-emo, 5 Slack)", new: "notify-pipe, notify-pipe-noresolve, slack-fallback"}
- {key: "notify: page label", where: "prometheus_chart_values.tpl (161), loki.tf (15), tests/cloud-deploy/alerts.test.yml", old: "on 176 rules", new: removed}
- {key: SLACK_BOT_TOKEN, where: stacks/notify ExternalSecret, old: absent, new: "secret/viktor slack_bot_token"}
- {key: SLACK_LIVE, where: notify-adapter env, old: absent, new: "false in steps 2-3, true in step 4"}
- {key: LOKI_URL, where: notify-adapter env, old: absent, new: "http://loki.monitoring.svc.cluster.local:3100"}
```
