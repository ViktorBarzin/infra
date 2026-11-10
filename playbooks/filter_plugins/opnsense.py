# -*- coding: utf-8 -*-
"""Filters that turn playbooks/files/opnsense/*.yml into OPNsense 26.7 API payloads.

Used by playbooks/opnsense.yml with the opnsense_mvc module. The YAML keeps pfSense's
vocabulary (pfSense interface keys, `net:`/`ip:`/`address:` endpoints, "keep state");
these filters map it to the field names and values of the MVC models on the box
(Firewall/Filter.xml, Firewall/DNat.xml, Routing/Gateways.xml, ...).
"""

from __future__ import annotations

import ipaddress

import jinja2

PRODUCTION_ONLY = ("profile", "enabled_in")


# What a placeholder renders to when the profile has no value for it. It is
# never sent to the box: every payload builder refuses an item that still
# carries it (an empty string would read as "any" in a rule).
UNRENDERED = "__unrendered_placeholder__"


def opn_render(data, fw):
    """Render "{{ fw.x }}" placeholders in every string.

    A placeholder the profile cannot fill (fw.lan_v6 in staging) becomes
    UNRENDERED. Items marked for another profile are dropped with opn_active
    before they reach a payload builder.
    """
    env = jinja2.Environment(undefined=jinja2.StrictUndefined)

    def walk(v):
        if isinstance(v, dict):
            return {k: walk(x) for k, x in v.items()}
        if isinstance(v, list):
            return [walk(x) for x in v]
        if isinstance(v, str) and "{{" in v:
            try:
                return env.from_string(str(v)).render(fw=fw)
            except jinja2.exceptions.UndefinedError:
                return UNRENDERED
        return v

    return walk(data)


def _has_unrendered(v):
    if isinstance(v, dict):
        return any(_has_unrendered(x) for x in v.values())
    if isinstance(v, list):
        return any(_has_unrendered(x) for x in v)
    return isinstance(v, str) and UNRENDERED in v


def _guarded(fn, what):
    """Wrap a payload builder so no item with an unfilled placeholder reaches the box."""
    def wrapper(*args, **kwargs):
        out = fn(*args, **kwargs)
        for it in out or []:
            if _has_unrendered(it):
                raise ValueError("%s %r uses a placeholder this profile does not define"
                                 % (what, it.get("description") or it.get("descr") or it.get("name")))
        return out
    wrapper.__name__ = fn.__name__
    wrapper.__doc__ = fn.__doc__
    return wrapper


def opn_active(items, profile):
    """Drop entries marked profile/enabled_in for another profile."""
    out = []
    for it in items or []:
        want = [it.get(k) for k in PRODUCTION_ONLY if it.get(k)]
        if want and profile not in want:
            continue
        out.append(it)
    return out


def _iface(name, ifmap):
    if isinstance(name, list):
        return ",".join(_iface(n, ifmap) for n in name)
    return ifmap.get(name, name)


def _endpoint(e, ifmap):
    """pfSense source/destination -> (net, not, port)."""
    e = e or {}
    if e.get("any"):
        net = "any"
    elif e.get("net"):
        net = _iface(e["net"], ifmap)
    elif e.get("ip"):
        ip = e["ip"]
        net = _iface(ip[:-2], ifmap) + "ip" if ip.endswith("ip") else ip
    elif e.get("self"):
        net = "(self)"
    elif e.get("alias"):
        net = e["alias"]
    elif e.get("address"):
        net = str(e["address"])
    else:
        net = "any"
    return net, bool(e.get("not")), str(e.get("port") or "")


def _proto(p, ipprotocol):
    p = (p or "any").lower()
    if p == "any":
        return "any"
    if p == "icmp" and ipprotocol == "inet6":
        return "IPV6-ICMP"
    return p.upper()


ICMP6 = {"echoreq": "128", "echorep": "129", "unreach": "1", "toobig": "2", "timex": "3", "paramprob": "4"}


def _uses_missing_iface(names, present):
    names = names if isinstance(names, list) else [names]
    return [n for n in names if n not in present]


def rule_description(r):
    return r.get("description") or "pfSense rule %s" % r.get("pfsense_tracker")


def opn_filter_rules(rules, ifmap, present_ifs):
    """filter.yml rules (already profile-filtered) -> Firewall/Filter rule dicts.

    Sequence follows YAML order (index * 10, starting at 100) so production and
    staging share numbering. Rules created by a port forward (linked_nat_rule) are
    left to the forward. Rules on an interface the box does not have are skipped;
    opn_filter_skipped lists them.
    """
    out = []
    for idx, r in enumerate(rules or []):
        if r.get("linked_nat_rule"):
            continue
        ifs = r["interface"] if isinstance(r["interface"], list) else [r["interface"]]
        mapped = [_iface(i, ifmap) for i in ifs]
        if _uses_missing_iface(mapped, present_ifs):
            continue
        src, src_not, src_port = _endpoint(r.get("source"), ifmap)
        dst, dst_not, dst_port = _endpoint(r.get("destination"), ifmap)
        ipp = r.get("ipprotocol") or "inet"
        item = {
            "enabled": not r.get("disabled", False),
            "sequence": str(100 + idx * 10),
            "action": r.get("action", "pass"),
            "quick": bool(r.get("quick", True)),
            "interface": ",".join(mapped),
            "direction": r.get("direction", "in"),
            "ipprotocol": ipp,
            "protocol": _proto(r.get("protocol"), ipp),
            "source_net": src,
            "source_not": src_not,
            "source_port": src_port,
            "destination_net": dst,
            "destination_not": dst_not,
            "destination_port": dst_port,
            "log": bool(r.get("log", False)),
            "statetype": (r.get("statetype") or "keep state").split()[0],
            "disablereplyto": bool(r.get("reply_to_disabled", False)),
            "description": rule_description(r),
        }
        if r.get("icmptype"):
            if ipp == "inet6":
                item["icmp6type"] = ",".join(ICMP6[t] for t in r["icmptype"])
            else:
                item["icmptype"] = ",".join(r["icmptype"])
        for src_key, dst_key in (("max_src_conn", "max-src-conn"), ("max_src_conn_rate", "max-src-conn-rate"),
                                 ("max_src_conn_rates", "max-src-conn-rates")):
            if r.get(src_key) is not None:
                item[dst_key] = str(r[src_key])
        out.append(item)
    return out


def opn_filter_skipped(rules, ifmap, present_ifs):
    """Descriptions of rules skipped because their interface is not on the box."""
    out = []
    for r in rules or []:
        if r.get("linked_nat_rule"):
            continue
        ifs = r["interface"] if isinstance(r["interface"], list) else [r["interface"]]
        missing = _uses_missing_iface([_iface(i, ifmap) for i in ifs], present_ifs)
        if missing:
            out.append("%s (interface %s)" % (rule_description(r), ",".join(missing)))
    return out


def forward_description(f):
    return f.get("description") or "pfSense forward %s:%s" % (f.get("interface"), (f.get("destination") or {}).get("port"))


PASS_MAP = {"linked": "rule", "pass": "pass", "none": ""}


def opn_dnat_rules(forwards, ifmap):
    """nat_port_forwards.yml -> Firewall/DNat rule dicts.

    associated_rule linked -> pass=rule (OPNsense registers the pass rule itself),
    pass -> pass=pass (rdr pass), none -> no rule. natreflection enable has no
    OPNsense equivalent beyond pure NAT, so it maps to purenat.
    """
    out = []
    for idx, f in enumerate(forwards or []):
        src, src_not, src_port = _endpoint(f.get("source"), ifmap)
        dst, dst_not, dst_port = _endpoint(f.get("destination"), ifmap)
        tgt = f.get("target") or {}
        target = tgt.get("alias") or str(tgt.get("address") or "")
        refl = f.get("natreflection") or ""
        if refl == "enable":
            refl = "purenat"
        ipp = f.get("ipprotocol") or "inet"
        out.append({
            "sequence": str(100 + idx * 10),
            "disabled": bool(f.get("disabled", False)),
            "interface": _iface(f["interface"], ifmap),
            "ipprotocol": ipp,
            # the DNat model keeps protocols in lower case, unlike the filter rules
            "protocol": _proto(f.get("protocol"), ipp).lower(),
            "source": {"network": src, "not": src_not, "port": src_port},
            "destination": {"network": dst, "not": dst_not, "port": dst_port},
            "target": target,
            "local-port": str(f.get("local_port") or ""),
            "natreflection": refl,
            "pass": PASS_MAP.get(f.get("associated_rule") or "none", ""),
            "log": False,
            "descr": forward_description(f),
        })
    return out


def _family(net):
    try:
        return "inet6" if ipaddress.ip_network(str(net), strict=False).version == 6 else "inet"
    except ValueError:
        return "inet"


def outbound_description(r):
    if r.get("description"):
        return r["description"]
    s = r.get("source") or {}
    d = r.get("destination") or {}
    return "pfSense outbound %s %s -> %s" % (
        r.get("interface"), s.get("address") or s.get("net") or ("self" if s.get("self") else "any"),
        d.get("address") or d.get("alias") or "any")


def opn_snat_rules(rules, ifmap):
    """nat_outbound.yml -> Firewall/Filter snatrules dicts.

    The snatrules model has no inet46, so inet46 rules take the family of their
    source address (127.0.0.0/8 -> inet, ::1/128 -> inet6), else inet. OPNsense only
    takes ports on TCP/UDP rules, so a rule with a port and protocol any (pfSense's
    ISAKMP auto rules, port 500) becomes TCP/UDP.
    """
    out = []
    for idx, r in enumerate(rules or []):
        src, src_not, src_port = _endpoint(r.get("source"), ifmap)
        dst, dst_not, dst_port = _endpoint(r.get("destination"), ifmap)
        ipp = r.get("ipprotocol") or "inet"
        if ipp == "inet46":
            ipp = _family(src) if src not in ("any", "(self)") else "inet"
        tgt = r.get("target") or {}
        if tgt.get("interface"):
            target = _iface(tgt["interface"], ifmap) + "ip"
        else:
            target = str(tgt.get("address") or "")
            if target.endswith("/32"):
                target = target[:-3]
        out.append({
            "enabled": not r.get("disabled", False),
            "nonat": bool(r.get("nonat", False)),
            "sequence": str(100 + idx * 10),
            "interface": _iface(r["interface"], ifmap),
            "ipprotocol": ipp,
            "protocol": "TCP/UDP" if (r.get("protocol") or "any") == "any" and (src_port or dst_port)
                        else _proto(r.get("protocol"), ipp),
            "source_net": src,
            "source_not": src_not,
            "source_port": src_port,
            "destination_net": dst,
            "destination_not": dst_not,
            "destination_port": dst_port,
            "target": "" if r.get("nonat") else target,
            "target_port": str(tgt.get("port") or ""),
            "staticnatport": bool(r.get("staticnatport", False)),
            "log": False,
            "description": outbound_description(r),
        })
    return out


def opn_aliases(aliases):
    out = []
    for a in aliases or []:
        item = {
            "enabled": True,
            "name": a["name"],
            "type": a["type"],
            "content": "\n".join(str(c) for c in a.get("content") or []),
            "description": a.get("description") or "",
        }
        # URL tables: refresh interval in days (0.0035 is about five minutes).
        if a.get("updatefreq") is not None:
            item["updatefreq"] = str(a["updatefreq"])
        out.append(item)
    return out


def opn_gateways(gateways, ifmap):
    out = []
    for g in gateways or []:
        if g.get("port") is False:
            continue
        mon = g.get("monitor")
        item = {
            "name": g["name"],
            "disabled": bool(g.get("disabled", False)),
            "interface": _iface(g["interface"], ifmap),
            "ipprotocol": g.get("ipprotocol", "inet"),
            "gateway": str(g["address"]),
            "defaultgw": bool(g.get("default", False)),
            "monitor_disable": mon is False,
            "monitor": "" if mon in (False, None) else str(mon),
            "monitor_killstates": bool(g.get("kill_states_on_down", False)),
            "weight": str(g.get("weight", 1)),
            "descr": g.get("description") or "",
        }
        if g.get("interval_ms"):
            item["interval"] = str(int(g["interval_ms"]) // 1000)
        out.append(item)
    return out


def opn_routes(routes):
    return [{
        "network": r["network"],
        "gateway": r["gateway"],
        "descr": r.get("description") or "",
        "enabled": not r.get("disabled", False),
    } for r in routes or []]


for _fn, _what in (("opn_filter_rules", "filter rule"), ("opn_dnat_rules", "port forward"),
                   ("opn_snat_rules", "outbound NAT rule"), ("opn_aliases", "alias"),
                   ("opn_gateways", "gateway"), ("opn_routes", "route")):
    globals()[_fn] = _guarded(globals()[_fn], _what)


class FilterModule(object):
    def filters(self):
        return {
            "opn_render": opn_render,
            "opn_active": opn_active,
            "opn_filter_rules": opn_filter_rules,
            "opn_filter_skipped": opn_filter_skipped,
            "opn_dnat_rules": opn_dnat_rules,
            "opn_snat_rules": opn_snat_rules,
            "opn_aliases": opn_aliases,
            "opn_gateways": opn_gateways,
            "opn_routes": opn_routes,
            "opn_rule_description": rule_description,
            "opn_forward_description": forward_description,
            "opn_outbound_description": outbound_description,
        }
