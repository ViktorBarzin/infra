---
name: cluster-health
description: |
  Personalized for emo. Check whether the homelab Kubernetes cluster is
  affecting ha-sofia or the Sofia smart-home devices it runs (Tuya devices,
  the MPPT ATS, lights, climate, security, irrigation). Use when:
  (1) "is ha-sofia ok", "are my devices / the ATS / the lights down",
  (2) "is the cluster affecting Sofia / my devices",
  (3) "check the cluster", "cluster health", "is everything running",
  (4) a device on the Барзини → Статус dashboard looks offline.
  Runs the cluster-wide healthcheck read-only and triages it by what
  ha-sofia actually depends on; the rest of the cluster is the admin's area.
author: Claude Code
version: 3.0.0-emo
date: 2026-06-26
---

# Cluster Health — personalized for emo (ha-sofia focus)

## What you actually care about

You care about **ha-sofia** and the **Sofia smart-home devices** it runs —
the Tuya devices, the **MPPT ATS**, and the lights / climate / security /
irrigation on your **Барзини → Статус** dashboard. The wider Kubernetes
cluster matters to you **only when it's breaking something ha-sofia or your
devices depend on.** Anything else is the admin's (wizard's) area — note it in
one line and move on; don't chase it.

You have **read-only** cluster access. You can SEE everything but change
nothing — so when something on your chain is broken, the job is to confirm it
and hand it off, not to repair it.

## How ha-sofia depends on the cluster

ha-sofia itself runs at the house (HAOS at https://ha-sofia.viktorbarzin.me) —
**not** in the cluster. The cluster reaches it through exactly two things:

1. **tuya-bridge** (namespace `tuya-bridge`) — the REST API ha-sofia calls for
   every Tuya device **and the MPPT ATS**. If it's unhealthy, your Tuya devices
   + ATS stop responding. **This is the #1 thing to check.**
2. **The path that carries ha-sofia ⇄ tuya-bridge and keeps ha-sofia
   reachable**: cloudflared (tunnel) → Traefik (LB) → the ingress + TLS cert
   for `tuya-bridge.viktorbarzin.me` and `ha-sofia.viktorbarzin.me`, plus
   Technitium DNS. If any of these break, ha-sofia can't reach tuya-bridge and
   you can't reach ha-sofia remotely.

Everything else in the cluster is unrelated to you unless it's hosting one of
those pods.

## Step 1 — run the healthcheck (read-only, with your HA token)

Your account can't read Vault, so load your own ha-sofia token first (it was
minted for you and lives at `~/.config/cluster-health/haos_token`). Then run
the script from YOUR clone, read-only:

```bash
cd /home/emo/code
export HOME_ASSISTANT_SOFIA_TOKEN="$(cat ~/.config/cluster-health/haos_token)"
bash scripts/cluster_healthcheck.sh --no-fix --quiet
# machine-readable instead:
# bash scripts/cluster_healthcheck.sh --no-fix --quiet --json | tee /tmp/cluster-health.json
```

- **Never pass `--fix`** — it deletes pods (a write); you're read-only and it
  will fail.
- Exit codes: `0` healthy, `1` warnings, `2` failures.

With the token exported, the **ha-sofia checks run for you**:
26 Entity Availability · 27 Integration Health · 28 Automation Status ·
29 System Resources · **45 Status Dashboard** — your Барзини → Статус view,
classifying every device tile as OK / ⚠️ / Offline across Сигурност, Мрежа &
IT, Енергия, Климат, Уреди, Мултимедия, Осветление, Поливна. Check 30 also
covers the **tuya** exporter.

## Step 2 — triage the output by relevance to YOU

Read the PASS/WARN/FAIL summary, then split the WARN/FAIL items in two:

- **On your chain → this is what matters.** Anything touching: `tuya-bridge`,
  `cloudflared`, `traefik`, DNS (check 21), the TLS cert / ingress for your two
  hosts (checks 12, 22, 31, 32), or a **node** hosting those pods — plus all the
  **ha-sofia** checks (26–29, 45) and the **tuya** exporter (30).
- **Not on your chain → one line, then drop it.** Summarise as "N unrelated
  cluster issues (admin's area)" and don't investigate.

## Step 3 — read-only checks for your chain

All of these work with your read-only access:

```bash
# tuya-bridge — your devices + the ATS
kubectl get pods -n tuya-bridge
kubectl rollout status deploy/tuya-bridge -n tuya-bridge
kubectl logs -n tuya-bridge deploy/tuya-bridge --tail=50

# the reachability path ha-sofia uses
kubectl get pods -n cloudflared
kubectl get pods -n traefik
kubectl get ingress -A | grep -Ei 'tuya-bridge|ha-sofia'

# whole external path in one shot (DNS + tunnel + Traefik + cert):
curl -sI --max-time 10 https://tuya-bridge.viktorbarzin.me | head -1
#   reachable  -> HTTP/2 200 / 401 / 403  (any HTTP response = path is up)
#   broken     -> curl: timeout / could not resolve host
```

The fastest **device-level** signal is your own dashboard: open
**https://ha-sofia.viktorbarzin.me → Барзини → Статус**. If devices show
Offline / Разкачен / ⚠️ **but tuya-bridge is healthy**, the problem is at the
house (device power / Wi-Fi / the Sofia TP-Link network) — **not** the cluster.

## Step 4 — if something on your chain is broken

You can't fix the cluster (read-only), so **capture + hand off**:

```bash
kubectl describe pod -n tuya-bridge <pod>
kubectl logs -n tuya-bridge <pod> --previous --tail=200
```

Then file it for the admin with the **`/file-issue`** skill — e.g. *"ha-sofia
Tuya devices + ATS unresponsive; tuya-bridge pod CrashLooping"* with the output
above. cloudflared / Traefik / DNS outages are cluster-wide — the admin's
alerting is already firing, but file it so it's tracked from your side too.

## What will skip for you (expected — not failures)

A few checks need access your account doesn't have. They warn/skip — that's
normal, and **none of them are on your ha-sofia chain**:

- **Uptime Kuma (14)** — needs an admin password from Vault.
- **PVE host checks** — 36 (LVM snapshots), 43 (host thermals), 44 (host load),
  and the Proxmox CSI ghost-disk check — all need root SSH to the Proxmox host.
- **`--fix`** — pod deletion (a write); not available to you.

(The ha-sofia checks are **not** in this list — your token makes them work.)

## Your ha-sofia token

- Stored at `~/.config/cluster-health/haos_token` (yours, mode 600).
- It's a **dedicated** long-lived token, named `emo-cluster-health` under
  ha-sofia → your profile → **Long-Lived Access Tokens**. Revoking it there
  affects only you.
- It currently carries admin-level HA scope (Home Assistant only lets a token
  be minted for the account that created it, and it was minted via the admin
  account). If it ever stops working, tell wizard and a fresh one can be minted.
