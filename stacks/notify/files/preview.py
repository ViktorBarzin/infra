"""Test notifications: an alert rule as it would look when it fires.

The settings page's Test button (page.py) sends the signed-in person one
Notification built the same way as a real one (adapter.build), from an
alert that looks as real as we can make it, best source first:

  1. firing now      Prometheus's own alert: its labels, value and the
                     annotations Prometheus rendered.
  2. last fired      the rule's expression evaluated at the last time ALERTS
                     shows it firing, within Prometheus's 26 weeks.
  3. made-up value   for a rule `A > N` that never fired: A's current series
     on real labels  for the labels, and a value just past N.
  4. made-up values  label values that exist on the rule's metrics, else
                     "example", and a value past the threshold, else 1.

For 2 to 4 the annotations are rendered here with the subset of Prometheus's
Go templates the rules use: $labels.x, $value, printf, humanize,
humanize1024, humanizePercentage, humanizeDuration, and
`with query "..."` ... `. | first | value` ... `end`.
"""

import ast
import datetime
import math
import operator
import re
import urllib.parse

from subs import Unavailable, _get_json

LAST_FIRED = 'max(max_over_time(timestamp(ALERTS{alertname="%s",alertstate="firing"})[26w:1h]))'
COMPARISON = re.compile(r"^(?P<left>.+?)\s*(?P<op>>=|<=|==|!=|>|<)\s*(?P<n>[-+0-9.eE*/ ()]+)$", re.S)
NUMBER_EXPR = re.compile(r"^[-+0-9.eE*/ ()]+$")
PROMQL_WORDS = {
    "sum", "min", "max", "avg", "count", "by", "without", "on", "ignoring", "group_left", "group_right",
    "and", "or", "unless", "bool", "offset", "rate", "irate", "increase", "delta", "deriv", "time",
    "abs", "absent", "absent_over_time", "clamp_min", "clamp_max", "round", "floor", "ceil", "topk",
    "bottomk", "quantile", "histogram_quantile", "label_replace", "label_join", "vector", "scalar",
    "timestamp", "changes", "resets", "predict_linear", "avg_over_time", "max_over_time",
    "min_over_time", "sum_over_time", "count_over_time", "last_over_time", "present_over_time",
    "stddev", "stdvar", "count_values", "group", "sort", "sort_desc", "ln", "log2", "log10", "exp", "sqrt",
}


class Prometheus:
    def __init__(self, base: str, timeout: float = 10):
        self.base = base.rstrip("/")
        self.timeout = timeout

    def query(self, expr: str, at=None) -> list:
        params = {"query": expr}
        if at is not None:
            params["time"] = "%.3f" % at
        data = _get_json(self.base + "/api/v1/query?" + urllib.parse.urlencode(params), {}, self.timeout)
        result = (data.get("data") or {}).get("result") or []
        rows = []
        for r in result if isinstance(result, list) else []:
            try:
                rows.append({"metric": r.get("metric") or {}, "value": float(r["value"][1])})
            except (KeyError, ValueError, TypeError):
                continue
        return rows

    def values(self, label: str, metrics: list) -> list:
        params = [("match[]", '{__name__=~"%s"}' % "|".join(metrics))] if metrics else []
        url = self.base + "/api/v1/label/%s/values?%s" % (urllib.parse.quote(label), urllib.parse.urlencode(params))
        return _get_json(url, {}, self.timeout).get("data") or []


# --- Go value formatting, as Prometheus's template functions do it ---------


def go_float(v: float) -> str:
    if v == int(v) and abs(v) < 1e21:
        return str(int(v))
    return repr(v)


def g4(v: float) -> str:
    """Go's %.4g."""
    s = "%.4g" % v
    if "e" in s:
        mant, exp = s.split("e")
        s = "%se%s%02d" % (mant, exp[0], abs(int(exp)))
    return s


def humanize(v: float) -> str:
    if v == 0 or math.isnan(v) or math.isinf(v):
        return g4(v)
    if abs(v) >= 1:
        prefix = ""
        for p in ("k", "M", "G", "T", "P", "E", "Z", "Y"):
            if abs(v) < 1000:
                break
            prefix, v = p, v / 1000
        return g4(v) + prefix
    prefix = ""
    for p in ("m", "u", "n", "p", "f", "a", "z", "y"):
        if abs(v) >= 1:
            break
        prefix, v = p, v * 1000
    return g4(v) + prefix


def humanize1024(v: float) -> str:
    if abs(v) <= 1:
        return g4(v)
    prefix = ""
    for p in ("Ki", "Mi", "Gi", "Ti", "Pi", "Ei", "Zi", "Yi"):
        if abs(v) < 1024:
            break
        prefix, v = p, v / 1024
    return g4(v) + prefix


def humanize_percentage(v: float) -> str:
    return g4(v * 100) + "%"


def humanize_duration(v: float) -> str:
    if math.isnan(v) or math.isinf(v):
        return g4(v)
    if v == 0:
        return "0s"
    if abs(v) >= 1:
        sign = "-" if v < 0 else ""
        v = abs(v)
        seconds = int(v) % 60
        minutes = int(v) // 60 % 60
        hours = int(v) // 3600 % 24
        days = int(v) // 86400
        if days:
            return "%s%dd %dh %dm %ds" % (sign, days, hours, minutes, seconds)
        if hours:
            return "%s%dh %dm %ds" % (sign, hours, minutes, seconds)
        if minutes:
            return "%s%dm %ds" % (sign, minutes, seconds)
        return "%s%ss" % (sign, g4(v))
    prefix = ""
    for p in ("m", "u", "n", "p", "f", "a", "z", "y"):
        if abs(v) >= 1:
            break
        prefix, v = p, v * 1000
    return "%s%ss" % (g4(v), prefix)


def go_printf(fmt: str, *args) -> str:
    args = list(args)

    def verb(m):
        flags, kind = m.group(1), m.group(2)
        if kind == "%":
            return "%"
        a = args.pop(0) if args else ""
        if kind == "v":
            return go_float(a) if isinstance(a, float) else str(a)
        if kind == "s":
            return go_float(a) if isinstance(a, float) else str(a)
        if kind == "q":
            return '"%s"' % a
        if kind == "d":
            return ("%" + flags + "d") % int(float(a))
        return ("%" + flags + kind) % float(a)

    return re.sub(r"%([-+ 0#]*\d*(?:\.\d+)?)([vdsqfFgGeEx%])", verb, fmt)


FUNCS = {
    "humanize": humanize,
    "humanize1024": humanize1024,
    "humanizePercentage": humanize_percentage,
    "humanizeDuration": humanize_duration,
    "toUpper": lambda s: str(s).upper(),
    "toLower": lambda s: str(s).lower(),
    "title": lambda s: str(s).title(),
    "first": lambda rows: rows[0] if rows else None,
    "value": lambda row: row["value"],
}


# --- A small Go template evaluator ------------------------------------------

ACTION = re.compile(r"\{\{(-?)\s*(.*?)\s*(-?)\}\}", re.S)


class Skip(Exception):
    """An action this evaluator does not know; it renders as nothing."""


def _words(command: str) -> list:
    return re.findall(r'"(?:\\.|[^"\\])*"|`[^`]*`|\S+', command)


def _pipes(pipeline: str) -> list:
    return [p.strip() for p in re.findall(r'(?:"(?:\\.|[^"\\])*"|`[^`]*`|[^|"`])+', pipeline)]


def _parse(text: str) -> list:
    """-> nodes: ("text", s) | ("expr", pipeline) | ("with", pipeline, nodes, else_nodes)."""
    root, stack, pos, trim_next = [], [], 0, False
    current = root
    withs = []  # the open `with` nodes, innermost last
    for m in ACTION.finditer(text):
        chunk = text[pos:m.start()]
        if trim_next:
            chunk = chunk.lstrip()
        if m.group(1):
            chunk = chunk.rstrip()
        if chunk:
            current.append(("text", chunk))
        action, trim_next, pos = m.group(2), bool(m.group(3)), m.end()
        head = action.split(None, 1)[0] if action else ""
        if head == "with":
            node = ("with", action[4:].strip(), [], [])
            current.append(node)
            stack.append(current)
            withs.append(node)
            current = node[2]
        elif head == "else" and action == "else" and withs:
            current = withs[-1][3]
        elif head == "end":
            current = stack.pop() if stack else root
            if withs:
                withs.pop()
        elif head in ("if", "range", "else", "define", "template", "block"):
            current.append(("skip", action))
        else:
            current.append(("expr", action))
    chunk = text[pos:]
    if trim_next:
        chunk = chunk.lstrip()
    if chunk:
        current.append(("text", chunk))
    return root


def render(text: str, labels: dict, value: float, prom, at=None) -> str:
    def operand(word, dot):
        if word.startswith('"'):
            return bytes(word[1:-1], "utf-8").decode("unicode_escape")
        if word.startswith("`"):
            return word[1:-1]  # a Go raw string: no escapes
        if word in ("$value", ".Value"):
            return value
        if word == ".":
            return dot
        for prefix in ("$labels.", ".Labels."):
            if word.startswith(prefix):
                return labels.get(word[len(prefix):], "")
        if re.fullmatch(r"-?\d+(\.\d+)?", word):
            return float(word)
        raise Skip(word)

    def command(cmd, dot, piped):
        words = _words(cmd)
        name, rest = words[0], words[1:]
        if name == "query":
            return prom.query(operand(rest[0], dot), at)
        if name == "printf":
            args = [operand(w, dot) for w in rest] + ([] if piped is _NONE else [piped])
            return go_printf(args[0], *args[1:])
        if name == "label":
            row = piped if piped is not _NONE else operand(rest[1], dot)
            return (row or {}).get("metric", {}).get(operand(rest[0], dot), "")
        if name in FUNCS:
            args = [operand(w, dot) for w in rest] + ([] if piped is _NONE else [piped])
            return FUNCS[name](*args)
        if rest or piped is not _NONE:
            raise Skip(name)
        return operand(name, dot)

    def pipeline(p, dot):
        out = _NONE
        for cmd in _pipes(p):
            out = command(cmd, dot, out)
        return out

    def show(v):
        if isinstance(v, float):
            return go_float(v)
        if v is None:
            return "<no value>"
        return str(v)

    def walk(nodes, dot):
        out = []
        for node in nodes:
            try:
                if node[0] == "text":
                    out.append(node[1])
                elif node[0] == "expr":
                    out.append(show(pipeline(node[1], dot)))
                elif node[0] == "with":
                    v = pipeline(node[1], dot)
                    if v not in (None, "", [], 0, 0.0):
                        out.append(walk(node[2], v))
                    else:
                        out.append(walk(node[3], dot))
            except (Skip, Unavailable, IndexError, KeyError, TypeError, ValueError):
                continue
        return "".join(out)

    return walk(_parse(text), None)


_NONE = object()


# --- Picking the values ------------------------------------------------------


def last_fired_query(alertname: str) -> str:
    return LAST_FIRED % alertname


def split_comparison(expr: str):
    """`A > N` -> (A, ">", N) for a plain top-level comparison, else None."""
    if re.search(r"\b(and|or|unless)\b", expr):
        return None
    m = COMPARISON.match(expr.strip())
    if not m or not NUMBER_EXPR.match(m.group("n")):
        return None
    try:
        n = _arith(ast.parse(m.group("n").strip(), mode="eval").body)
    except (SyntaxError, ZeroDivisionError, ValueError):
        return None
    return m.group("left").strip(), m.group("op"), n


_OPS = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul, ast.Div: operator.truediv}


def _arith(node) -> float:
    """A threshold such as `30 * 86400`: numbers and + - * / only."""
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
        return float(node.value)
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.USub, ast.UAdd)):
        v = _arith(node.operand)
        return -v if isinstance(node.op, ast.USub) else v
    if isinstance(node, ast.BinOp) and type(node.op) in _OPS:
        return _OPS[type(node.op)](_arith(node.left), _arith(node.right))
    raise ValueError("not arithmetic")


def past_threshold(op: str, n: float) -> float:
    if op in (">", ">="):
        return n * 1.2 if n > 0 else n + 1.0
    if op in ("<", "<="):
        return n * 0.8 if n > 0 else n - 1.0
    return n


def _metrics(expr: str) -> list:
    names = re.findall(r"(?<![\w\"'=~.])([a-zA-Z_:][a-zA-Z0-9_:]*)\s*(?=[{\[)\s]|$)", expr)
    return sorted({n for n in names if n not in PROMQL_WORDS and not re.fullmatch(r"\d.*", n)})


def _referenced(annotations: dict) -> list:
    text = " ".join(annotations.values())
    return sorted(set(re.findall(r"(?:\$labels|\.Labels)\.(\w+)", text)))


def _build(rule, series_labels, value, prom, at, source):
    labels = {k: v for k, v in series_labels.items() if k not in ("__name__", "alertstate")}
    labels.update(rule.get("labels") or {})
    labels["alertname"] = rule["name"]
    annotations = {k: render(v, labels, value, prom, at) for k, v in (rule.get("annotations") or {}).items()}
    return {"alert": {"status": "firing", "labels": labels, "annotations": annotations}, "source": source}


def sample(rule: dict, prom, now: float) -> dict:
    """-> {"alert": an Alertmanager-shaped firing alert, "source": where its values came from}."""
    active = sorted(rule.get("alerts") or [], key=lambda a: a.get("state") != "firing")
    if active:
        a = active[0]
        return {
            "alert": {"status": "firing", "labels": dict(a.get("labels") or {}), "annotations": dict(a.get("annotations") or {})},
            "source": "%s now" % (a.get("state") or "firing"),
        }

    expr = rule.get("query") or ""
    comparison = split_comparison(expr)
    try:
        fired = prom.query(last_fired_query(rule["name"]))
        if fired and fired[0]["value"] > 0:
            at = fired[0]["value"]
            when = datetime.datetime.fromtimestamp(at, datetime.timezone.utc).strftime("%-d %b %Y %H:%M UTC")
            rows = prom.query(expr, at) if expr else []
            if rows:
                return _build(rule, rows[0]["metric"], rows[0]["value"], prom, at, "last fired " + when)
            seen = prom.query('ALERTS{alertname="%s",alertstate="firing"}' % rule["name"], at)
            value = past_threshold(comparison[1], comparison[2]) if comparison else 1.0
            return _build(rule, seen[0]["metric"] if seen else {}, value, prom, at, "labels from " + when + ", made-up value")
        if comparison:
            rows = prom.query(comparison[0])
            if rows:
                value = past_threshold(comparison[1], comparison[2])
                return _build(rule, rows[0]["metric"], value, prom, None, "made-up value on real labels")
    except Unavailable:
        pass

    labels = {}
    metrics = _metrics(expr)
    for name in _referenced(rule.get("annotations") or {}):
        if name in (rule.get("labels") or {}):
            continue
        found = []
        # Values on the rule's own metrics first, then any value of that label.
        for match in ([metrics] if metrics else []) + [[]]:
            try:
                found = prom.values(name, match)
            except Unavailable:
                found = []
            if found:
                break
        labels[name] = found[0] if found else "example"
    value = past_threshold(comparison[1], comparison[2]) if comparison else 1.0
    return _build(rule, labels, value, prom, None, "made-up values")
