---
name: file-issue
description: |
  File an issue on Forgejo viktor/infra to report something broken or request a change.
  Use when: (1) the user says "file an issue", "report a problem", "something is broken",
  (2) the user says "request a feature", "I want X deployed", "can we add X",
  (3) the user says "/file-issue" or "/report",
  (4) you hit a wall you cannot pass — a 403, a missing permission, an admin-only
      action — and the work needs someone with more access than this account has,
  (5) you detect a broken service during infra work.
  An issue labelled `broken` dispatches the fixer agent, which diagnoses and repairs
  it autonomously. An issue labelled `change` is filed for review and dispatches nothing.
author: Claude Code
version: 2.0.0
---

# File an issue on Forgejo

The tracker is **Forgejo `viktor/infra`** — `https://forgejo.viktorbarzin.me/viktor/infra`.
Not GitHub: the GitHub mirror's issue automation was retired on 2026-08-25, and
`origin` in the infra clone points at Forgejo, so `fixes #N` there refers to the
issue you filed.

## The two labels, and what each one does

| Label | Means | What happens |
|---|---|---|
| `broken` | Something is not working **right now** | **The fixer agent picks it up** — usually within a couple of minutes — diagnoses it, fixes it, pushes, watches CI, and comments on the issue as it goes. If it cannot finish, it escalates to Viktor with its findings attached. |
| `change` | A proposal; nothing is currently failing | Filed for review. Nothing is dispatched; Viktor picks it up when he gets to it. |

Choosing between them is the one judgement that matters here, so be honest about
it: **is something failing at this moment?**

- A pod crash-looping, a 502, a timeout, a service that used to work and no longer
  does, a cert that expired, a command that returns 403 when it should not →
  `broken`.
- A version bump, a new feature, a config you would prefer, a doc that should
  exist, a cleanup, a "this would be better if" → `change`.

When it is genuinely both — something is broken *and* the real fix is a larger
change — file it `broken` and say so in the body. The fixer will do what it can
and hand the remainder on.

Do not reach for `broken` to make something happen faster. A mislabelled issue
wakes an agent with cluster write for something that was not an emergency, and it
will relabel it `change` and close its run anyway.

## Step 1: Your token

Your own Forgejo PAT is already on this box, in `~/.git-credentials`:

```bash
FJ=https://forgejo.viktorbarzin.me/api/v1
TOKEN=$(grep forgejo ~/.git-credentials | head -1 | sed -E 's#https://[^:]+:([^@]+)@.*#\1#')
AUTH="Authorization: token $TOKEN"
```

That is your identity, not a shared one — the issue is authored by you, and the
fixer's trigger check requires a `viktor/infra` collaborator, which you are.

## Step 2: Gather what the fixer will need

The quality of the body decides whether the fixer succeeds or escalates. It
starts cold: it has your words, the repo, and the cluster. Give it what you
already know — you have just been looking at this, and it has not.

For something **broken**:

- **What is failing**, named precisely: service, namespace, URL, entity id
- **The evidence you already have**: the error text, the HTTP status, the log
  line, the `kubectl` output. Paste it, do not summarise it.
- **When it started**, and what changed around then if you know
- **What you already ruled out** — this is the most valuable part, because it is
  the work the fixer would otherwise repeat
- **How to check it is fixed**: the command or URL that should start working

For a **change**: what you want, where, and why — plus anything you already
checked about feasibility.

## Step 3: File it

Labels take numeric ids, not names, so resolve first:

```bash
LABEL=broken   # or: change
LID=$(curl -s -H "$AUTH" "$FJ/repos/viktor/infra/labels?limit=100" \
  | python3 -c "import sys,json;print(next(l['id'] for l in json.load(sys.stdin) if l['name']=='$LABEL'))")

curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "$FJ/repos/viktor/infra/issues" \
  -d "$(python3 - "$LID" <<'PY'
import json, sys
title = "tuya-bridge: gunicorn workers hang on Tuya Cloud calls"
body = """## Symptom
...

## Evidence
```
...
```

## Already ruled out
- ...

## Verify the fix
`curl -s https://.../healthz` should answer 200 within a second.
"""
print(json.dumps({"title": title, "body": body, "labels": [int(sys.argv[1])]}))
PY
)"
```

Write the title as the symptom, not the guess: "immich returns 502 after upload"
rather than "immich needs more memory". You may well be right about the cause —
put that in the body, where being wrong costs nothing.

## Step 4: Tell the user what happens next

Hand them the URL — `https://forgejo.viktorbarzin.me/viktor/infra/issues/<N>` —
and, for a `broken` issue, what to expect: the fixer comments on the issue as it
works, so that page is where the answer appears. They will also get Forgejo's
email on every comment, since they authored it.

## Following a run

```bash
# the conversation, including the fixer's findings
curl -s -H "$AUTH" "$FJ/repos/viktor/infra/issues/<N>/comments?limit=100" \
  | python3 -c "import sys,json;[print('---',c['user']['login'],'\n'+c['body']) for c in json.load(sys.stdin)]"
```

Labels tell you where a run is: `agent-in-progress` means it holds the issue,
`needs-human` means it handed over, and a closed issue with a resolution comment
means it landed.

**Only one fixer run happens at a time.** A second `broken` issue waits its turn
and starts when the first finishes — so "nothing has happened yet" usually means
"something else is still going", not that the trigger failed.

## The brake

If a run is doing something you did not want, add the **`paused`** label to its
issue. That stops the next dispatch for that issue immediately, with no deploy
and no cluster access needed — it works from a phone. It does not cancel a run
already in flight; tell Viktor if that is what you need.

## What the fixer will not do

Knowing this saves you filing something that can only escalate:

- **Repos other than `infra`.** An application bug (`tuya_bridge`,
  `terminal-lobby`, …) gets diagnosed and written up, then escalated. Still worth
  filing — the diagnosis is the valuable part.
- **Anything outside the cluster.** Home Assistant hosts, the Synology, routers,
  switches, access points: it will read them if it can, but it will not change
  them.
- **Destructive Terraform.** If a plan shows destroys, it stops and escalates.
