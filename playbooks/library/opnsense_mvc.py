#!/usr/bin/python
# -*- coding: utf-8 -*-
"""Idempotent client for OPNsense MVC APIs (grid items and settings sections).

Written for OPNsense 26.7 (playbooks/opnsense.yml). It talks to the documented
REST API only and does not need any collection.
"""

from __future__ import annotations

DOCUMENTATION = r"""
module: opnsense_mvc
short_description: Manage OPNsense MVC grid items or settings sections over the REST API
description:
  - C(mode=grid) keeps a list of items (aliases, rules, gateways, ...) in the state given
    by C(items). Items are matched on C(match_key); only the fields given in each item
    are compared and written. With C(prune) the items that are not listed are deleted.
  - C(mode=settings) reads a whole model section with C(get), compares the fields given
    in C(settings) and posts only those with C(set).
  - Option fields come back from the API as dicts of choices with a C(selected) flag;
    they are compared as a set of the selected keys. Booleans are compared as "1"/"0".
  - After a change the module POSTs C(reconfigure) when given.
options:
  base_url: {type: str, required: true, description: "e.g. https://10.0.10.2:8443/api"}
  api_key: {type: str, required: true, no_log: true}
  api_secret: {type: str, required: true, no_log: true}
  validate_certs: {type: bool, default: false}
  timeout: {type: int, default: 60}
  mode: {type: str, default: grid, choices: [grid, settings]}
  controller: {type: str, description: "module/controller prefix, e.g. firewall/alias"}
  item: {type: str, description: "item name used to build endpoints, e.g. item -> search_item, get_item"}
  search: {type: str, description: "override search endpoint (relative to base_url)"}
  get: {type: str, description: "override get endpoint; grid mode appends /<uuid>"}
  add: {type: str}
  set: {type: str, description: "override set endpoint; grid mode appends /<uuid>"}
  delete: {type: str, aliases: [del]}
  item_root: {type: str, description: "payload root key; detected from the get response when omitted"}
  match_key: {type: raw, default: description, description: "field name or list of field names"}
  items: {type: list, elements: dict, default: []}
  prune: {type: bool, default: false}
  prune_match: {type: dict, description: "only prune existing items whose fields match these regexes"}
  settings: {type: dict, description: "settings mode: nested dict of desired fields under item_root"}
  reconfigure: {type: str, description: "endpoint POSTed after a change"}
  reconfigure_always: {type: bool, default: false}
"""

RETURN = r"""
uuids: {description: "match key -> uuid of each desired item (grid mode)", type: dict}
added: {type: list}
updated: {type: list}
deleted: {type: list}
"""

import json
import re

from ansible.module_utils.basic import AnsibleModule
from ansible.module_utils.urls import open_url
from ansible.module_utils.six.moves.urllib.error import HTTPError

UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


class Api:
    def __init__(self, module):
        p = module.params
        self.module = module
        self.base = p["base_url"].rstrip("/")
        self.auth = (p["api_key"], p["api_secret"])
        self.validate = p["validate_certs"]
        self.timeout = p["timeout"]

    def call(self, method, path, data=None):
        url = "%s/%s" % (self.base, path.lstrip("/"))
        body = None
        headers = {"Accept": "application/json"}
        if method == "POST":
            body = json.dumps(data if data is not None else {})
            headers["Content-Type"] = "application/json"
        try:
            resp = open_url(url, method=method, data=body, headers=headers,
                            url_username=self.auth[0], url_password=self.auth[1],
                            force_basic_auth=True, validate_certs=self.validate,
                            timeout=self.timeout)
            raw = resp.read()
        except HTTPError as e:
            self.module.fail_json(msg="%s %s failed: HTTP %s %s" % (method, path, e.code, e.read()[:500]))
        except Exception as e:  # network errors
            self.module.fail_json(msg="%s %s failed: %s" % (method, path, e))
        try:
            return json.loads(raw) if raw else {}
        except ValueError:
            self.module.fail_json(msg="%s %s returned non-JSON: %s" % (method, path, raw[:300]))


def is_choice(x):
    return isinstance(x, dict) and "selected" in x and "value" in x


def is_choice_dict(v):
    """Option field: {key: {value, selected}}."""
    return isinstance(v, dict) and bool(v) and all(is_choice(x) for x in v.values())


def selected_keys(v):
    return [k for k, x in v.items() if str(x.get("selected")) in ("1", "True", "true")]


def normalise(v):
    """Turn a raw get<Item> value into comparable plain data."""
    if is_choice_dict(v):
        return ",".join(selected_keys(v))
    if isinstance(v, dict):
        if not v:
            return ""
        return {k: normalise(x) for k, x in v.items()}
    if isinstance(v, list):
        if v and all(is_choice(x) for x in v):
            # option fields with numeric keys arrive as a JSON list
            return ",".join(str(i) for i, x in enumerate(v) if str(x.get("selected")) in ("1", "True", "true"))
        return "" if not v else ",".join(str(x) for x in v)
    if v is None:
        return ""
    if isinstance(v, bool):
        return "1" if v else "0"
    return str(v)


def desired_value(v):
    """Turn a desired value from YAML into the form the API stores."""
    if isinstance(v, dict):
        return {k: desired_value(x) for k, x in v.items()}
    if isinstance(v, bool):
        return "1" if v else "0"
    if v is None:
        return ""
    if isinstance(v, (list, tuple)):
        return ",".join(str(desired_value(x)) for x in v)
    return str(v)


def differs(cur, want, choice_fields, path=""):
    """Fields of want that differ from cur; returns dict path -> (cur, want)."""
    out = {}
    for k, w in want.items():
        p = path + k
        if k not in cur:
            out[p] = ("<missing field>", w)
            continue
        c = cur[k]
        if isinstance(w, dict):
            if not isinstance(c, dict):
                out[p] = (c, w)
            else:
                out.update(differs(c, w, choice_fields, p + "."))
            continue
        if p in choice_fields:
            if set(filter(None, re.split(r"[,\n]", c))) != set(filter(None, re.split(r"[,\n]", w))):
                out[p] = (c, w)
        elif c != w:
            out[p] = (c, w)
    return out


def choice_paths(raw, path=""):
    out = set()
    if isinstance(raw, dict):
        for k, v in raw.items():
            if is_choice_dict(v) or (isinstance(v, list) and v and all(is_choice(x) for x in v)):
                out.add(path + k)
            elif isinstance(v, dict):
                out |= choice_paths(v, path + k + ".")
    return out


def unknown_fields(template, want, path=""):
    bad = []
    for k, w in want.items():
        if k not in template:
            bad.append(path + k)
        elif isinstance(w, dict) and isinstance(template[k], dict) and not is_choice_dict(template[k]):
            bad += unknown_fields(template[k], w, path + k + ".")
    return bad


def check_saved(module, path, res):
    if not isinstance(res, dict) or res.get("result") not in ("saved", "deleted"):
        module.fail_json(msg="%s was not saved" % path, response=res)


def item_key(item, keys):
    return tuple(desired_value(item.get(k, "")) if not isinstance(item.get(k), dict) else json.dumps(item.get(k), sort_keys=True) for k in keys)


def run_grid(module, api):
    p = module.params
    ctl = (p["controller"] or "").strip("/")
    name = p["item"]
    ep = {}
    for op in ("search", "get", "add", "set", "delete"):
        if p[op]:
            ep[op] = p[op].strip("/")
        elif ctl and name:
            ep[op] = "%s/%s_%s" % (ctl, "del" if op == "delete" else op, name)
        else:
            module.fail_json(msg="endpoint %s not given and controller/item missing" % op)
    keys = p["match_key"] if isinstance(p["match_key"], list) else [p["match_key"]]

    # template: get without uuid returns the defaults; used for the root key and field check
    tmpl_raw = api.call("GET", ep["get"])
    root = p["item_root"] or (list(tmpl_raw.keys())[0] if len(tmpl_raw) == 1 else None)
    if not root or root not in tmpl_raw:
        module.fail_json(msg="cannot determine item_root from %s" % ep["get"], response=tmpl_raw)
    template = tmpl_raw[root]
    choices = choice_paths(template)

    want = []
    for it in p["items"]:
        d = desired_value(it)
        bad = unknown_fields(template, d)
        if bad:
            module.fail_json(msg="unknown field(s) %s for %s" % (bad, root), item=it)
        want.append(d)

    res = api.call("POST", ep["search"], {"current": 1, "rowCount": -1, "searchPhrase": ""})
    rows = res.get("rows", []) if isinstance(res, dict) else []
    rows = [r for r in rows if UUID_RE.match(str(r.get("uuid", "")))]

    current = []
    for r in rows:
        raw = api.call("GET", "%s/%s" % (ep["get"], r["uuid"])).get(root, {})
        current.append({"uuid": r["uuid"], "raw": raw, "norm": normalise(raw)})

    # pair desired and current by key; duplicates pair in order
    pool = {}
    for c in current:
        pool.setdefault(item_key(c["norm"], keys), []).append(c)

    changed = False
    added, updated, deleted, uuids = [], [], [], {}
    before_list, after_list = [], []
    plan = []
    for w in want:
        k = item_key(w, keys)
        match = pool.get(k, [])
        c = match.pop(0) if match else None
        label = "|".join(k)
        if c is None:
            plan.append(("add", w, None, label))
        else:
            diff = differs(c["norm"], w, choices)
            plan.append(("set" if diff else "ok", w, c, label, diff))
    leftovers = [c for lst in pool.values() for c in lst]
    if p["prune_match"]:
        def matches(c):
            for f, rx in p["prune_match"].items():
                if not re.search(rx, str(c["norm"].get(f, ""))):
                    return False
            return True
        leftovers = [c for c in leftovers if matches(c)]
    if not p["prune"]:
        leftovers = []

    for entry in plan:
        action, w, c, label = entry[:4]
        if action == "add":
            changed = True
            added.append(label)
            after_list.append({label: w})
            if module.check_mode:
                uuids[label] = "check-mode-" + label
                continue
            r = api.call("POST", ep["add"], {root: w})
            check_saved(module, ep["add"], r)
            uuids[label] = r.get("uuid")
        elif action == "set":
            diff = entry[4]
            changed = True
            updated.append({label: {f: {"before": b, "after": a} for f, (b, a) in diff.items()}})
            before_list.append({label: {f: b for f, (b, a) in diff.items()}})
            after_list.append({label: {f: a for f, (b, a) in diff.items()}})
            uuids[label] = c["uuid"]
            if not module.check_mode:
                r = api.call("POST", "%s/%s" % (ep["set"], c["uuid"]), {root: w})
                check_saved(module, ep["set"], r)
        else:
            uuids[label] = c["uuid"]

    for c in leftovers:
        changed = True
        label = "|".join(item_key(c["norm"], keys))
        deleted.append(label)
        before_list.append({label: "present"})
        if not module.check_mode:
            r = api.call("POST", "%s/%s" % (ep["delete"], c["uuid"]), {})
            check_saved(module, ep["delete"], r)

    reconf = None
    if p["reconfigure"] and (changed or p["reconfigure_always"]) and not module.check_mode:
        reconf = api.call("POST", p["reconfigure"], {})

    diff = {"before": json.dumps(before_list, indent=1) + "\n", "after": json.dumps(after_list, indent=1) + "\n"}
    module.exit_json(changed=changed, uuids=uuids, added=added, updated=updated, deleted=deleted,
                     reconfigure=reconf, diff=diff)


def run_settings(module, api):
    p = module.params
    ctl = (p["controller"] or "").strip("/")
    get_ep = (p["get"] or ctl + "/get").strip("/")
    set_ep = (p["set"] or ctl + "/set").strip("/")
    raw = api.call("GET", get_ep)
    root = p["item_root"] or (list(raw.keys())[0] if len(raw) == 1 else None)
    if not root or root not in raw:
        module.fail_json(msg="cannot determine item_root from %s" % get_ep, response=raw)
    cur_raw = raw[root]
    want = desired_value(p["settings"] or {})
    bad = unknown_fields(cur_raw, want)
    if bad:
        module.fail_json(msg="unknown setting(s) %s under %s" % (bad, root))
    diff = differs(normalise(cur_raw), want, choice_paths(cur_raw))
    changed = bool(diff)
    if changed and not module.check_mode:
        r = api.call("POST", set_ep, {root: want})
        check_saved(module, set_ep, r)
    reconf = None
    if p["reconfigure"] and (changed or p["reconfigure_always"]) and not module.check_mode:
        reconf = api.call("POST", p["reconfigure"], {})
    module.exit_json(changed=changed, reconfigure=reconf,
                     updated={f: {"before": b, "after": a} for f, (b, a) in diff.items()},
                     diff={"before": json.dumps({f: b for f, (b, a) in diff.items()}, indent=1) + "\n",
                           "after": json.dumps({f: a for f, (b, a) in diff.items()}, indent=1) + "\n"})


def main():
    module = AnsibleModule(
        argument_spec=dict(
            base_url=dict(type="str", required=True),
            api_key=dict(type="str", required=True, no_log=True),
            api_secret=dict(type="str", required=True, no_log=True),
            validate_certs=dict(type="bool", default=False),
            timeout=dict(type="int", default=60),
            mode=dict(type="str", default="grid", choices=["grid", "settings"]),
            controller=dict(type="str"),
            item=dict(type="str"),
            search=dict(type="str"),
            get=dict(type="str"),
            add=dict(type="str"),
            set=dict(type="str"),
            delete=dict(type="str", aliases=["del"]),
            item_root=dict(type="str"),
            match_key=dict(type="raw", default="description"),
            items=dict(type="list", elements="dict", default=[]),
            prune=dict(type="bool", default=False),
            prune_match=dict(type="dict"),
            settings=dict(type="dict"),
            reconfigure=dict(type="str"),
            reconfigure_always=dict(type="bool", default=False),
        ),
        supports_check_mode=True,
    )
    api = Api(module)
    if module.params["mode"] == "grid":
        run_grid(module, api)
    else:
        run_settings(module, api)


if __name__ == "__main__":
    main()
