#!/usr/bin/env python3
"""Pure pool logic for the proxy shared per-country NordVPN gateway model.

NO kubernetes / network I/O lives here — only the *decisions* the broker makes,
so they can be unit-tested in isolation (pool_test.py; the watchdog.py/
watchdog_test.py split from infra#80 is the precedent). broker.py owns all I/O
(apiserver calls, `wg` key generation, `iptables`/`ip rule` on the gateway) and
calls these functions for every decision.

Model (validated end-to-end by Spike G, memory #10214): one **gateway** pod per
active country holds the single NordVPN WireGuard tunnel for that country and
FORWARDS many **browser** pods' traffic out through it (browsers join over
WireGuard, leak-proof via gluetun's kill-switch). The NordVPN ~10-tunnel account
cap therefore limits concurrent *countries* (MAX_COUNTRIES, minus RESERVED_SLOTS
kept free for Viktor's own devices), NOT users — browsers per country are
unbounded (bounded only by the /24 client subnet and cluster resources).

Each gateway owns a /24 carved from 10.13.0.0/16: gateway index i => client
subnet 10.13.i.0/24, gateway itself at 10.13.i.1, browsers at 10.13.i.2 ..
10.13.i.254. Indexes 1..254 (i=0 reserved: 10.13.0.0/24 unused), of which
PERMANENT_IDX belongs to the always-on cluster VPN egress gateway below and is
never leased to an on-demand one.
"""

# ---- account/tunnel budget (NordVPN ~10 concurrent tunnels, memory #10182) ----
MAX_COUNTRIES = 8      # concurrent country gateways (each = one NordVPN tunnel)
RESERVED_SLOTS = 2     # tunnels kept free for Viktor's own NordVPN devices
GW_SUBNET_PREFIX = "10.13"
MIN_SUBNET_IDX = 1
MAX_SUBNET_IDX = 254

# ---- the permanent, Terraform-declared gateway (cluster VPN egress) ----
# One always-on gateway serves BOTH products: the WireGuard sidecar the browsers
# join (Service proxy-gw-1, UDP 51820) and gluetun's own HTTP/SOCKS5 proxy
# listeners any cluster workload can point HTTPS_PROXY at (Service
# proxy-egress-uk, TCP 8888/1080). It occupies one of the existing
# MAX_COUNTRIES slots — the budget above is deliberately unchanged.
# Terraform owns its Deployment, Services and Secret, so the broker must never
# allocate, re-create or reap this index. The country string is matched
# byte-for-byte against the offered-countries list in broker.py.
PERMANENT_IDX = 1
PERMANENT_COUNTRY = "United Kingdom"


def normalize_country(country, allowed):
    """Return the canonical country name or None if not offered."""
    if not country:
        return None
    for c in allowed:
        if c.lower() == country.strip().lower():
            return c
    return None


def alloc_subnet_idx(used_idxs):
    """Lowest free /24 index in [1,254], never PERMANENT_IDX; raises if exhausted.

    PERMANENT_IDX counts as permanently used rather than being filtered out by the
    caller: the permanent gateway is a Deployment, so during a rollout (or any
    window where its pod carries a deletionTimestamp) it is absent from
    list_gateways() and its index would never reach `used_idxs`. Reserving it here
    means an on-demand gateway can never be handed the Terraform-owned
    proxy-gw-1 Service/Secret/ConfigMap names, whatever the caller passes.
    """
    used = set(used_idxs) | {PERMANENT_IDX}
    for i in range(MIN_SUBNET_IDX, MAX_SUBNET_IDX + 1):
        if i not in used:
            return i
    raise RuntimeError("gateway subnet space exhausted")


def gateway_subnet(idx):
    return "%s.%d.0/24" % (GW_SUBNET_PREFIX, idx)


def gateway_ip(idx):
    return "%s.%d.1" % (GW_SUBNET_PREFIX, idx)


def alloc_client_ip(idx, used_ips):
    """Lowest free browser IP (.2..254) in gateway `idx`'s /24."""
    used = set(used_ips)
    for host in range(2, 255):
        ip = "%s.%d.%d" % (GW_SUBNET_PREFIX, idx, host)
        if ip not in used:
            return ip
    raise RuntimeError("client subnet %s exhausted" % gateway_subnet(idx))


def plan_gateway(country, gateways, max_countries=MAX_COUNTRIES,
                 reserved=RESERVED_SLOTS):
    """Decide how a browser request for `country` is served.

    `gateways` is a list of dicts each with at least {"country", "idx"}.
    Returns one of:
      ("reuse",  {"idx": i})                  -- a gateway for this country exists
      ("create", {"idx": i, "subnet": s, ...}) -- room to start a new one
      ("reject", {"reason": str})              -- at the concurrent-country cap
    One gateway per distinct country is a hard invariant (same NordLynx key on two
    tunnels to the same country flaps, memory #10214); reuse always wins.

    PERMANENT_COUNTRY short-circuits to PERMANENT_IDX *before* the listed-gateway
    scan and before the capacity check, for two reasons: the permanent gateway's
    identity comes from Terraform rather than from a listed pod (so during a
    rollout the scan would fall through to "create" and start a SECOND tunnel to
    the same country on the account-wide NordLynx key), and its tunnel is already
    running, so serving one more browser from it costs no additional NordVPN slot.

    That short-circuit deliberately says nothing about whether the gateway is
    RUNNING — "reuse" here means "this country is served by index 1, never create
    another". Liveness is not knowable from these arguments (the pod is absent
    from `gateways` during any rollout), so the broker checks it: ensure_gateway
    requires a Ready pod at PERMANENT_IDX before handing the index to a browser,
    and fails with a retryable error otherwise. Reading this function alone, it
    looks like a browser could be wired to a gateway that is not running; that
    check is what prevents it.

    Capacity is counted as `len(gateways)`, i.e. from the pods that are listed. A
    rollout of the permanent gateway therefore leaves the count one low for a few
    seconds, which can admit one on-demand country over budget; that transient is
    still well inside the ~10-tunnel account cap, so it is left as-is rather than
    hard-coding the permanent slot into the arithmetic.
    """
    if country == PERMANENT_COUNTRY:
        return ("reuse", {"idx": PERMANENT_IDX})
    for gw in gateways:
        if gw.get("country") == country:
            return ("reuse", {"idx": gw["idx"]})
    budget = max(0, max_countries - reserved)
    if len(gateways) >= budget:
        return ("reject", {
            "reason": "at capacity: %d/%d country tunnels in use "
                      "(%d reserved for personal use)" % (
                          len(gateways), max_countries, reserved),
        })
    idx = alloc_subnet_idx([gw["idx"] for gw in gateways])
    return ("create", {"idx": idx, "subnet": gateway_subnet(idx),
                       "gateway_ip": gateway_ip(idx)})


def plan_reaping(gateways, browsers, now, gw_idle_seconds):
    """Return (gateway_idxs_to_reap, browser_ids_to_reap).

    A gateway is reaped once it has carried NO browsers for `gw_idle_seconds`
    (freeing its NordVPN tunnel slot); `browsers` reaping is the pod's own
    lifecycle (expired/failed), passed in as already-decided ids here so the
    caller keeps the k8s status read.  `gateways`: [{"idx","last_used"}];
    `browsers`: [{"id","gateway_idx","dead"}].

    PERMANENT_IDX is never reaped: it is always-on by design, and its `last_used`
    would read 0 anyway (nothing patches a Deployment pod's annotation), which
    satisfies any idle test on the very first tick.
    """
    dead_browsers = [b["id"] for b in browsers if b.get("dead")]
    live_by_gw = {}
    for b in browsers:
        if not b.get("dead"):
            live_by_gw.setdefault(b.get("gateway_idx"), 0)
            live_by_gw[b["gateway_idx"]] += 1
    dead_gws = []
    for gw in gateways:
        if gw["idx"] == PERMANENT_IDX:
            continue
        has_live = live_by_gw.get(gw["idx"], 0) > 0
        idle_for = now - gw.get("last_used", now)
        if not has_live and idle_for >= gw_idle_seconds:
            dead_gws.append(gw["idx"])
    return (dead_gws, dead_browsers)


def plan_stranded_browsers(browsers, gateways, missing_streak, required_streak=3):
    """Return (browser_ids_to_rehome, new_missing_streak) for live browsers whose
    gateway can no longer serve them.

    plan_reaping walks gateways, never browsers, so a browser pointing at a
    gateway that went away outside delete_gateway (a reap interrupted mid-sequence,
    an eviction, a node drain) is not a case it has: the browser's gluetun keeps
    re-dialling a ClusterIP with nothing behind it. One browser looped that way for
    about four days with every health signal green.

    A browser is stranded when its gateway index has no gateway at all, or when the
    gateway now on that index serves a DIFFERENT country than the browser asked for
    — the index-reuse case, where a freed index was re-leased to another country and
    the browser silently egresses from somewhere it never chose.

    PERMANENT_IDX is always treated as present and serving PERMANENT_COUNTRY: its
    pod is legitimately absent during a Deployment rollout, and re-homing then would
    both fight Terraform and spend a second tunnel on the same country. Note what
    this does and does not cover: a browser on that index asking for a DIFFERENT
    country (the index-reuse case, e.g. a leftover from when index 1 served the US)
    still disagrees with PERMANENT_COUNTRY and is re-homed. A browser on that index
    asking for PERMANENT_COUNTRY is never "stranded" — re-homing it would only
    return the same index — so a permanent gateway that is genuinely down is a
    gateway-health problem, covered by the VPNEgressGatewayDown alert and by
    ensure_gateway refusing to wire new browsers to a gateway with no Ready pod.

    Absence is counted across consecutive reaper ticks (the rationale in
    plan_orphan_routing_reaping applies unchanged) so a gateway that is mid-recreate
    is not misread as gone. Streaks for browsers that have gone away are dropped.

    `browsers`: [{"id","gateway_idx","country","dead"}]; `gateways`: [{"idx","country"}].
    """
    serving = {gw["idx"]: gw.get("country") for gw in gateways}
    serving[PERMANENT_IDX] = PERMANENT_COUNTRY
    stranded, new_streak = [], {}
    for b in browsers:
        if b.get("dead"):
            continue
        idx, country = b.get("gateway_idx"), b.get("country")
        # Either side's country being unknown means "cannot judge" — only a
        # positive disagreement counts, so a missing annotation never starts a
        # re-home loop.
        if idx in serving and (not country or serving[idx] is None or serving[idx] == country):
            continue
        seen = missing_streak.get(b["id"], 0) + 1
        new_streak[b["id"]] = seen
        if seen >= required_streak:
            stranded.append(b["id"])
    return (stranded, new_streak)


def plan_orphan_gateway_reaping(object_idxs, live_gw_idxs, missing_streak,
                                required_streak=3):
    """Return (gateway_idxs_to_reap, new_missing_streak) for gateway Services /
    peers ConfigMaps / wg Secrets left behind by a gateway pod that vanished.

    The mirror image of plan_orphan_routing_reaping, for the gateway side. Gateways
    created after the ownerReferences change clean themselves up via kube's garbage
    collector; this covers the ones created before it and any set whose owner stamp
    never landed. The consecutive-tick streak keeps a gateway that is mid-create
    (objects first, pod a moment later) from being reaped out from under itself.

    PERMANENT_IDX is excluded: its objects are Terraform-owned and its pod is
    absent during every rollout, so reaping them is exactly the outage this
    function exists to prevent.

    `object_idxs`: gateway indexes seen on Services/ConfigMaps/Secrets;
    `live_gw_idxs`: indexes that still have a gateway pod.
    """
    live = set(live_gw_idxs)
    orphans, new_streak = [], {}
    for idx in object_idxs:
        if idx == PERMANENT_IDX or idx in live:
            continue
        seen = missing_streak.get(idx, 0) + 1
        new_streak[idx] = seen
        if seen >= required_streak:
            orphans.append(idx)
    return (orphans, new_streak)


def plan_orphan_routing_reaping(routes, live_pod_names, missing_streak, required_streak=3):
    """Return (userkeys_to_reap, new_missing_streak) for Services/Ingresses whose
    browser pod no longer exists.

    A browser is a bare Pod, and `plan_reaping` above only ever sees browsers that
    still HAVE a pod — so anything that removes the pod outside `delete_browser`
    (eviction, node drain, GC of a Failed pod) leaves its Service + Ingress behind
    with nothing backing them. The hostname then serves 503 forever and the
    auto-discovered external monitor sits red; one such pair survived 13 days
    (2026-08-08, user edinpriqtelvirtual-gmail-com-432ab095).

    Absence is counted across consecutive reaper ticks rather than judged from the
    Service's age: a switch-country recreate deletes and re-creates the pod under
    the SAME name while the long-lived Service stays put, so an age-based gate
    would happily reap a browser that is mid-recreate. Requiring the pod to be
    missing for `required_streak` ticks (~3 min at the 60s loop) outlasts any
    recreate while still clearing a genuine leak quickly. Streaks for routes that
    have gone away are dropped, so a reused userkey starts from zero.

    `routes`: [{"userkey", "name"}] built from Services labelled app=proxy-browser;
    `live_pod_names`: set of existing browser pod names.
    """
    orphans = []
    new_streak = {}
    for route in routes:
        userkey, name = route["userkey"], route["name"]
        if name in live_pod_names:
            continue
        seen = missing_streak.get(userkey, 0) + 1
        new_streak[userkey] = seen
        if seen >= required_streak:
            orphans.append(userkey)
    return (orphans, new_streak)
