# Goldmane Flow Trail — east-west "who-talks-to-whom" observability

> As-built runbook for the Calico Goldmane + Whisker flow plane and the
> `goldmane-edge-aggregator` durable audit trail. Design + rationale:
> [ADR-0014](../adr/0014-service-identity-and-east-west-observability.md).
> Glossary: `CONTEXT.md` → **Service identity**, **Goldmane / Whisker**.
> Implements infra issues #57 (Whisker ingress), #58 (aggregator), #61
> (monitoring), #62 (egress allowlist queries), #63 (these docs).

## What the trail is

Three layers turn raw east-west traffic into a queryable, durable record of
which Service talks to which. **Service identity = the workload's namespace**
(primary), refined by a `service-identity` label in the few multi-Service
namespaces (`monitoring`, `kube-system`, `dbaas`) — see ADR-0014.

| Layer | Component | Lifetime | Where it lives |
|---|---|---|---|
| **Live map** | Calico **Goldmane** + **Whisker** | ~60-min in-memory ring buffer (lost on Goldmane restart) | `calico-system`; Whisker UI at `whisker.viktorbarzin.me` |
| **Durable trail** | `goldmane-edge-aggregator` (`aggregate` mode) | persistent | CNPG Postgres DB `goldmane_edges`, table `edge` |
| **Notification** | `goldmane-edges-digest` CronJob (`digest` mode) | daily | Slack `#alerts` |

**Goldmane** aggregates identity-stamped flows (namespace / pod / workload /
labels + allow-deny + policy-trace) streamed from Felix (the existing
`calico-node` DaemonSet) over gRPC into a ~60-minute in-memory ring buffer —
**nothing is written to etcd or the K8s API** (the etcd-cost constraint that
drove the whole design). **Whisker** is its live web UI. Because the ring
buffer is *not* a trail (a Goldmane restart loses the window), the
`goldmane-edge-aggregator` consumes Goldmane's gRPC `Flows.Stream` API over
mTLS and upserts the unique **namespace-pair edge set** into Postgres; a daily
CronJob posts first-seen edges to Slack.

The edge set is deliberately **low-cardinality** — one row per
`(src_ns, dst_ns, action)`, *not* per-pod or per-port — so the table stays
small no matter how much traffic flows.

## Where the data lives

### Whisker UI — live, ~60 min
- `https://whisker.viktorbarzin.me` (Authentik-gated — Whisker ships no own
  login; `auth = "required"`). Shows the live flow stream + a service graph for
  roughly the last hour. Use it for "what is talking right now"; it is **not**
  history.
- In-cluster: `Service goldmane:7443` (gRPC/mTLS), `Service whisker:8081`
  (HTTP), both in `calico-system`.
- **DNS fix + self-heal:** whisker's egress to the kube-dns ClusterIP is allowed
  by `whisker-allow-dns-clusterip` (`stacks/calico`) — without it the UI goes
  empty after any gRPC-stream break (see Troubleshooting → "Whisker UI empty").
  The `whisker-watchdog` CronJob (every 10 min) is a backstop that restarts
  whisker if its backend ever wedges for another reason.

### CNPG `goldmane_edges` — durable
- Postgres DB `goldmane_edges` on the CNPG cluster
  (`pg-cluster-rw.dbaas.svc.cluster.local:5432`). One table:

  ```
  edge(src_ns text, dst_ns text, action text,
       first_seen timestamptz, last_seen timestamptz, flow_count bigint,
       PRIMARY KEY (src_ns, dst_ns, action))
  ```

  - `action` ∈ `allow` / `deny` / `pass` / `unspecified` (normalised Goldmane
    action).
  - **Self-edges (`src_ns == dst_ns`) and empty-namespace flows** (host-endpoint
    / public-internet) are **dropped** — the trail is about in-cluster service
    relationships only. (Egress to the public internet is therefore NOT in this
    table; it lives in the Wave-1 Calico flow-log path — see security.md.)
  - A **"new edge"** = a row whose `first_seen` falls inside the digest window.
  - Role `goldmane_edges` (Vault-rotated, 7-day) owns the DB. The `edge` table
    is created idempotently by the aggregator at startup (canonical DDL also in
    the repo at `migrations/0001_edge.sql`).

### Slack `#alerts` — daily digest

> **Channel note (2026-06-25):** posts to **`#alerts`**. The dedicated `#security` channel was abandoned — the shared `alertmanager_slack_api_url` incoming webhook's Slack app is not a member of it, so a channel override there returns HTTP `404 channel_not_found`. Everything now posts to `#alerts` (this digest plus alertmanager's `slack-security` receiver, which keeps its `[SECURITY]` styling so security-lane alerts still stand out there).

- CronJob `goldmane-edges-digest` (08:00 Europe/London) posts edges first seen
  in the last 24h. Quiet when there are none. Reuses the existing alert-digest
  Slack incoming webhook (Vault `secret/viktor` → `alertmanager_slack_api_url`)
  — no new webhook was created.

## How to enable / disable

### Goldmane + Whisker (the flow plane)
Operator CRs in **`stacks/calico/main.tf`** — NOT the Helm `goldmane`/`whisker`
flags (those stay `false`; the operator's own `installation`/`apiServer` are
operator-managed via the `goldmanes`/`whiskers.operator.tigera.io` CRDs):

- `kubectl_manifest.goldmane` (kind `Goldmane`) — creating it makes the operator
  re-render `calico-node` with the `FELIX_FLOWLOGSGOLDMANESERVER` env (the
  operator auto-wires Felix — **do NOT patch FelixConfiguration**), triggering a
  supervised `calico-node` DaemonSet roll. Yields `Deployment` + `Service
  goldmane:7443`.
- `kubectl_manifest.whisker` (kind `Whisker`, `depends_on` goldmane;
  `notifications = Disabled`). Yields `Deployment` + `Service whisker:8081`.

**To disable:** delete those two CRs and re-apply `stacks/calico`. Reversible
toggle (Goldmane is tech-preview in OSS Calico 3.30 — the main standing risk per
ADR-0014).

### Whisker public ingress (infra #57)
Also in `stacks/calico/main.tf`:
- `module "ingress_whisker"` (`ingress_factory`, `auth = "required"`,
  `dns_type = "proxied"`) → `whisker.viktorbarzin.me`.
- `kubernetes_network_policy_v1.whisker_allow_traefik` — **required alongside the
  ingress**: the operator's own `whisker` NetworkPolicy (owned by the Whisker CR)
  is `policyTypes: [Ingress]` with no rules = default-deny ingress to the pod.
  This additive NP ORs in an allow for `namespaceSelector
  kubernetes.io/metadata.name=traefik` on TCP 8081. Without it Traefik 502s.

### The aggregator + digest (the durable trail) — `stacks/goldmane-edge-aggregator`
A Tier-1 stack (PG state) mirroring the claude-memory pattern. `scripts/tg
apply` from `stacks/goldmane-edge-aggregator/`. It provisions: the namespace,
the mTLS client material, the Postgres DB-init Job, the `DATABASE_URL`
ExternalSecret (Vault static role `pg-goldmane-edges`), the Slack ExternalSecret,
the `aggregate` Deployment, and the `digest` CronJob. **To disable the trail
without touching the flow plane:** scale `deployment/goldmane-edge-aggregator` to
0 (transient) or remove the stack (permanent) — Goldmane/Whisker keep running.

Image: `ghcr.io/viktorbarzin/goldmane-edge-aggregator` (PRIVATE) — the
`goldmane-edge-aggregator` namespace must be in the `ghcr-credentials` Kyverno
allowlist (`stacks/kyverno/modules/kyverno/ghcr-credentials.tf`,
`local.ghcr_private_namespaces`) or pulls 401. Code repo:
`~/code/goldmane-edge-aggregator` (see its `README.md` + `DEPLOY.md`).

## mTLS cert — the REUSE decision (cert-reuse gotcha)

The aggregator dials `goldmane:7443` over **mutual TLS**. Goldmane requires the
client cert to chain to the **Tigera CA**, but it does **NOT authorize by client
identity** — any Tigera-CA-signed cert is accepted.

Rather than copy the Tigera CA **private key** into Terraform state to mint our
own cert (a needless CA-key exposure; the `hashicorp/tls` provider also clashes
with this repo's global generate-providers/lockfile pattern), the stack
**REUSES the operator-minted, Tigera-CA-signed `whisker-backend-key-pair`
Secret** (`calico-system`), copying its `tls.crt`/`tls.key` into the
`goldmane-client-tls` Secret in the aggregator namespace. The CA *bundle* that
verifies Goldmane's serving cert (`tigera-ca-bundle` ConfigMap, key
`tigera-ca-bundle.crt`) is likewise copied verbatim (a ConfigMap can't be
cross-namespace-mounted).

> **GOTCHA — if the operator rotates `whisker-backend-key-pair`, re-apply
> `stacks/goldmane-edge-aggregator`** to re-sync the copied cert. Symptom of a
> stale copy: the `aggregate` pod logs TLS handshake / `Flows.Stream` failures
> and no `last_seen` updates land in the `edge` table. Hardening follow-up
> (noted in the stack): mint an own-identity cert in-namespace if Whisker is ever
> removed (which would delete the reused source Secret).

The Deployment leaves `GOLDMANE_HOST=goldmane.calico-system.svc.cluster.local:7443`
and the default cert/CA paths; the default ServerName (host sans port) is a SAN
on Goldmane's live serving cert, so no `GOLDMANE_SERVER_NAME` /
`GOLDMANE_TLS_INSECURE` override is needed.

## How to query who-talks-to-whom

**Quickest — the `homelab edges` CLI** (the investigation helper; read-only
SELECT against the DB via the dbaas primary pod, no creds/SQL to remember):

```
homelab edges --ns <ns>         # edges touching <ns> (either direction)
homelab edges --peers-of <ns>   # <ns>'s distinct peer namespaces
homelab edges --src <ns>        # <ns>'s egress peers   (--dst <ns> for ingress)
homelab edges --new-since 24h   # edges first seen in the last day (or a date)
homelab edges --denied          # blocked / lateral-movement attempts
homelab edges --json [...]      # machine-readable, for agents/pipelines
homelab edges --help            # full flag list
```

For ad-hoc SQL, `psql` into the DB (creds: Vault static role
`static-creds/pg-goldmane-edges`, or exec a CNPG pod). All queries are against
the single `edge` table.

```sql
-- Everything talking to a namespace (inbound), most-active first
SELECT src_ns, action, flow_count, first_seen, last_seen
FROM edge WHERE dst_ns = '<ns>' ORDER BY flow_count DESC;

-- Everything a namespace talks TO (outbound)
SELECT dst_ns, action, flow_count, first_seen, last_seen
FROM edge WHERE src_ns = '<ns>' ORDER BY last_seen DESC;

-- New edges in the last 24h (what the digest reports)
SELECT src_ns, dst_ns, action, flow_count, first_seen
FROM edge WHERE first_seen > now() - interval '24 hours'
ORDER BY first_seen DESC;

-- Any DENIED edges (policy is dropping this pair)
SELECT src_ns, dst_ns, flow_count, last_seen
FROM edge WHERE action = 'deny' ORDER BY last_seen DESC;

-- Full edge set as a graph adjacency list
SELECT src_ns, dst_ns, action, flow_count FROM edge ORDER BY src_ns, dst_ns;
```

For the **live** (sub-hour) view including pod/port detail, use the Whisker UI —
the `edge` table intentionally aggregates that away.

## Deriving the Wave-1 egress allowlist from the edge table (infra #62)

The durable edge set is a faster, identity-stamped data source for the existing
**observe-then-enforce** egress effort (beads `code-8ywc`; snapshot
`docs/architecture/wave1-egress-observation-2026-05-22.md`) than the original
iptables-`LOG` → journald → Loki path (ADR-0014 consequence: "Enforcement gains
a better data source"). It replaces the *internal* (namespace-to-namespace) leg
of the allowlist; **external/public-internet egress is NOT in this table** (empty
dst namespace, dropped) — for those destinations keep using the Calico flow-log
path described in security.md.

**Per-namespace internal egress allowlist** — the set of in-cluster namespaces a
given source is *observed* talking to with `action='allow'`:

```sql
-- Internal egress allowlist for one namespace (feeds its NetworkPolicy)
SELECT DISTINCT dst_ns
FROM edge
WHERE src_ns = '<ns>' AND action = 'allow'
ORDER BY dst_ns;
```

```sql
-- Full internal egress matrix for all namespaces at once
SELECT src_ns, array_agg(DISTINCT dst_ns ORDER BY dst_ns) AS allowed_dst_ns
FROM edge
WHERE action = 'allow'
GROUP BY src_ns
ORDER BY src_ns;
```

```sql
-- Sanity: namespaces with a DENY edge already (policy is biting; investigate
-- before tightening further)
SELECT DISTINCT src_ns, dst_ns FROM edge WHERE action = 'deny';
```

**How this feeds enforcement (scope):** the derived `dst_ns` set is the
*internal* half of a namespace's egress allowlist — it tells you which
in-cluster namespaces to permit before flipping that namespace to default-deny.
The universal baseline (kube-dns :53, often dbaas :3306/:5432, redis :6379) and
the external destinations still come from the Wave-1 observation snapshot.
**Enforce-flips remain OUT OF SCOPE** here — this is observe-and-derive only;
the phased per-namespace default-deny rollout (starting `recruiter-responder`)
is tracked under `code-8ywc`. Cross-links:
[security.md → NetworkPolicy Default-Deny Egress](../architecture/security.md#networkpolicy-default-deny-egress-wave-1--observe-then-enforce-tier-34),
[wave1-egress-observation-2026-05-22.md](../architecture/wave1-egress-observation-2026-05-22.md),
[ADR-0014](../adr/0014-service-identity-and-east-west-observability.md).

> **Caveat (same as the Wave-1 snapshot):** an edge only exists if it was
> *observed*. A weekly CronJob or a 7-day Vault rotation may not have fired yet —
> collect ≥7 days of edges before treating a namespace's `allow` set as
> complete. The `first_seen` column tells you how long an edge has been known;
> the digest surfaces brand-new ones daily.

## Monitoring & health (infra #61)

The aggregator pod has **no `/metrics` endpoint** — health is inferred from
kube-state-metrics. Three complementary signals (memory ids 6598, 6599;
see also [monitoring.md → Security Alerts](../architecture/monitoring.md#security-alerts-wave-1--planned-beads-code-8ywc)):

| Signal | What | Where |
|---|---|---|
| **`AggregatorDown`** | `kube_deployment_status_replicas_available{namespace="goldmane-edge-aggregator",deployment="goldmane-edge-aggregator"} < 1` for 15m → warning | Prometheus alert group `Network Observability (Goldmane)` in `stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl`; routes `slack-warning` → `#alerts` |
| **`DigestFailing`** | `kube_job_status_failed{...job_name=~"goldmane-edges-digest.*"} > 0` within 24h, for 30m → warning | same alert group → `#alerts` |
| **cluster-health #48** | `check_goldmane_aggregator` reads the Deployment's `Available` condition (missing or not-Available → FAIL) | `scripts/cluster_healthcheck.sh` (human / `--quiet` / `--json` modes; emits `goldmane_aggregator`) |

The two alert layers are deliberately complementary: `AggregatorDown` →
**no new edges land** in the DB; `DigestFailing` → **edges still land but nobody
is told**. A freshness probe (#61b) was intentionally skipped — `AggregatorDown`
is the agreed floor.

## Troubleshooting

**Whisker UI 502 / unreachable.** The additive
`kubernetes_network_policy_v1.whisker_allow_traefik` is missing or the
operator's default-deny `whisker` NP regenerated — re-apply `stacks/calico`. A
brand-new ingress host is also invisible to LAN split-horizon until the hourly
`technitium-ingress-dns-sync` runs (memory #5349); test meanwhile with
`curl -sSI --resolve whisker.viktorbarzin.me:443:10.0.20.203 https://whisker.viktorbarzin.me`
(expect a 302 to Authentik — the gate working).

**Whisker UI empty (but reachable — 302s to Authentik fine).** ROOT CAUSE (the
2026-06-28 incident): the operator's own `whisker` NetworkPolicy is
policyTypes:[Ingress,**Egress**], and its egress allows DNS only to the kube-dns
*pods* (podSelector `k8s-app=kube-dns`). But whisker-backend resolves
`goldmane.calico-system.svc` via the kube-dns **ClusterIP** (10.96.0.10), and
**Calico drops UDP DNS to a ClusterIP under a podSelector-only egress rule**.
Verified: from the whisker pod's netns, ClusterIP DNS = 100% timeout while direct
kube-dns *pod-IP* DNS = OK, and a pod with no egress policy resolves fine.
whisker-backend resolves goldmane ONCE in the brief startup window before the
policy programs, holds its long-lived gRPC stream, and only re-resolves when that
stream breaks (e.g. a node-reboot blip) — at which point the blocked ClusterIP
DNS wedges its Go resolver (`failed to stream flows` / `code = Unavailable: dns
... i/o timeout` forever) and the UI goes blank. The durable **aggregator is a
SEPARATE pod in its own (unrestricted) namespace** and is unaffected.

FIX (applied 2026-06-28): `kubernetes_network_policy_v1.whisker_allow_dns_clusterip`
(`stacks/calico`) — an additive egress NP allowing whisker → the kube-dns
ClusterIP (`10.96.0.10/32`) on 53/UDP+TCP; k8s egress policies are additive so
the operator NP is untouched. Backstop: the `whisker-watchdog` CronJob restarts
the pod if it ever wedges for another reason. Immediate manual heal:
`kubectl -n calico-system delete pod -l k8s-app=whisker`. Diagnose by comparing,
from the whisker pod's netns, `nslookup goldmane.calico-system.svc.cluster.local
10.96.0.10` (the ClusterIP — times out if the NP fix is missing) against the same
query aimed at a kube-dns *pod IP* (always works).

**No new `last_seen` updates / `AggregatorDown` firing.** Check the `aggregate`
pod logs (`kubectl logs -n goldmane-edge-aggregator deploy/goldmane-edge-aggregator`).
Common causes, in order:
1. **Stale mTLS cert** — the operator rotated `whisker-backend-key-pair`; re-apply
   `stacks/goldmane-edge-aggregator` (see cert-reuse gotcha above). Symptom: TLS
   handshake / `Flows.Stream` errors.
2. **Stale DB password** — the 7-day Vault rotation bounced the credential but
   the pod kept the old one. The Deployment carries
   `secret.reloader.stakater.com/reload: goldmane-edges-db-creds`; if it's not
   restarting on rotation, verify the Reloader annotation and the ExternalSecret.
3. **Goldmane restarted** — the in-memory window was lost (expected); the stream
   reconnects automatically and resumes upserting. No data loss in the DB
   (only the sub-hour live window in Whisker is gone).

**Digest never posts / `DigestFailing` firing.** Inspect the most recent
`goldmane-edges-digest-*` Job (`kubectl get jobs -n goldmane-edge-aggregator`;
`kubectl logs job/<name>`). The CronJob's `ttl_seconds_after_finished=86400` GCs
pods after a day, so check soon after a failed run. With `SLACK_WEBHOOK_URL`
empty the binary forces a dry-run (no post) — verify the `goldmane-edges-slack`
ExternalSecret resolved. A dry run / smoke test: run the image with `args:
["digest"]` + `DRY_RUN=1` to print the message instead of POSTing.
> Resolved (2026-06-28): the digest posts cleanly to `#alerts`
> (`lastSuccessfulTime` current, `DigestFailing` clear; e.g. the 2026-06-28 08:00
> London run reported "8 new edges in last 24h"). The 2026-06-25 failures were
> the `#security` channel override returning HTTP 404 — the shared
> `alertmanager_slack_api_url` webhook's Slack app isn't a member of `#security`;
> consolidating all Slack output to `#alerts` fixed it.

**No edges at all in the table.** Confirm Goldmane is enabled
(`kubectl get goldmane,whisker -A`) and `calico-node` rolled with the
`FELIX_FLOWLOGSGOLDMANESERVER` env; confirm the `goldmane-edges-db-init` Job
completed; confirm the aggregator pod is `Running` and not `ImagePullBackOff`
(ghcr allowlist).

## Related
- [ADR-0014 — Service identity & east-west observability](../adr/0014-service-identity-and-east-west-observability.md)
- [security.md — NetworkPolicy Default-Deny Egress + east-west flow observability](../architecture/security.md)
- [monitoring.md — east-west flow observability + alerts](../architecture/monitoring.md)
- [wave1-egress-observation-2026-05-22.md](../architecture/wave1-egress-observation-2026-05-22.md)
- `CONTEXT.md` glossary — **Service identity**, **Goldmane / Whisker**
- Code: `~/code/goldmane-edge-aggregator` (`README.md`, `DEPLOY.md`); stacks
  `stacks/goldmane-edge-aggregator`, `stacks/calico`
