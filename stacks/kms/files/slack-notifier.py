#!/usr/bin/env python3
"""
Tail vlmcsd verbose log; post a Slack message per activation, and expose
Prometheus metrics on /metrics for activation counts.

vlmcsd verbose output emits a multi-line block per request:
  <ts>: IPv4 connection accepted: <ip>:<port>.
  <ts>: <<< Incoming KMS request
  <ts>: Application ID    : <uuid> (<name>)
  <ts>: Activation ID (Product): <uuid> (<product>)
  <ts>: Workstation name  : <hostname>
  ...
  <ts>: IPv4 connection closed: <ip>:<port>.

A bare TCP open/close pair (no Application/Activation lines) is a probe —
typically Uptime Kuma's port-type monitor on windows-kms.kms:1688. Probes
are counted in `kms_connection_probes_total` but never posted to Slack.

Real activations dedupe by (client_ip, product) within DEDUP_WINDOW_SECONDS
to avoid spam from Windows' default 7-day re-activation cycle.

Prometheus metrics (text format, no client_ip label — cardinality):
  kms_activations_total{product, status}        counter
  kms_activations_dedup_skipped_total{product}  counter
  kms_connection_probes_total{source}           counter (probe-only conns)
  kms_last_activation_timestamp_seconds         gauge
  kms_slack_notifier_up                         gauge (heartbeat)
"""
import ipaddress
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import OrderedDict
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG_PATH = os.environ.get("VLMCSD_LOG", "/var/log/vlmcsd/vlmcsd.log")
WEBHOOK = os.environ["SLACK_WEBHOOK_URL"]
CHANNEL = os.environ.get("SLACK_CHANNEL", "#alerts")
DEDUP_WINDOW = int(os.environ.get("DEDUP_WINDOW_SECONDS", "3600"))
DEDUP_MAX = 4096
METRICS_PORT = int(os.environ.get("METRICS_PORT", "9101"))

OPEN_RE = re.compile(r":\s*IPv[46] connection accepted:\s*([0-9a-f.:\[\]]+):\d+")
CLOSE_RE = re.compile(r":\s*IPv[46] connection closed:\s*([0-9a-f.:\[\]]+):\d+")
APP_RE = re.compile(r":\s*Application ID\s*:\s*[0-9a-f-]+\s*\(([^)]+)\)")
PROD_RE = re.compile(r":\s*Activation ID \(Product\)\s*:\s*[0-9a-f-]+\s*\(([^)]+)\)")
HOST_RE = re.compile(r":\s*Workstation name\s*:\s*(.+?)\s*$")
STATUS_RE = re.compile(r":\s*Licensing status\s*:\s*\d+\s*\((.+?)\)\s*$")

# Pod CIDR (Calico, kube-proxy SNAT-free intra-cluster traffic) and cluster
# LAN (kube-proxy SNATs ETP=Cluster external traffic to a node IP). Anything
# else is a real client IP that arrived via ETP=Local or pod-to-svc routing.
POD_CIDR = ipaddress.ip_network("10.10.0.0/16")
CLUSTER_LAN_CIDR = ipaddress.ip_network("10.0.20.0/24")

_metrics_lock = threading.Lock()
_activations: dict = {}
_dedup_skipped: dict = {}
_probes: dict = {}
_last_activation_ts: float = 0.0


def _esc(value: str) -> str:
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def classify_source(ip: str) -> str:
    """Return 'internal_pod', 'cluster_node', or 'external' for a vlmcsd-logged IP."""
    raw = ip.strip().strip("[]")
    try:
        addr = ipaddress.ip_address(raw)
    except ValueError:
        return "external"
    if isinstance(addr, ipaddress.IPv4Address):
        if addr in POD_CIDR:
            return "internal_pod"
        if addr in CLUSTER_LAN_CIDR:
            return "cluster_node"
    return "external"


def is_probe(state: dict) -> bool:
    """A connection that closed without any Application/Activation block."""
    return "app" not in state and "product" not in state


class Event:
    __slots__ = ("kind", "ip", "source", "app", "product", "host", "status")

    def __init__(self, kind: str, ip: str, source: str, *, app: str = "",
                 product: str = "", host: str = "", status: str = "") -> None:
        self.kind = kind
        self.ip = ip
        self.source = source
        self.app = app
        self.product = product
        self.host = host
        self.status = status


def process_line(line: str, state: dict):
    """Drive the parser one line at a time. Returns (new_state, event_or_None).

    On `connection accepted`, a new state dict is started.
    On `connection closed`, an Event is emitted and state is reset.
    Other lines accumulate fields into the current state.
    """
    if (m := OPEN_RE.search(line)):
        return {"ip": m.group(1)}, None
    if not state:
        return state, None
    if (m := APP_RE.search(line)):
        state["app"] = m.group(1)
        return state, None
    if (m := PROD_RE.search(line)):
        state["product"] = m.group(1)
        return state, None
    if (m := HOST_RE.search(line)):
        state["host"] = m.group(1)
        return state, None
    if (m := STATUS_RE.search(line)):
        state["status"] = m.group(1)
        return state, None
    if CLOSE_RE.search(line):
        ip = state.get("ip", "?")
        source = classify_source(ip)
        if is_probe(state):
            event = Event("probe", ip, source)
        else:
            event = Event(
                "activation", ip, source,
                app=state.get("app", ""),
                product=state.get("product", state.get("app", "unknown")),
                host=state.get("host", "?"),
                status=state.get("status", "unknown"),
            )
        return {}, event
    return state, None


def record_activation(product: str, status: str) -> None:
    global _last_activation_ts
    with _metrics_lock:
        key = (product, status)
        _activations[key] = _activations.get(key, 0) + 1
        _last_activation_ts = time.time()


def record_dedup_skip(product: str) -> None:
    with _metrics_lock:
        _dedup_skipped[product] = _dedup_skipped.get(product, 0) + 1


def record_probe(source: str) -> None:
    with _metrics_lock:
        _probes[source] = _probes.get(source, 0) + 1


def render_metrics() -> bytes:
    out = []
    with _metrics_lock:
        activations = dict(_activations)
        dedup_skipped = dict(_dedup_skipped)
        probes = dict(_probes)
        last_ts = _last_activation_ts

    out.append("# HELP kms_activations_total KMS activation events that resulted in a Slack post.")
    out.append("# TYPE kms_activations_total counter")
    for (product, status), count in sorted(activations.items()):
        out.append(
            f'kms_activations_total{{product="{_esc(product)}",status="{_esc(status)}"}} {count}'
        )

    out.append("# HELP kms_activations_dedup_skipped_total KMS activation events suppressed by dedup window.")
    out.append("# TYPE kms_activations_dedup_skipped_total counter")
    for product, count in sorted(dedup_skipped.items()):
        out.append(f'kms_activations_dedup_skipped_total{{product="{_esc(product)}"}} {count}')

    out.append("# HELP kms_connection_probes_total Probe-only TCP connections (open+close, no KMS RPC).")
    out.append("# TYPE kms_connection_probes_total counter")
    for source, count in sorted(probes.items()):
        out.append(f'kms_connection_probes_total{{source="{_esc(source)}"}} {count}')

    out.append("# HELP kms_last_activation_timestamp_seconds Unix ts of the last non-deduped activation.")
    out.append("# TYPE kms_last_activation_timestamp_seconds gauge")
    out.append(f"kms_last_activation_timestamp_seconds {last_ts}")

    out.append("# HELP kms_slack_notifier_up 1 while the notifier process is running.")
    out.append("# TYPE kms_slack_notifier_up gauge")
    out.append("kms_slack_notifier_up 1")

    return ("\n".join(out) + "\n").encode("utf-8")


class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok\n")
            return
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        body = render_metrics()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args, **kwargs):
        pass


def start_metrics_server() -> None:
    server = HTTPServer(("0.0.0.0", METRICS_PORT), MetricsHandler)
    print(f"[slack-notifier] metrics on :{METRICS_PORT}/metrics", flush=True)
    server.serve_forever()


def slack_post(text: str) -> None:
    payload = json.dumps({"channel": CHANNEL, "text": text, "username": "kms.viktorbarzin.me", "icon_emoji": ":computer:"}).encode("utf-8")
    req = urllib.request.Request(WEBHOOK, data=payload, headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=10).read()
    except urllib.error.URLError as exc:
        print(f"[slack] post failed: {exc}", file=sys.stderr)


class DedupCache(OrderedDict):
    def should_send(self, key: str) -> bool:
        now = time.time()
        while self and (now - next(iter(self.values()))) > DEDUP_WINDOW:
            self.popitem(last=False)
        if key in self and (now - self[key]) < DEDUP_WINDOW:
            return False
        if len(self) >= DEDUP_MAX:
            self.popitem(last=False)
        self[key] = now
        self.move_to_end(key)
        return True


def follow(path: str):
    while not os.path.exists(path):
        time.sleep(1)
    fh = open(path, "r", encoding="utf-8", errors="replace")
    fh.seek(0, 2)
    inode = os.fstat(fh.fileno()).st_ino
    while True:
        line = fh.readline()
        if line:
            yield line.rstrip("\n")
            continue
        time.sleep(0.5)
        try:
            new_inode = os.stat(path).st_ino
            if new_inode != inode:
                fh.close()
                fh = open(path, "r", encoding="utf-8", errors="replace")
                inode = new_inode
        except FileNotFoundError:
            time.sleep(1)


def handle_event(event: "Event", dedup: "DedupCache") -> None:
    if event.kind == "probe":
        record_probe(event.source)
        print(
            f"[slack-notifier] probe: ip={event.ip} source={event.source}",
            flush=True,
        )
        return

    key = f"{event.ip}|{event.product}"
    if not dedup.should_send(key):
        record_dedup_skip(event.product)
        print(
            f"[slack-notifier] dedup-skip: ip={event.ip} product={event.product!r}",
            flush=True,
        )
        return

    text = (
        f":computer: KMS activation\n"
        f"• *Client*: `{event.ip}` ({event.source})\n"
        f"• *Workstation*: `{event.host}`\n"
        f"• *Product*: `{event.product}`\n"
        f"• *Status before*: {event.status}"
    )
    slack_post(text)
    record_activation(event.product, event.status)
    print(
        f"[slack-notifier] sent: ip={event.ip} source={event.source} "
        f"product={event.product!r} host={event.host!r}",
        flush=True,
    )


def main() -> None:
    threading.Thread(target=start_metrics_server, daemon=True).start()

    dedup = DedupCache()
    print(f"[slack-notifier] tailing {LOG_PATH}, posting to {CHANNEL} via Slack", flush=True)
    state: dict = {}

    for line in follow(LOG_PATH):
        state, event = process_line(line, state)
        if event is not None:
            handle_event(event, dedup)


if __name__ == "__main__":
    main()
