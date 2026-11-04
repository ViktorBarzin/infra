#!/usr/bin/env python3
"""Convert pfSense's config.xml into the declarative YAML that drives OPNsense.

Purpose
    One-off converter for the OPNsense migration
    (docs/plans/2026-11-03-opnsense-migration.md, decision 5). It reads a copy
    of pfSense CE 2.7.2's config.xml and writes one YAML file per area to the
    output directory, plus REPORT.md listing counts, dropped objects, literal
    firewall addresses that became per-profile placeholders, settings it did
    not map, the secrets the Ansible run will need, and open questions.

Run
    umask 077; d=$(mktemp -d)
    ssh admin@10.0.20.1 'cat /cf/conf/config.xml' > "$d/config.xml"
    scripts/pfsense-to-opnsense.py --config "$d/config.xml" --out playbooks/files/opnsense
    rm -rf "$d"

    Requires python3 and PyYAML. The copy of config.xml holds secrets, so keep
    it in a mode-700 temp dir outside the repo and delete it afterwards.

One-off
    The output was generated once (2026-11-04), reviewed and committed. From
    then on the YAML is hand-maintained: edit the YAML, do not re-run this
    script over it. The script stays in the repo as a record of how each
    pfSense field was interpreted.

Secrets
    No secret value is copied into the output. Private keys, pre-shared keys,
    password hashes, certificates and API keys are skipped, and the names of
    the ones the new firewall needs are listed in REPORT.md. Before writing,
    the script checks every output file against every secret-bearing value in
    config.xml and refuses to write if any appears.

Output is deterministic: objects keep pfSense's order and keys keep a fixed order.
"""

import argparse
import base64
import datetime
import html
import ipaddress
import os
import re
import sys
import xml.etree.ElementTree as ET

import yaml

# Firewall-owned addresses per profile. Production is pfSense's addressing;
# staging is the spare set from decision 6 of the plan.
PROFILES = {
    "staging": {
        "wan": "192.168.1.250",
        "lan": "10.0.10.2",
        "opt1": "10.0.20.2",
        "opt4": "10.0.30.2",
    },
    "production": {
        "wan": "192.168.1.2",
        "lan": "10.0.10.1",
        "opt1": "10.0.20.1",
        "opt4": "10.0.30.1",
        "wan_v6": "fdfe:e989:d3ce:1::1/64",
        "lan_v6": "2001:470:6f:43d::1/64",
        "opt1_v6": "2001:470:5a7f:20::1/64",
    },
}

# pfSense literal -> addresses.yml key. IPv6 keys carry a prefix length in
# addresses.yml, so their placeholder strips it.
LITERAL_MAP = {
    "192.168.1.2": "wan",
    "10.0.10.1": "lan",
    "10.0.20.1": "opt1",
    "10.0.30.1": "opt4",
    "fdfe:e989:d3ce:1::1": "wan_v6",
    "2001:470:6f:43d::1": "lan_v6",
    "2001:470:5a7f:20::1": "opt1_v6",
}

# Interfaces that exist only in the production profile: opt2 is the
# WireGuard tunnel, opt3 the HE 6in4 gif. The WireGuard interface group
# exists only where the tunnel does.
PRODUCTION_ONLY_IFACES = {"opt2", "opt3", "WireGuard"}

# Objects that today's pfSense Ansible configurators own, matched the same
# way those configurators match them (by description or name).
K8S_IPV6 = "pfsense-k8s-ipv6.yml"
VERMONT = "pfsense-vermont-alias.yml"
TAILSCALE = "pfsense-tailscale.yml"
MANAGED_DESCR = {
    "Vermont complex alias: only k8s nodes and devvm (ADR-0035)": VERMONT,
    "no NAT to Vermont complex alias (ADR-0035)": VERMONT,
    "Vermont complex alias via rpi-sofia (ADR-0035)": VERMONT,
    "tailnet -> CCTV blocked (ADR-0017 keeps that segment isolated)": TAILSCALE,
    "tailnet -> homelab (subnet routes + exit node)": TAILSCALE,
    "tailnet -> WG sites: SNAT to tunnel address (see design 2026-08-03)": TAILSCALE,
}
MANAGED_NAMES = {
    "vermont_complex_clients": VERMONT,
    "vermont_complex_alias": VERMONT,
    "rpi_sofia": VERMONT,
}

HAPROXY_DROP_FRONTENDS = {"mailserver_proxy_test"}
HAPROXY_RETIRED_PREFIX = "ipv6_"

# Tags whose text is secret. Used both to skip them and to build the leak check.
SECRET_TAG = re.compile(
    r"(privatekey|presharedkey|bcrypt-hash|password|passwd|secret|"
    r"authorizedkeys|^prv$|^crt$|^key$|apikey|preauthkey|oinkmaster|"
    r"encryption_password|ddnsdomainkey$|tsig|ipsecpsk|^psk$|_hash_key)",
    re.I,
)


class UnresolvedRef(Exception):
    """An object names an alias or network that pfSense does not define."""


def txt(e, tag, default=""):
    if e is None:
        return default
    v = e.findtext(tag)
    return default if v is None else v.strip()


def has(e, tag):
    return e is not None and e.find(tag) is not None


def clean(s):
    """Decode pfSense's HTML-escaped descriptions; keep them ASCII-friendly."""
    if s is None:
        return None
    s = html.unescape(s).strip()
    s = s.replace("\u2014", "-").replace("\u2013", "-").replace("\u2192", "->")
    return s or None


def is_ip_or_net(s):
    try:
        ipaddress.ip_network(s, strict=False)
        return True
    except ValueError:
        return False


def norm_port(p):
    """pfSense writes ranges as a:b or a-b; normalise to a-b."""
    if not p:
        return None
    return p.replace(":", "-")


def onoff(e, tag):
    return has(e, tag)


class Converter:
    def __init__(self, root, date):
        self.root = root
        self.date = date
        self.replaced = []  # (object, field, old, new)
        self.dropped = []  # (section, object, reason)
        self.unmapped = []  # (setting, value/why)
        self.ambiguous = []
        self.defaults = []  # defaults made explicit
        self.counts = []  # (section, pfsense, yaml, note)
        self.secrets_needed = []
        self.ifaces = {c.tag: c for c in root.find("interfaces")}
        self.ifgroups = [txt(g, "ifname") for g in root.findall("ifgroups/ifgroupentry")]
        self.aliases = {txt(a, "name"): a for a in root.findall("aliases/alias")}

    # ---------- helpers ----------

    def fw(self, literal, obj, field):
        """Return a placeholder if literal (optionally /32 or /128) is a firewall address."""
        if literal is None:
            return None
        bare, _, plen = literal.partition("/")
        key = LITERAL_MAP.get(bare.lower()) or LITERAL_MAP.get(bare)
        if key is None:
            return literal
        if plen and plen not in ("32", "128"):
            return literal
        new = "{{ fw.%s }}" % key if "_v6" not in key else "{{ fw.%s.split('/')[0] }}" % key
        self.replaced.append((obj, field, literal, new))
        return new

    def endpoint(self, e, obj, field):
        """Convert a pfSense <source>/<destination> into the YAML form."""
        out = {}
        if e is None:
            return {"any": True}
        if has(e, "any"):
            out["any"] = True
        net = txt(e, "network")
        addr = txt(e, "address")
        for value, kind in ((net, "network"), (addr, "address")):
            if not value:
                continue
            if value == "(self)":
                out["self"] = True
            elif value == "any":
                out["any"] = True
            elif kind == "network" and re.fullmatch(r"(wan|lan|opt\d+)ip", value):
                out["ip"] = value
            elif kind == "network" and (value in self.ifaces or value in self.ifgroups):
                out["net"] = value
            elif is_ip_or_net(value):
                out["address"] = self.fw(value, obj, f"{field}.{kind}")
            elif value in self.aliases:
                out["alias"] = value
            else:
                raise UnresolvedRef(value)
        if has(e, "not"):
            out["not"] = True
        port = norm_port(txt(e, "port"))
        if port:
            out["port"] = port
        return out or {"any": True}

    def profile_for(self, ifaces):
        if isinstance(ifaces, str):
            ifaces = [ifaces]
        return "production" if any(i in PRODUCTION_ONLY_IFACES for i in ifaces) else None

    def managed_by(self, descr, name=None):
        if descr and descr.startswith("k8s-ipv6: "):
            return K8S_IPV6
        if descr in MANAGED_DESCR:
            return MANAGED_DESCR[descr]
        if name in MANAGED_NAMES:
            return MANAGED_NAMES[name]
        return None

    # ---------- sections ----------

    def addresses(self):
        return {
            "profiles": PROFILES,
            "literal_map": [{"literal": k, "key": v} for k, v in LITERAL_MAP.items()],
        }

    def aliases_yml(self):
        out = []
        for a in self.root.findall("aliases/alias"):
            name = txt(a, "name")
            detail = txt(a, "detail")
            item = {
                "name": name,
                "type": txt(a, "type"),
                "content": txt(a, "address").split(),
                "description": clean(txt(a, "descr")),
            }
            if detail:
                item["content_descriptions"] = [clean(d) for d in detail.split("||")]
            if txt(a, "url"):
                item["url"] = txt(a, "url")
            m = self.managed_by(None, name)
            if m:
                item["managed_by"] = m
            out.append(item)
        n = len(self.root.findall("aliases/alias"))
        self.counts.append(("aliases", n, len(out), ""))
        return out

    def gateways(self):
        g = self.root.find("gateways")
        d4, d6 = txt(g, "defaultgw4"), txt(g, "defaultgw6")
        out = []
        for gw in g.findall("gateway_item"):
            name = txt(gw, "name")
            proto = txt(gw, "ipprotocol") or "inet"
            item = {
                "name": name,
                "interface": txt(gw, "interface"),
                "address": txt(gw, "gateway"),
                "ipprotocol": proto,
                "default": name == (d4 if proto == "inet" else d6) or has(gw, "defaultgw"),
                "monitor": False if has(gw, "monitor_disable") else (txt(gw, "monitor") or None),
                "description": clean(txt(gw, "descr")),
                "disabled": has(gw, "disabled"),
            }
            for tag, key in (("weight", "weight"), ("interval", "interval_ms"),
                             ("alert_interval", "alert_interval_ms")):
                if txt(gw, tag):
                    item[key] = int(txt(gw, tag))
            if has(gw, "gw_down_kill_states"):
                item["kill_states_on_down"] = True
            prof = self.profile_for(item["interface"])
            if prof:
                item["profile"] = prof
            m = self.managed_by(item["description"], name)
            if m:
                item["managed_by"] = m
            if proto == "inet6" and name == "default" and txt(gw, "gateway").upper().startswith("2A00:4802"):
                item["port"] = False
                item["_comment"] = (
                    "Stale: an old ISP IPv6 address on WAN. No route or rule uses it and it is\n"
                    "not the default; IPv6 leaves through HE_GWv6. Not ported (port: false)."
                )
                self.dropped.append(("gateways", name, "stale ISP inet6 gateway, kept in YAML with port: false"))
            if name == "k8s_master_gw":
                self.ambiguous.append("Gateway k8s_master_gw (10.0.20.100 on opt1) is not used by any route or rule in config.xml. Ported as-is; it may be droppable.")
            out.append(item)
        self.counts.append(("gateways", len(g.findall("gateway_item")), len(out),
                            "1 marked port: false"))
        return out

    def routes(self):
        gwif = {txt(g, "name"): txt(g, "interface") for g in self.root.findall("gateways/gateway_item")}
        out = []
        for r in self.root.findall("staticroutes/route"):
            item = {
                "network": txt(r, "network"),
                "gateway": txt(r, "gateway"),
                "description": clean(txt(r, "descr")),
                "disabled": has(r, "disabled"),
            }
            prof = self.profile_for(gwif.get(item["gateway"], ""))
            if prof:
                item["profile"] = prof
            m = self.managed_by(item["description"], item["gateway"])
            if m:
                item["managed_by"] = m
            out.append(item)
        self.counts.append(("static routes", len(self.root.findall("staticroutes/route")), len(out), ""))
        return out

    def filter(self):
        rules = self.root.findall("filter/rule")
        out = []
        empty_type = 0
        no_proto = 0
        for r in rules:
            tracker = txt(r, "tracker")
            descr = clean(txt(r, "descr"))
            label = f"filter rule {tracker} ({descr or 'no description'})"
            floating = txt(r, "floating") == "yes"
            iface_raw = txt(r, "interface")
            iface = iface_raw.split(",") if floating else iface_raw
            try:
                src = self.endpoint(r.find("source"), label, "source")
                dst = self.endpoint(r.find("destination"), label, "destination")
            except UnresolvedRef as ex:
                self.dropped.append(("filter", label, f"references alias '{ex}', which config.xml does not define"))
                continue
            rtype = txt(r, "type")
            if not rtype:
                empty_type += 1
            proto_raw = txt(r, "ipprotocol")
            if not proto_raw:
                no_proto += 1
            item = {
                "pfsense_tracker": tracker,
                "description": descr,
                "interface": iface,
                "floating": floating,
                "direction": (txt(r, "direction") or "any") if floating else "in",
                # pfSense: an empty <type> is pass; non-floating rules are always quick.
                "action": rtype or "pass",
                "quick": (txt(r, "quick") == "yes") if floating else True,
                # pfSense: a missing <ipprotocol> means inet.
                "ipprotocol": proto_raw or "inet",
                "protocol": txt(r, "protocol") or "any",
                "source": src,
                "destination": dst,
                "log": has(r, "log"),
                "disabled": has(r, "disabled"),
                "statetype": txt(r, "statetype") or "keep state",
            }
            if txt(r, "icmptype"):
                item["icmptype"] = txt(r, "icmptype").split(",")
            for tag in ("max", "max-src-nodes", "max-src-conn", "max-src-states",
                        "max-src-conn-rate", "max-src-conn-rates", "statetimeout",
                        "os", "gateway", "tag", "tagged"):
                v = txt(r, tag)
                if v:
                    key = tag.replace("-", "_")
                    item[key] = int(v) if v.isdigit() else v
            if has(r, "disablereplyto"):
                item["reply_to_disabled"] = True
            assoc = txt(r, "associated-rule-id")
            if assoc.startswith("nat_"):
                item["linked_nat_rule"] = assoc
            elif assoc:
                self.ambiguous.append(
                    f"{label} carries associated-rule-id '{assoc}', which only has meaning on a NAT rule. Ignored.")
            m = self.managed_by(descr)
            if not m and (iface_raw == "Tailscale"):
                m = TAILSCALE
            if m:
                item["managed_by"] = m
            prof = self.profile_for(iface)
            if prof:
                item["profile"] = prof
            out.append(item)
        self.counts.append(("filter rules", len(rules), len(out),
                            f"{empty_type} had an empty type (pfSense: pass); {no_proto} had no ipprotocol (pfSense: inet)"))
        self._filter_out = out
        return out

    def nat_port_forwards(self):
        rules = self.root.findall("nat/rule")
        linked = {}
        for fr in self.root.findall("filter/rule"):
            a = txt(fr, "associated-rule-id")
            if a.startswith("nat_"):
                linked[a] = fr
        kept_trackers = {i["pfsense_tracker"] for i in getattr(self, "_filter_out", [])}
        out = []
        for r in rules:
            descr = clean(txt(r, "descr"))
            dport = txt(r.find("destination"), "port")
            label = f"port forward {txt(r, 'interface')}:{dport} ({descr or 'no description'})"
            target_raw = txt(r, "target")
            try:
                src = self.endpoint(r.find("source"), label, "source")
                dst = self.endpoint(r.find("destination"), label, "destination")
                if is_ip_or_net(target_raw):
                    target = {"address": self.fw(target_raw, label, "target")}
                elif target_raw in self.aliases:
                    target = {"alias": target_raw}
                else:
                    raise UnresolvedRef(target_raw)
            except UnresolvedRef as ex:
                self.dropped.append(("nat port forwards", label, f"targets alias '{ex}', which config.xml does not define"))
                continue
            assoc = txt(r, "associated-rule-id")
            if assoc.startswith("nat_"):
                assoc_mode = "linked"
            elif assoc == "pass":
                assoc_mode = "pass"
            else:
                assoc_mode = "none"
            item = {
                "description": descr,
                "interface": txt(r, "interface"),
                "ipprotocol": txt(r, "ipprotocol") or "inet",
                "protocol": txt(r, "protocol"),
                "source": src,
                "destination": dst,
                "target": target,
                "local_port": norm_port(txt(r, "local-port")),
                "natreflection": txt(r, "natreflection") or None,
                "associated_rule": assoc_mode,
                "disabled": has(r, "disabled"),
            }
            if assoc_mode == "linked":
                fr = linked.get(assoc)
                if fr is not None:
                    tr = txt(fr, "tracker")
                    item["linked_filter_tracker"] = tr
                    if tr not in kept_trackers:
                        item["_comment"] = (
                            f"pfSense's linked filter rule ({tr}) still points at the undefined\n"
                            "'mailserver' alias, so pf never loaded it; today the WAN pass-all rule\n"
                            "admits this traffic. A linked rule on OPNsense follows the target above.")
                        self.ambiguous.append(
                            f"{label}: linked filter rule {tr} referenced the undefined 'mailserver' alias and was dropped; "
                            "the forward keeps associated_rule: linked, so OPNsense creates a correct pass rule to the target. "
                            "Today that traffic is admitted only by the WAN pass-all rule.")
                    else:
                        fd = self.endpoint(fr.find("destination"), "", "")
                        want_port = item["local_port"]
                        tgt = target.get("alias") or target.get("address")
                        have = fd.get("alias") or fd.get("address")
                        if have != tgt or fd.get("port") != want_port:
                            self.ambiguous.append(
                                f"{label}: pfSense's linked filter rule {tr} passes to {have}:{fd.get('port')}, "
                                f"but the forward targets {tgt}:{want_port}. The rule was edited out of step with the "
                                "forward; the WAN pass-all rule admits the traffic either way. OPNsense's linked rule "
                                "will follow the forward.")
            if r.find("nordr") is not None:
                item["no_rdr"] = True
            prof = self.profile_for(item["interface"])
            if prof:
                item["profile"] = prof
            m = self.managed_by(descr)
            if m:
                item["managed_by"] = m
            out.append(item)
        en_pf = sum(1 for r in rules if not has(r, "disabled"))
        en_y = sum(1 for i in out if not i["disabled"])
        self.counts.append(("NAT port forwards", len(rules), len(out),
                            f"enabled {en_pf} -> {en_y}"))
        return out

    def nat_outbound(self):
        o = self.root.find("nat/outbound")
        out = []
        for r in o.findall("rule"):
            descr = clean(txt(r, "descr"))
            label = f"outbound NAT {txt(r, 'interface')} ({descr or 'no description'})"
            src = self.endpoint(r.find("source"), label, "source")
            dst = self.endpoint(r.find("destination"), label, "destination")
            if txt(r, "sourceport"):
                src["port"] = norm_port(txt(r, "sourceport"))
            if txt(r, "dstport"):
                dst["port"] = norm_port(txt(r, "dstport"))
            t = txt(r, "target")
            nonat = has(r, "nonat")
            if nonat or not t:
                target = None
            elif re.fullmatch(r"(wan|lan|opt\d+)ip", t):
                target = {"interface": t[:-2]}
            elif is_ip_or_net(t):
                sub = txt(r, "target_subnet")
                lit = f"{t}/{sub}" if sub and "/" not in t else t
                target = {"address": self.fw(lit, label, "target")}
            else:
                target = {"alias": t}
            if target and txt(r, "natport"):
                target["port"] = txt(r, "natport")
            item = {
                "description": descr,
                "interface": txt(r, "interface"),
                "ipprotocol": txt(r, "ipprotocol") or "inet46",
                "protocol": txt(r, "protocol") or "any",
                "source": src,
                "destination": dst,
                "target": target,
                "staticnatport": has(r, "staticnatport"),
                "nonat": nonat,
                "disabled": has(r, "disabled"),
            }
            if txt(r, "poolopts"):
                item["poolopts"] = txt(r, "poolopts")
            if txt(r, "source_hash_key"):
                self.unmapped.append(("nat outbound source_hash_key", f"{label}: set, not copied (it is a hash key)"))
            prof = self.profile_for(item["interface"])
            if prof:
                item["profile"] = prof
            m = self.managed_by(descr)
            if m:
                item["managed_by"] = m
            out.append(item)
        self.counts.append(("outbound NAT rules", len(o.findall("rule")), len(out), f"mode {txt(o, 'mode')}"))
        return {"mode": txt(o, "mode"), "rules": out}

    def iface_net(self, key):
        i = self.ifaces[key]
        return str(ipaddress.ip_network(f"{txt(i, 'ipaddr')}/{txt(i, 'subnet')}", strict=False))

    def dhcp(self):
        out = []
        dhcpd = self.root.find("dhcpd")
        sysdomain = txt(self.root.find("system"), "domain")
        nmaps = 0
        for d in dhcpd:
            key = d.tag
            if not has(d, "enable"):
                self.dropped.append(("dhcp", f"DHCPv4 on {key} (range {txt(d, 'range/from')}-{txt(d, 'range/to')})",
                                     "disabled in pfSense (the TP-Link serves that LAN)" if key == "wan" else "disabled in pfSense"))
                continue
            fwaddr = txt(self.ifaces[key], "ipaddr")
            label = f"dhcp {key}"
            dns = [self.fw(s.text.strip(), label, "dns_servers") for s in d.findall("dnsserver") if s.text]
            if not dns:
                dns = [self.fw(fwaddr, label, "dns_servers (pfSense default)")]
                self.defaults.append(f"dhcp {key}: no DNS servers set; pfSense then offers the interface address, written out as {dns[0]}")
            gw = txt(d, "gateway")
            if not gw:
                self.defaults.append(f"dhcp {key}: gateway unset; pfSense uses the interface address")
            dom = txt(d, "domain")
            if not dom:
                self.defaults.append(f"dhcp {key}: domain unset; pfSense uses the system domain {sysdomain}")
            res = []
            for m in d.findall("staticmap"):
                nmaps += 1
                res.append({
                    "mac": txt(m, "mac"),
                    "ip": txt(m, "ipaddr"),
                    "hostname": txt(m, "hostname") or None,
                    "description": clean(txt(m, "descr")),
                })
                if txt(m, "cid"):
                    self.unmapped.append(("dhcp reservation client id", f"{key} {txt(m, 'hostname')}: cid '{txt(m, 'cid')}' not copied (reservations match on MAC)"))
            item = {
                "interface": key,
                "subnet": self.iface_net(key),
                "pool_start": txt(d, "range/from"),
                "pool_end": txt(d, "range/to"),
                "gateway": self.fw(gw or fwaddr, label, "gateway" if gw else "gateway (pfSense default)"),
                "dns_servers": dns,
                "domain": dom or sysdomain,
                "next_server": txt(d, "nextserver") or None,
                "boot_file": txt(d, "filename") or None,
                "default_lease_time": int(txt(d, "defaultleasetime")) if txt(d, "defaultleasetime") else None,
                "max_lease_time": int(txt(d, "maxleasetime")) if txt(d, "maxleasetime") else None,
                "reservations": res,
            }
            out.append(item)
        backend = txt(self.root, "dhcpbackend")
        total = len(list(dhcpd))
        self.counts.append(("DHCPv4 interfaces", total, len(out), f"backend {backend}; {nmaps} reservations"))
        for d in self.root.find("dhcpdv6"):
            if d.find("range") is not None and txt(d, "range/from") and not has(d, "enable"):
                self.dropped.append(("dhcp", f"DHCPv6 on {d.tag} (range {txt(d, 'range/from')})", "DHCPv6 server disabled in pfSense"))
        return {"enabled_in": "production", "backend": "kea", "interfaces": out}

    RA_MODES = {
        "router": "router", "unmanaged": "unmanaged", "managed": "managed",
        "assist": "assisted", "stateless_dhcp": "stateless",
    }

    def radvd(self):
        out = []
        sysdomain = txt(self.root.find("system"), "domain")
        v6 = self.root.find("dhcpdv6")
        for d in v6:
            key = d.tag
            mode = txt(d, "ramode")
            if not mode or mode == "disabled":
                self.dropped.append(("radvd", f"router advertisements on {key}", f"ramode {mode or 'unset'} in pfSense"))
                continue
            i = self.ifaces[key]
            addr = txt(i, "ipaddrv6")
            prefix = str(ipaddress.ip_network(f"{addr}/{txt(i, 'subnetv6')}", strict=False))
            label = f"radvd {key}"
            dns_on = txt(d, "radvd-dns") != "disabled"
            rdnss, dnssl = [], []
            if dns_on:
                servers = [s.text.strip() for s in d.findall("dnsserver") if s.text]
                rdnss = [self.fw(s, label, "rdnss") for s in servers] or [self.fw(addr, label, "rdnss (pfSense default)")]
                dnssl = txt(d, "radomainsearchlist").split(";") if txt(d, "radomainsearchlist") else [sysdomain]
                if not servers:
                    self.defaults.append(f"radvd {key}: RDNSS unset; pfSense advertises the interface address, written out as a placeholder")
                if not txt(d, "radomainsearchlist"):
                    self.defaults.append(f"radvd {key}: DNSSL unset; pfSense advertises the system domain {sysdomain}")
            lifetime = txt(d, "raadvdefaultlifetime")
            item = {
                "interface": key,
                "mode": self.RA_MODES.get(mode, mode),
                "pfsense_mode": mode,
                "prefixes": [prefix],
                "rdnss": rdnss,
                "dnssl": dnssl,
                "router_lifetime": int(lifetime) if lifetime else None,
                "priority": txt(d, "rapriority") or "medium",
                "min_interval": int(txt(d, "raminrtradvinterval")) if txt(d, "raminrtradvinterval") else None,
                "max_interval": int(txt(d, "ramaxrtradvinterval")) if txt(d, "ramaxrtradvinterval") else None,
                "valid_lifetime": int(txt(d, "ravalidlifetime")) if txt(d, "ravalidlifetime") else None,
                "preferred_lifetime": int(txt(d, "rapreferredlifetime")) if txt(d, "rapreferredlifetime") else None,
            }
            if key == "wan":
                # Intent from scripts/pfsense-sofia-lan-ula-ra.php (infra #102).
                if item["min_interval"] is None and item["max_interval"] is None:
                    item["min_interval"], item["max_interval"] = 10, 30
                    self.ambiguous.append(
                        "radvd wan: config.xml has no RA interval, so live pfSense uses its 200-600 s default, but "
                        "scripts/pfsense-sofia-lan-ula-ra.php sets 10/30 s (Matter devices sleep and miss slow RAs). "
                        "The YAML follows the script (10/30). Either the script was not re-run after a later save, "
                        "or its interval keys were dropped by a GUI save.")
                item["_comment"] = (
                    "Sofia home LAN ULA for the Matter lock (infra #102, scripts/pfsense-sofia-lan-ula-ra.php).\n"
                    "Router lifetime 0 keeps the firewall off every host's default-router list; no RDNSS/DNSSL.")
            out.append(item)
        self.counts.append(("router advertisements", sum(1 for d in v6 if txt(d, "ramode")), len(out), "opt1 is ramode disabled"))
        return {"enabled_in": "production", "interfaces": out}

    def unbound(self):
        u = self.root.find("unbound")
        custom = base64.b64decode(txt(u, "custom_options")).decode() if txt(u, "custom_options") else ""
        server_opts, auth = {}, {}
        section = None
        for line in custom.splitlines():
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            if s.endswith(":") and not line.startswith((" ", "\t")):
                section = s[:-1]
                continue
            k, _, v = s.partition(":")
            v = v.strip().strip('"')
            if section == "server":
                server_opts[k.strip()] = v
            elif section == "auth-zone":
                auth[k.strip()] = v
            else:
                self.unmapped.append(("unbound custom option", s))
        overrides = []
        for o in u.findall("domainoverrides"):
            overrides.append({
                "domain": txt(o, "domain"),
                "server": txt(o, "ip"),
                "description": clean(txt(o, "descr")),
                "forward_tls_upstream": bool(txt(o, "forward_tls_upstream")),
            })
        hosts = []
        for h in u.findall("hosts"):
            hosts.append({"host": txt(h, "host"), "domain": txt(h, "domain"), "ip": txt(h, "ip"),
                          "description": clean(txt(h, "descr"))})
        acls = []
        for a in u.findall("acls"):
            acls.append({
                "name": txt(a, "aclname"),
                "action": txt(a, "aclaction"),
                "description": clean(txt(a, "description")),
                "networks": [f"{txt(r, 'acl_network')}/{txt(r, 'mask')}" for r in a.findall("row")],
                "profile": "production",
            })
        nodnsrebind = has(self.root.find("system/webgui"), "nodnsrebindcheck")
        auth_zone = None
        if auth:
            auth_zone = {
                "name": auth.get("name"),
                "primary": auth.get("master"),
                "zonefile": auth.get("zonefile"),
                "url": auth.get("url"),
                "allow_notify": auth.get("allow-notify"),
                "fallback_enabled": auth.get("fallback-enabled") == "yes",
                "for_downstream": auth.get("for-downstream") == "yes",
                "for_upstream": auth.get("for-upstream") == "yes",
            }
        sysdns = [s.text.strip() for s in self.root.findall("system/dnsserver") if s.text]
        out = {
            "enabled": has(u, "enable"),
            "port": int(txt(u, "port")) if txt(u, "port") else 53,
            "listen_interfaces": txt(u, "active_interface").split(",") if txt(u, "active_interface") else ["all"],
            "outgoing_interfaces": txt(u, "outgoing_interface").split(",") if txt(u, "outgoing_interface") else ["all"],
            "dnssec": has(u, "dnssec"),
            "harden_dnssec_stripped": has(u, "dnssecstripped"),
            "serve_expired": has(u, "dnsrecordcache"),
            "serve_expired_ttl": int(server_opts.pop("serve-expired-ttl")) if "serve-expired-ttl" in server_opts else None,
            "prefetch": has(u, "prefetch"),
            "prefetch_key": has(u, "prefetchkey"),
            "hide_identity": has(u, "hideidentity"),
            "hide_version": has(u, "hideversion"),
            "register_dhcp_leases": has(u, "regdhcp"),
            "register_dhcp_static": has(u, "regdhcpstatic"),
            "dns_rebind_protection": not nodnsrebind,
            "forwarding": {
                "enabled": has(u, "forwarding"),
                "use_tls": has(u, "forward_tls_upstream"),
                "servers": [
                    {"address": s, "tls_hostname": txt(self.root.find("system"), f"dns{i}host") or None}
                    for i, s in enumerate(sysdns, start=1)
                ],
            },
            "host_overrides": hosts,
            "domain_overrides": overrides,
            # pfSense's unbound.inc adds private-domain (and domain-insecure when
            # DNSSEC is on) for every domain override.
            "private_domains": [o["domain"] for o in overrides],
            "insecure_domains": [o["domain"] for o in overrides] if has(u, "dnssec") else [],
            "system_domain_local_zone_type": txt(u, "system_domain_local_zone_type") or None,
            "access_lists": acls,
            "auth_zone": auth_zone,
            "advanced": {
                "msgcachesize_mb": int(txt(u, "msgcachesize")) if txt(u, "msgcachesize") else None,
                "outgoing_num_tcp": int(txt(u, "outgoing_num_tcp")) if txt(u, "outgoing_num_tcp") else None,
                "incoming_num_tcp": int(txt(u, "incoming_num_tcp")) if txt(u, "incoming_num_tcp") else None,
                "edns_buffer_size": txt(u, "edns_buffer_size") or None,
                "num_queries_per_thread": int(txt(u, "num_queries_per_thread")) if txt(u, "num_queries_per_thread") else None,
                "jostle_timeout": int(txt(u, "jostle_timeout")) if txt(u, "jostle_timeout") else None,
                "cache_max_ttl": int(txt(u, "cache_max_ttl")) if txt(u, "cache_max_ttl") else None,
                "cache_min_ttl": int(txt(u, "cache_min_ttl")) if txt(u, "cache_min_ttl") else None,
                "infra_host_ttl": int(txt(u, "infra_host_ttl")) if txt(u, "infra_host_ttl") else None,
                "infra_cache_numhosts": int(txt(u, "infra_cache_numhosts")) if txt(u, "infra_cache_numhosts") else None,
                "infra_keep_probing": txt(u, "infra_keep_probing") == "enabled",
                "unwanted_reply_threshold": txt(u, "unwanted_reply_threshold") or None,
                "sock_queue_timeout": int(txt(u, "sock_queue_timeout")) if txt(u, "sock_queue_timeout") else None,
                "log_verbosity": int(txt(u, "log_verbosity")) if txt(u, "log_verbosity") else None,
            },
            "custom_server_options": server_opts,
        }
        if txt(u, "sslcertref") and not has(u, "enablessl"):
            self.unmapped.append(("unbound sslcertref", "a certificate is referenced but the DNS-over-TLS listener is off; not ported"))
        self.ambiguous.append(
            "unbound private_domains / insecure_domains are inferred from how pfSense's unbound.inc treats domain "
            "overrides; I did not read the live /var/unbound/unbound.conf (only config.xml was in scope).")
        self.counts.append(("unbound domain overrides", len(u.findall("domainoverrides")), len(overrides), ""))
        self.counts.append(("unbound host overrides", len(u.findall("hosts")), len(hosts), ""))
        self.counts.append(("unbound ACLs", len(u.findall("acls")), len(acls), ""))
        dm = self.root.find("dnsmasq")
        if dm is not None and not has(dm, "enable"):
            hosts_dm = [f"{txt(h, 'host')}.{txt(h, 'domain')} -> {txt(h, 'ip')}" for h in dm.findall("hosts")]
            self.dropped.append(("dns", "dnsmasq settings (interfaces, custom options, host " + ", ".join(hosts_dm) + ")",
                                 "dnsmasq is disabled in pfSense; Unbound answers on port 53"))
        return out

    def ntp(self):
        s = self.root.find("system")
        n = self.root.find("ntpd")
        servers = txt(s, "timeservers").split()
        out = {
            "servers": [{"host": h, "pool": "pool.ntp.org" in h} for h in servers],
            "interfaces": (txt(n, "interface").split(",") if n is not None and txt(n, "interface") else ["all"]),
            "restrictions": None,  # config.xml has no <ntpd> section, so pfSense's built-in defaults apply
            "note": "CCTV on opt4 may only reach NTP on the firewall (filter rule 1783022274).",
        }
        self.ambiguous.append(
            "ntp: pfSense's server is 2.pfsense.pool.ntp.org. Kept as written; OPNsense's default pool "
            "(0-3.opnsense.pool.ntp.org) is an alternative. config.xml has no <ntpd> section, so interfaces "
            "(all) and restrictions (none set) are pfSense's defaults.")
        self.counts.append(("NTP servers", len(servers), len(servers), ""))
        return out

    def wireguard(self):
        wg = self.root.find("installedpackages/wireguard")
        tunnels, peers = [], []
        for t in wg.findall("tunnels/item"):
            name = txt(t, "name")
            iface_key = next((k for k, i in self.ifaces.items() if txt(i, "if") == name), None)
            ia = self.ifaces.get(iface_key)
            tunnels.append({
                "name": name,
                "enabled": txt(t, "enabled") == "yes",
                "interface": iface_key,
                "interface_address": f"{txt(ia, 'ipaddr')}/{txt(ia, 'subnet')}" if ia is not None else None,
                "listen_port": int(txt(t, "listenport")),
                "addresses": [f"{txt(r, 'address')}/{txt(r, 'mask')}" for r in t.findall("addresses/row")],
                "mtu": int(txt(t, "mtu")) if txt(t, "mtu") else None,
                "public_key": txt(t, "publickey"),
                "private_key_vault_field": f"wireguard_{name}_private_key",
                "description": clean(txt(t, "descr")),
            })
            self.secrets_needed.append(f"WireGuard private key of {name} (reuse pfSense's, decision 13)")
        for p in wg.findall("peers/item"):
            ep = txt(p, "endpoint")
            port = txt(p, "port")
            peers.append({
                "name": clean(txt(p, "descr")),
                "tunnel": txt(p, "tun"),
                "enabled": txt(p, "enabled") == "yes",
                "public_key": txt(p, "publickey"),
                "allowed_ips": [f"{txt(r, 'address')}/{txt(r, 'mask')}" for r in p.findall("allowedips/row")],
                "endpoint": f"{ep}:{port}" if ep else None,
                "keepalive": int(txt(p, "persistentkeepalive")) if txt(p, "persistentkeepalive") else None,
                "preshared_key": bool(txt(p, "presharedkey")),
            })
            if txt(p, "presharedkey"):
                self.secrets_needed.append(f"WireGuard pre-shared key for peer {clean(txt(p, 'descr'))}")
        self.counts.append(("WireGuard tunnels", len(wg.findall("tunnels/item")), len(tunnels), ""))
        self.counts.append(("WireGuard peers", len(wg.findall("peers/item")), len(peers),
                            "no peer has a configured endpoint (they all dial in)"))
        return {"profile": "production", "tunnels": tunnels, "peers": peers}

    def tailscale(self):
        c = self.root.find("installedpackages/tailscale/config")
        a = self.root.find("installedpackages/tailscaleauth/config")
        routes = [{"route": txt(r, "advertisedroutevalue"), "description": clean(txt(r, "advertisedroutedescr"))}
                  for r in c.findall("row")]
        if txt(a, "preauthkey"):
            self.unmapped.append(("tailscale pre-auth key", "set in config.xml; not copied"))
        self.secrets_needed.append("Tailscale/Headscale pre-auth key for registering the node (single-use, from Headscale)")
        self.counts.append(("Tailscale advertised routes", len(routes), len(routes), ""))
        return {
            "managed_by": TAILSCALE,
            "enabled": txt(c, "enable") == "on",
            "login_server": txt(a, "loginserver"),
            "listen_port": int(txt(c, "listenport")) if txt(c, "listenport") else None,
            "advertise_exit_node": txt(c, "exitnode") == "on",
            "accept_routes": txt(c, "acceptroutes") == "on",
            "accept_dns": txt(c, "acceptdns") == "on",
            "advertised_routes": routes,
            "syslog": {"enabled": txt(c, "syslogenable") == "on", "priority": txt(c, "syslogpriority") or None,
                       "facility": txt(c, "syslogfacility") or None},
            "profiles": {
                "staging": {"hostname": "opnsense-staging", "advertised_routes": [], "advertise_exit_node": False,
                            "accept_dns": False, "tags": []},
                "production": {"advertised_routes": "as above", "advertise_exit_node": True, "tags": ["tag:infra"]},
            },
        }

    def haproxy(self):
        h = self.root.find("installedpackages/haproxy")
        frontends, backends = [], []
        used_pools = set()
        for f in h.findall("ha_backends/item"):
            name = txt(f, "name")
            if name in HAPROXY_DROP_FRONTENDS:
                self.dropped.append(("haproxy", f"frontend {name} (:{txt(f, 'a_extaddr/item/extaddr_port')})", "the :2525 test listener (decision 7)"))
                continue
            if name.startswith(HAPROXY_RETIRED_PREFIX):
                self.dropped.append(("haproxy", f"frontend {name}", "retired IPv6 frontend"))
                continue
            binds = []
            for b in f.findall("a_extaddr/item"):
                ext = txt(b, "extaddr")
                addr = txt(b, "extaddr_custom") if ext == "custom" else ext
                m = re.fullmatch(r"(wan|lan|opt\d+)_ipv([46])", addr or "")
                if m:
                    bind = {"interface": m.group(1), "family": f"inet{'' if m.group(2) == '4' else '6'}"}
                elif addr in ("any_ipv4", "any_ipv6"):
                    bind = {"address": "0.0.0.0" if addr == "any_ipv4" else "::"}
                else:
                    bind = {"address": self.fw(addr, f"haproxy frontend {name}", "bind")}
                bind["port"] = int(txt(b, "extaddr_port"))
                binds.append(bind)
            acls = [{"name": txt(x, "name"), "expression": txt(x, "expression"), "value": txt(x, "value")}
                    for x in f.findall("ha_acls/item")]
            actions = [{"action": txt(x, "action"), "backend": txt(x, "use_backendbackend"), "acl": txt(x, "acl")}
                       for x in f.findall("a_actionitems/item")]
            adv = txt(f, "advanced")
            item = {
                "name": name,
                "description": clean(txt(f, "descr")),
                "enabled": txt(f, "status") == "active",
                "mode": txt(f, "type"),
                "binds": binds,
                "default_backend": txt(f, "backend_serverpool"),
                "acls": acls,
                "actions": actions,
                "advanced": base64.b64decode(adv).decode().replace("\t", "  ") if adv else None,
            }
            for tag in ("max_connections", "client_timeout", "forwardfor", "httpclose"):
                if txt(f, tag):
                    item[tag] = txt(f, tag)
            used_pools.add(item["default_backend"])
            used_pools.update(a["backend"] for a in actions)
            frontends.append(item)
        for p in h.findall("ha_pools/item"):
            name = txt(p, "name")
            if name not in used_pools:
                self.dropped.append(("haproxy", f"backend {name}", "used only by a dropped frontend"))
                continue
            servers = []
            for s in p.findall("ha_servers/item"):
                adv = txt(s, "advanced").split()
                send_proxy = "send-proxy-v2" in adv
                check_port = None
                if "port" in adv:
                    check_port = int(adv[adv.index("port") + 1])
                rest = [t for t in adv if t not in ("send-proxy-v2", "port", str(check_port))]
                srv = {
                    "name": txt(s, "name"),
                    "address": self.fw(txt(s, "address"), f"haproxy backend {name}", "server address"),
                    "port": int(txt(s, "port")),
                    "weight": int(txt(s, "weight")) if txt(s, "weight") else None,
                    "send_proxy_v2": send_proxy,
                    "check_port": check_port,
                    "check_interval_ms": int(txt(s, "checkinter")) if txt(s, "checkinter") else None,
                    "enabled": txt(s, "status") == "active",
                }
                if rest:
                    srv["advanced_extra"] = " ".join(rest)
                servers.append(srv)
            backends.append({
                "name": name,
                "balance": txt(p, "balance") or None,
                "check_type": txt(p, "check_type") or None,
                "check_interval_ms": int(txt(p, "checkinter")) if txt(p, "checkinter") else None,
                "retries": int(txt(p, "retries")) if txt(p, "retries") else None,
                "connect_timeout_ms": int(txt(p, "connection_timeout")) if txt(p, "connection_timeout") else None,
                "server_timeout_ms": int(txt(p, "server_timeout")) if txt(p, "server_timeout") else None,
                "servers": servers,
            })
        retired = [txt(f, "name") for f in h.findall("ha_backends/item") if txt(f, "name").startswith(HAPROXY_RETIRED_PREFIX)]
        if not retired:
            self.ambiguous.append("haproxy: none of the six retired ipv6_* frontends is present in config.xml, so nothing was omitted on that account.")
        self.ambiguous.append(
            "haproxy: the mail frontends store extaddr '10.0.20.1' (a literal, not one of pfSense's named choices). "
            "The fact sheet says the live haproxy.cfg binds them on '*'. The YAML binds them to {{ fw.opt1 }}, which "
            "covers the WAN port forwards (they target 10.0.20.1). Confirm whether anything reaches 25/465/587/993 "
            "on another firewall address.")
        self.ambiguous.append(
            "haproxy internal_https_443: the SNI ACL still matches pfsense.viktorbarzin.lan/.me and sends it to the "
            "GUI on 127.0.0.1:8443. Kept as-is; it probably wants opnsense.viktorbarzin.* at cutover.")
        self.counts.append(("HAProxy frontends", len(h.findall("ha_backends/item")), len(frontends), ""))
        self.counts.append(("HAProxy backends", len(h.findall("ha_pools/item")), len(backends), ""))
        return {
            "enabled": txt(h, "enable") == "yes",
            "max_connections": int(txt(h, "maxconn")) if txt(h, "maxconn") else None,
            "frontends": frontends,
            "backends": backends,
        }

    def netflow(self):
        c = self.root.find("installedpackages/softflowd/config")
        t = txt(c, "timeout")
        timeouts = dict(x.split("=", 1) for x in t.split(",") if "=" in x) if t else {}
        self.counts.append(("softflowd instances", 1, 1, ""))
        return {
            "source": "softflowd (pfSense package); maps to OPNsense Reporting > NetFlow",
            "interfaces": txt(c, "interface").split(","),
            "collectors": [f"{txt(c, 'host')}:{txt(c, 'port')}"],
            "version": int(txt(c, "flow_version")) if txt(c, "flow_version") else None,
            "max_flows": int(txt(c, "max_flows")) if txt(c, "max_flows") else None,
            "timeouts": {k: int(v) if v.isdigit() else v for k, v in timeouts.items()},
            "tracking_level": txt(c, "tracking_level") or None,
            "hop_limit": txt(c, "hoplimit") or None,
        }

    def syslog(self):
        s = self.root.find("syslog")
        targets = []
        for tag in ("remoteserver", "remoteserver2", "remoteserver3"):
            v = txt(s, tag)
            if not v:
                continue
            host, _, port = v.rpartition(":") if re.search(r":\d+$", v) else (v, "", "514")
            types = [t for t in ("filter", "dhcp", "auth", "portalauth", "vpn", "dpinger", "hostapd",
                                 "system", "resolver", "ppp", "routing", "ntpd") if has(s, t)]
            if has(s, "logall"):
                types = ["everything"]
            targets.append({
                "address": host,
                "port": int(port),
                "transport": "udp4" if (txt(s, "ipproto") or "ipv4") == "ipv4" else "udp6",
                "log_types": types,
            })
        self.ambiguous.append(
            "syslog: pfSense sends firewall logs only, to 10.0.20.200:30514 (the CrowdSec NodePort). The plan "
            "(decision 10) sends all logs to Alloy at 10.0.20.208 as well; the YAML records pfSense's target only.")
        self.counts.append(("remote syslog targets", len(targets), len(targets), ""))
        return {
            "enabled": has(s, "enable"),
            "log_rule_descriptions": txt(s, "filterdescriptions") or None,
            "targets": targets,
        }

    def misc(self):
        s = self.root.find("system")
        wg = s.find("webgui")
        ifaces = []
        for k, i in self.ifaces.items():
            e = {
                "key": k,
                "device": txt(i, "if"),
                "description": txt(i, "descr"),
                "mtu": int(txt(i, "mtu")) if txt(i, "mtu") else None,
                "mss": int(txt(i, "mss")) if txt(i, "mss") else None,
                "block_private": has(i, "blockpriv"),
                "block_bogons": has(i, "blockbogons"),
            }
            prof = self.profile_for(k)
            if prof:
                e["profile"] = prof
            ifaces.append(e)
        gif = self.root.find("gifs/gif")
        nat_refl = []
        for r in self.root.findall("nat/rule"):
            if txt(r, "natreflection"):
                nat_refl.append({"port_forward": clean(txt(r, "descr")),
                                 "mode": txt(r, "natreflection"),
                                 "disabled": has(r, "disabled")})
        out = {
            "hostname": txt(s, "hostname"),
            "domain": txt(s, "domain"),
            "timezone": txt(s, "timezone"),
            "language": txt(s, "language"),
            "dns_servers": [x.text.strip() for x in s.findall("dnsserver") if x.text],
            "dns_server_gateways": [txt(s, "dns1gw") or None, txt(s, "dns2gw") or None],
            "dns_localhost": txt(s, "dnslocalhost") or None,
            "webgui": {
                "protocol": txt(wg, "protocol"),
                "port": int(txt(wg, "port")),
                "http_redirect": not has(wg, "disablehttpredirect"),
                "dns_rebind_check": not has(wg, "nodnsrebindcheck"),
                "http_referer_check": not has(wg, "nohttpreferercheck"),
                "login_autocomplete": has(wg, "loginautocomplete"),
                "max_processes": int(txt(wg, "max_procs")) if txt(wg, "max_procs") else None,
                "alt_hostnames_needed": ["opnsense.viktorbarzin.me"],
            },
            "ssh": {
                "enabled": txt(s, "ssh/enable") == "enabled",
                "agent_forwarding": txt(s, "ssh/sshdagentforwarding") == "enabled",
                "login_lockout": {
                    "threshold": int(txt(s, "sshguard_threshold")) if txt(s, "sshguard_threshold") else None,
                    "blocktime_s": int(txt(s, "sshguard_blocktime")) if txt(s, "sshguard_blocktime") else None,
                    "detection_time_s": int(txt(s, "sshguard_detection_time")) if txt(s, "sshguard_detection_time") else None,
                    "whitelist": txt(s, "sshguard_whitelist").split(),
                },
            },
            "console": {"primary": txt(s, "primaryconsole"), "serial_speed": int(txt(s, "serialspeed"))},
            "offload": {
                "checksum_disabled": has(s, "disablechecksumoffloading"),
                "tso_disabled": has(s, "disablesegmentationoffloading"),
                "lro_disabled": has(s, "disablelargereceiveoffloading"),
                "hn_altq_enable": has(s, "hn_altq_enable"),
            },
            "firewall": {
                "optimization": txt(s, "optimization") or "normal",
                "maximum_states": txt(s, "maximumstates") or None,
                "maximum_table_entries": int(txt(s, "maximumtableentries")) if txt(s, "maximumtableentries") else None,
                "maximum_frags": txt(s, "maximumfrags") or None,
                "aliases_resolve_interval": txt(s, "aliasesresolveinterval") or None,
                "scrub": not has(s, "disablescrub"),
                "ipv6_allow": has(s, "ipv6allow"),
                "bogons_update": txt(s, "bogons/interval") or None,
            },
            "nat_reflection": {
                "port_forward_mode": "purenat" if txt(s, "enablenatreflectionpurenat") == "yes"
                else ("disabled" if has(s, "disablenatreflection") else "proxy"),
                "reflection_timeout": txt(s, "reflectiontimeout") or None,
                "outbound_reflection": has(s, "enablebinatreflection"),
                "per_rule": nat_refl,
                "note": ("pfSense's 'enable' per-rule mode is NAT + proxy; for UDP it runs an xinetd helper "
                          "(127.0.0.1:19000 to 10.0.20.200:3479 per the fact sheet). OPNsense has pure NAT reflection only."),
            },
            "sysctl": [{"tunable": txt(i, "tunable"), "value": txt(i, "value"), "description": clean(txt(i, "descr"))}
                       for i in self.root.findall("sysctl/item")],
            "interfaces": ifaces,
            "interface_groups": [{"name": txt(g, "ifname"), "members": txt(g, "members").split() or [],
                                  "description": clean(txt(g, "descr"))} for g in self.root.findall("ifgroups/ifgroupentry")],
            "he_tunnel": {
                "profile": "production",
                "device": txt(gif, "gifif"),
                "parent_interface": txt(gif, "if"),
                "remote_address": txt(gif, "remote-addr"),
                "inner_local": txt(gif, "tunnel-local-addr"),
                "inner_remote": f"{txt(gif, 'tunnel-remote-addr')}/{txt(gif, 'tunnel-remote-net')}",
                "description": clean(txt(gif, "descr")),
                "mtu": int(txt(self.ifaces["opt3"], "mtu")),
                "mss": int(txt(self.ifaces["opt3"], "mss")),
                "managed_by": K8S_IPV6,
            } if gif is not None else None,
            "powerd": {k: txt(s, f"powerd_{k}_mode") for k in ("ac", "battery", "normal") if txt(s, f"powerd_{k}_mode")},
        }
        self.counts.append(("sysctl tunables", len(self.root.findall("sysctl/item")), len(out["sysctl"]), ""))
        return out

    def note_unported(self):
        ip = self.root.find("installedpackages")
        s = self.root.find("system")
        for tag, why in (
            ("frrbgp", "FRR BGP: configured but not running; not ported (decision 7)"),
            ("frrbgpneighbors", "FRR BGP neighbors: not ported (decision 7)"),
            ("frrglobalroutemaps", "FRR route maps: not ported (decision 7)"),
            ("openbgpd", "stale OpenBGPD section: not ported"),
            ("freeradius", "FreeRADIUS: not ported (decision 7)"),
            ("freeradiussettings", "FreeRADIUS: not ported (decision 7)"),
            ("freeradiusclients", "FreeRADIUS: not ported (decision 7)"),
            ("freeradiusinterfaces", "FreeRADIUS: not ported (decision 7)"),
            ("freeradiuseapconf", "FreeRADIUS: not ported (decision 7)"),
            ("miniupnpd", "UPnP/NAT-PMP: enabled in config, not running; not ported (decision 7)"),
            ("snortglobal", "Snort: replaced by Suricata, configured fresh (decision 8); rule sets and suppress lists do not carry over"),
            ("snortsync", "Snort XMLRPC sync: not ported"),
            ("shellcmdsettings", "earlyshellcmd 'service wireguardd start': pfSense WireGuard package detail; OPNsense starts WireGuard itself"),
        ):
            if ip.find(tag) is not None:
                self.unmapped.append((f"installedpackages/{tag}", why))
        if s.find("acb") is not None:
            self.unmapped.append(("system/acb", "Netgate AutoConfigBackup: not ported (decision 7); daily backup copies /conf/config.xml"))
        if s.find("authserver") is not None:
            self.unmapped.append(("system/authserver", f"RADIUS auth server '{txt(s, 'authserver/name')}' to 127.0.0.1: not ported with FreeRADIUS"))
        users = [txt(u, "name") for u in s.findall("user")]
        self.unmapped.append(("system/user", f"users {', '.join(users)}: not ported; root password hash and SSH keys come from Vault via the bootstrap config"))
        self.unmapped.append(("system/group", "groups all, admins: OPNsense has its own admins group"))
        self.unmapped.append(("cert / ca", f"{len(self.root.findall('cert'))} certs ('webConfigurator default', FreeRADIUS server) and {len(self.root.findall('ca'))} CA (FreeRADIUS CA): not ported; OPNsense makes its own GUI cert"))
        self.unmapped.append(("cron", f"{len(self.root.findall('cron/item'))} entries, all pfSense system or package jobs (bogons, Snort, RESTAPI cache, ACB upload, periodic); none custom"))
        if txt(self.root, "snmpd/rocommunity"):
            self.unmapped.append(("snmpd", "community set but SNMP disabled; not ported"))
        if self.root.find("dhcrelay6") is not None and not has(self.root.find("dhcrelay6"), "enable"):
            self.unmapped.append(("dhcrelay6", "DHCPv6 relay on lan, not enabled; not ported"))
        self.unmapped.append(("system/pkg_repo_conf_path, already_run_config_upgrade, widgets, rrd, revision, diag",
                              "pfSense internals with no OPNsense meaning"))
        self.unmapped.append(("filter/separator, nat/separator", "GUI separators only"))
        self.unmapped.append(("REST API package (pfSense-pkg-RESTAPI)", "Homepage widget moves to OPNsense's own API (plan, dependents)"))
        self.unmapped.append(("system/dnsserver gateways, dns1host/dns2host",
                              "carried into unbound.yml forwarding (TLS hostnames) and misc.yml; check OPNsense's System > General mapping"))
        self.unmapped.append(("system/webgui ssl-certref, webguicss, logincss, dashboardcolumns, loginshowhost, roaming",
                              "cosmetic or pfSense-specific GUI settings"))

    # ---------- secrets ----------

    def secret_values(self):
        vals = set()
        for e in self.root.iter():
            t = (e.text or "").strip()
            if len(t) >= 8 and SECRET_TAG.search(e.tag):
                vals.add(t)
                for line in t.splitlines():
                    line = line.strip()
                    if len(line) >= 16:
                        vals.add(line)
        return vals


# ---------- output ----------

HEADER = ("# Generated from pfSense config.xml on {date} by scripts/pfsense-to-opnsense.py, then reviewed;\n"
          "# edit this file, do not regenerate.\n")


class Dumper(yaml.SafeDumper):
    pass


def _str(dumper, data):
    style = "|" if "\n" in data else None
    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style=style)


Dumper.add_representer(str, _str)


def ydump(obj):
    return yaml.dump(obj, Dumper=Dumper, sort_keys=False, allow_unicode=True, default_flow_style=False, width=4096)


def render(obj, header, intro=None):
    """YAML text with optional '# ' comments taken from '_comment' keys on list items."""
    parts = [header]
    if intro:
        parts.append("".join(f"# {l}\n" if l else "#\n" for l in intro.splitlines()))
    parts.append("\n")

    def emit(value, key=None, indent=""):
        if isinstance(value, list) and any(isinstance(i, dict) and "_comment" in i for i in value):
            out = f"{indent}{key}:\n" if key is not None else ""
            ind = indent
            for item in value:
                item = dict(item)
                c = item.pop("_comment", None)
                if c:
                    out += "".join(f"{ind}# {l}\n" for l in c.splitlines())
                out += "".join(f"{ind}{l}\n" for l in ydump([item]).splitlines())
            return out
        return "".join(f"{indent}{l}\n" for l in ydump({key: value} if key is not None else value).splitlines())

    if isinstance(obj, dict):
        for k, v in obj.items():
            parts.append(emit(v, k))
    else:
        parts.append(emit(obj))
    return "".join(parts)


INTROS = {
    "addresses.yml": ("Firewall-owned addresses per profile, chosen by the inventory variable opnsense_profile.\n"
                      "Templates refer to them as {{ fw.<key> }}. IPv6 values carry their prefix length;\n"
                      "objects that need the bare address use {{ fw.<key>.split('/')[0] }}.\n"
                      "literal_map lists every pfSense literal the converter replaced with a placeholder."),
    "aliases.yml": "Firewall aliases, in pfSense order.",
    "gateways.yml": ("Gateways, in pfSense order. monitor: false means monitoring is off; null means the\n"
                     "gateway address itself is monitored. profile: production means staging leaves it out."),
    "routes.yml": "Static routes. Routes via a production-only gateway are production-only too.",
    "filter.yml": ("Filter rules in pfSense evaluation order. Semantics follow pfSense:\n"
                   "- interface rules are quick; floating rules are quick only when quick: true\n"
                   "- an empty pfSense type became action: pass, a missing ipprotocol became inet\n"
                   "- source/destination: any | net (interface subnet) | ip (interface address, e.g. wanip)\n"
                   "  | address | alias | self, with optional port and not\n"
                   "- linked_nat_rule: pfSense generated this rule from a port forward. On OPNsense a\n"
                   "  linked rule is created by the port forward (associated_rule: linked), so the\n"
                   "  playbook should not create these a second time\n"
                   "- managed_by: the pfSense playbook that owned the rule; profile: production means\n"
                   "  the rule is not rendered in staging (opt2 WireGuard, opt3 HE gif)"),
    "nat_port_forwards.yml": ("Port forwards (rdr) in pfSense order. associated_rule: linked | pass | none\n"
                              "(pfSense's linked rule, pass-through filtering, or no rule).\n"
                              "natreflection null means the system default (misc.yml nat_reflection)."),
    "nat_outbound.yml": ("Outbound (source) NAT. target null means no translation; {interface: wan} means the\n"
                         "interface address. OPNsense 26.7 calls this Source NAT."),
    "dhcp.yml": ("Kea DHCPv4 per interface. enabled_in: production, so staging keeps DHCP off.\n"
                 "pfSense defaults (gateway, DNS, domain) are written out explicitly."),
    "radvd.yml": ("Router advertisements. enabled_in: production, so staging sends none.\n"
                  "mode is OPNsense's name; pfsense_mode the original. null values mean the daemon default.\n"
                  "pfSense adds a 'route ::/0' option to every RA on its own; OPNsense's radvd does not\n"
                  "unless asked."),
    "unbound.yml": "Unbound DNS resolver. Interfaces are pfSense keys, so the addresses follow the profile.",
    "ntp.yml": "NTP service.",
    "wireguard.yml": ("WireGuard hub. Production only. No private or pre-shared key is stored here;\n"
                      "private_key_vault_field names the field in Vault secret/opnsense the playbook reads. preshared_key: false means none is in use."),
    "tailscale.yml": ("Tailscale (Headscale) node. Top-level values are pfSense's; the profiles block\n"
                      "follows plan decision 12 (staging joins without routes or exit node)."),
    "haproxy.yml": ("HAProxy (os-haproxy). The :2525 test frontend and its pool are left out.\n"
                    "Bind addresses that were firewall literals are placeholders."),
    "netflow.yml": "Flow export. pfSense used softflowd; OPNsense has built-in NetFlow.",
    "syslog.yml": "Remote syslog.",
    "misc.yml": "Settings without a file of their own.",
}


def write_report(c, path, date, files):
    L = []
    a = L.append
    a(f"# pfSense to OPNsense conversion report\n")
    a(f"Generated from pfSense config.xml on {date} by `scripts/pfsense-to-opnsense.py`, then reviewed. "
      "Edit the YAML, do not regenerate.\n")
    a("## Counts\n")
    a("| Section | pfSense | YAML | Note |")
    a("|---|---|---|---|")
    for s, p, y, n in c.counts:
        a(f"| {s} | {p} | {y} | {n} |")
    a("")
    a("## Dropped\n")
    for sec, obj, why in c.dropped:
        a(f"- {sec}: {obj}. {why}.")
    a("")
    a("## Literal firewall addresses replaced\n")
    a("| Object | Field | pfSense | YAML |")
    a("|---|---|---|---|")
    for obj, field, old, new in c.replaced:
        a(f"| {obj} | {field} | `{old}` | `{new}` |")
    a("")
    a("## pfSense defaults written out\n")
    for d in c.defaults:
        a(f"- {d}")
    a("")
    a("## Not mapped\n")
    for k, v in c.unmapped:
        a(f"- `{k}`: {v}")
    a("")
    a("## Secrets needed (names only, none in these files)\n")
    for s in dict.fromkeys(c.secrets_needed):
        a(f"- {s}")
    a("")
    a("## Ambiguous or worth a second look\n")
    for x in c.ambiguous:
        a(f"- {x}")
    a("")
    a("## Files\n")
    for f in files:
        a(f"- `{f}`")
    a("")
    with open(path, "w") as fh:
        fh.write("\n".join(L))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--config", required=True, help="path to a copy of pfSense's config.xml")
    ap.add_argument("--out", required=True, help="output directory, e.g. playbooks/files/opnsense")
    ap.add_argument("--date", default=datetime.date.today().isoformat(), help="date for the file headers")
    args = ap.parse_args()

    root = ET.parse(args.config).getroot()
    c = Converter(root, args.date)
    c.secrets_needed += [
        "OPNsense root password hash (bootstrap config.xml)",
        "OPNsense API key and secret (bootstrap config.xml, then the playbook)",
        "SSH authorized key for root (bootstrap config.xml)",
        "CrowdSec bouncer key from LAPI (os-crowdsec)",
    ]

    filter_rules = c.filter()
    outputs = {
        "addresses.yml": c.addresses(),
        "aliases.yml": {"aliases": c.aliases_yml()},
        "gateways.yml": {"gateways": c.gateways()},
        "routes.yml": {"routes": c.routes()},
        "filter.yml": {"rules": filter_rules},
        "nat_port_forwards.yml": {"port_forwards": c.nat_port_forwards()},
        "nat_outbound.yml": c.nat_outbound(),
        "dhcp.yml": c.dhcp(),
        "radvd.yml": c.radvd(),
        "unbound.yml": c.unbound(),
        "ntp.yml": c.ntp(),
        "wireguard.yml": c.wireguard(),
        "tailscale.yml": c.tailscale(),
        "haproxy.yml": c.haproxy(),
        "netflow.yml": c.netflow(),
        "syslog.yml": c.syslog(),
        "misc.yml": c.misc(),
    }
    c.note_unported()
    c.ambiguous += [
        "NAT port forwards: config.xml has 24 enabled forwards (27 total, 3 disabled); the plan and fact sheet say 23. "
        "After dropping the port-143 forward to 'mailserver' the YAML has 23 enabled, which matches the plan's figure.",
        "filter rule 1775855648 (IPv6 WireGuard site-to-site) passes to 2001:470:6e:43d::2, the firewall's own HE tunnel "
        "address. It is production-only (opt3) and the same in both profiles, so it stays a literal; it is not in literal_map.",
        "WireGuard addresses 10.3.2.1/24 and 10.3.0.1/32 (the opt2 tunnel) and the Unbound ACL for 10.3.0.1/32 stay literal: "
        "they exist only in production and do not change between profiles.",
        "Rules on the 'WireGuard' interface group are marked profile: production as well as opt2/opt3, since the group "
        "has no member without the tunnel. The 'WireGuard' and 'Tailscale' group names are pfSense's; OPNsense's plugins "
        "name their interfaces/groups differently (wireguard, tailscale), so the playbook has to map them.",
        "The two Tailscale filter rules and several outbound NAT rules store a CIDR in <network> (100.64.0.0/10, "
        "10.0.30.0/24, 192.168.1.0/24); pfSense's GUI would store those under <address>. They are written as address: <cidr>.",
        "Outbound NAT rules with no <ipprotocol> are written as inet46, reading pfSense's empty value as 'any'. The "
        "(self) -> 10.0.20.200:53 rule translates to an IPv4 address, so in practice it is IPv4 only.",
        "Outbound NAT on opt1: source (self) to 10.0.20.200/32 udp/53 is translated to 10.0.20.200 port 30054, i.e. the "
        "firewall's own DNS queries to the shared LB leave with the LB's address as source. 10.0.20.200 is not a firewall "
        "address, so it stays literal (the plan's review table lists it among the literals; nothing profile-specific in it). "
        "Worth confirming it is still wanted.",
        "Outbound NAT on opt3 (source any, inet, to opt3ip) has no effect: opt3 has no IPv4 address. Ported as-is.",
        "The eight 'Auto created rule' outbound entries are pfSense's automatic rules copied in when hybrid mode was "
        "chosen. OPNsense's automatic rules produce the same masquerade for its own interface networks; the playbook "
        "could skip them in hybrid mode.",
        "radvd lan is stateless_dhcp (O flag set) but no DHCPv6 server runs on lan, so clients get DNS only from RDNSS. "
        "OPNsense 'stateless' behaves the same way.",
        "dhcp opt4: pfSense offers the firewall address as DNS on the CCTV segment, but Unbound does not listen on opt4 "
        "and the opt4 rule allows only NTP, so that DNS server is unreachable today. Carried over unchanged.",
        "unbound register_dhcp_leases is set, but pfSense 2.7.2's Kea backend does not register leases in Unbound, so "
        "it has no effect today. Enabling the OPNsense equivalent with Kea would be a behaviour change.",
        "HTML entities in descriptions were decoded and em/en dashes and arrows became '-' and '->'.",
        "Port ranges written a:b in pfSense (49152:49252) are normalised to a-b.",
        "sysctl kern.ipc.maxsockbuf=16777216 was set by the FRR package, which is not ported. Kept in misc.yml; "
        "it may not be needed on OPNsense.",
        "misc.yml webgui.alt_hostnames_needed and tailscale.yml profiles come from the plan (review table, decision 12), "
        "not from config.xml.",
    ]

    header = HEADER.format(date=args.date)
    texts = {name: render(obj, header, INTROS.get(name)) for name, obj in outputs.items()}

    secrets = c.secret_values()
    leaks = [(n, s[:6]) for n, t in texts.items() for s in secrets if s in t]
    if leaks:
        sys.exit(f"refusing to write: secret values from config.xml found in {sorted({n for n, _ in leaks})}")

    for name, t in texts.items():
        yaml.safe_load(t)

    os.makedirs(args.out, exist_ok=True)
    for name, t in texts.items():
        with open(os.path.join(args.out, name), "w") as fh:
            fh.write(t)
    write_report(c, os.path.join(args.out, "REPORT.md"), args.date, list(texts) + ["REPORT.md"])
    with open(os.path.join(args.out, "REPORT.md")) as fh:
        rep = fh.read()
    if any(s in rep for s in secrets):
        os.remove(os.path.join(args.out, "REPORT.md"))
        sys.exit("refusing to keep REPORT.md: it contains a secret value")
    print(f"wrote {len(texts) + 1} files to {args.out}")
    print(f"dropped {len(c.dropped)}, replaced {len(c.replaced)} literals, unmapped {len(c.unmapped)}")


if __name__ == "__main__":
    main()
