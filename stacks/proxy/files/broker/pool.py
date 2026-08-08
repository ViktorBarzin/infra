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
10.13.i.254. Indexes 1..254 (i=0 reserved: 10.13.0.0/24 unused).
"""

# ---- account/tunnel budget (NordVPN ~10 concurrent tunnels, memory #10182) ----
MAX_COUNTRIES = 8      # concurrent country gateways (each = one NordVPN tunnel)
RESERVED_SLOTS = 2     # tunnels kept free for Viktor's own NordVPN devices
GW_SUBNET_PREFIX = "10.13"
MIN_SUBNET_IDX = 1
MAX_SUBNET_IDX = 254


def normalize_country(country, allowed):
    """Return the canonical country name or None if not offered."""
    if not country:
        return None
    for c in allowed:
        if c.lower() == country.strip().lower():
            return c
    return None


def alloc_subnet_idx(used_idxs):
    """Lowest free /24 index in [1,254]; raises if the space is exhausted."""
    used = set(used_idxs)
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
    """
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
    """
    dead_browsers = [b["id"] for b in browsers if b.get("dead")]
    live_by_gw = {}
    for b in browsers:
        if not b.get("dead"):
            live_by_gw.setdefault(b.get("gateway_idx"), 0)
            live_by_gw[b["gateway_idx"]] += 1
    dead_gws = []
    for gw in gateways:
        has_live = live_by_gw.get(gw["idx"], 0) > 0
        idle_for = now - gw.get("last_used", now)
        if not has_live and idle_for >= gw_idle_seconds:
            dead_gws.append(gw["idx"])
    return (dead_gws, dead_browsers)


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
