"""Forgejo Turnstile canary gate (48 h A/B test, see stacks/turnstile-gate/main.tf).

Traefik forwardAuth -> nginx shim -> GET /auth here. The answer is always 200
unless the visitor is an untrusted browser asking for an HTML page, holds no
pass cookie and its IP hashes into the Turnstile arm; then it is 403 with the
Turnstile page. A 200 carrying X-Turnstile-Pass: 1 tells Anubis to ALLOW.

GET  /auth            forwardAuth decision (stateless)
POST /_gate/verify    {"token": "..."} -> siteverify -> pass cookie (30 days)
POST /_gate/fallback  {"reason": "..."} -> fallback cookie (1 h): the visitor gets Anubis, never a pass
GET  /healthz         readiness

Every decision worth measuring is one JSON line on stdout, for Loki.
"""

import base64
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Callable, Union

SITEVERIFY = "https://challenges.cloudflare.com/turnstile/v0/siteverify"
PASS_COOKIE = "tsgate"
FALLBACK_COOKIE = "tsgate_fb"
PASS_HEADER = "X-Turnstile-Pass"
KIND_PASS = "pass"
KIND_FALLBACK = "fallback"
ARM_TURNSTILE = "turnstile"
ARM_ANUBIS = "anubis"
PASS_TTL = 30 * 24 * 3600
FALLBACK_TTL = 3600
TOKEN_TTL = 300  # Turnstile token lifetime; siteverify accepts reuse within it (measured), so we refuse it
MAX_TOKEN_LEN = 2048
SITEVERIFY_TIMEOUT = 5.0

# Mirrors var.trusted_local_cidrs in modules/kubernetes/anubis_instance, the
# canonical list. Matched against X-Real-Ip, which the real-ip plugin sets from
# the TCP peer, so it cannot be forged from the internet.
DEFAULT_TRUSTED_CIDRS = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "fc00::/7", "fe80::/10"]

# Clients that say they are a bot (or are not a browser at all) keep today's
# behaviour: Anubis verifies the good crawlers and denies the AI ones.
DECLARED_BOT = re.compile(r"bot|crawl|spider|slurp", re.IGNORECASE)

Network = Union[ipaddress.IPv4Network, ipaddress.IPv6Network]
Address = Union[ipaddress.IPv4Address, ipaddress.IPv6Address]


@dataclass
class Config:
    sitekey: str
    secret: str
    cookie_key: bytes
    arm_salt: str
    host: str
    action: str
    trusted: "list[Network]"


@dataclass
class Request:
    method: str
    real_ip: str
    accept: str
    ua: str
    cookie: str
    uri: str


@dataclass
class Decision:
    status: int
    reason: str
    headers: "dict[str, str]" = field(default_factory=dict)
    body: str = ""
    arm: str = ""
    cookie_id: str = ""


@dataclass
class VerifyResult:
    admitted: bool
    event: str
    set_cookie: str = ""
    detail: dict = field(default_factory=dict)


SiteverifyFn = Callable[[dict, float], dict]


def parse_cidrs(value: str) -> "list[Network]":
    return [ipaddress.ip_network(c.strip()) for c in value.split(",") if c.strip()]


def parse_cookies(header: str) -> "dict[str, str]":
    out: "dict[str, str]" = {}
    for part in header.split(";"):
        name, sep, value = part.strip().partition("=")
        if sep and name:
            out[name] = value
    return out


def wants_html(accept: str) -> bool:
    for item in accept.split(","):
        media, *params = [p.strip() for p in item.split(";")]
        if media.lower() != "text/html":
            continue
        q = 1.0
        for p in params:
            k, _, v = p.partition("=")
            if k.strip().lower() == "q":
                try:
                    q = float(v)
                except ValueError:
                    q = 0.0
        if q > 0:
            return True
    return False


def is_browser(ua: str) -> bool:
    return ua.startswith("Mozilla/") and not DECLARED_BOT.search(ua)


def parse_ip(value: str) -> "Address | None":
    try:
        addr = ipaddress.ip_address(value.strip())
    except ValueError:
        return None
    if isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped:
        return addr.ipv4_mapped
    return addr


def arm_for(cfg: Config, ip: str) -> str:
    addr = parse_ip(ip)
    key = ip
    if isinstance(addr, ipaddress.IPv6Address):
        # One /64 is one subscriber; privacy addresses rotate inside it.
        key = str(ipaddress.ip_network(f"{addr}/64", strict=False).network_address)
    elif addr is not None:
        key = str(addr)
    digest = hmac.new(cfg.arm_salt.encode(), key.encode(), hashlib.sha256).digest()
    return ARM_TURNSTILE if digest[0] & 1 else ARM_ANUBIS


def sign(cfg: Config, payload: dict) -> str:
    body = base64.urlsafe_b64encode(json.dumps(payload, separators=(",", ":")).encode()).decode().rstrip("=")
    mac = hmac.new(cfg.cookie_key, body.encode(), hashlib.sha256).hexdigest()
    return body + "." + mac


def unsign(cfg: Config, value: str, now: float) -> "dict | None":
    body, sep, mac = value.rpartition(".")
    if not sep:
        return None
    want = hmac.new(cfg.cookie_key, body.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(mac, want):
        return None
    try:
        payload = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
    except ValueError:
        return None
    if not isinstance(payload, dict) or payload.get("exp", 0) < now:
        return None
    return payload


def cookie_of_kind(cfg: Config, cookies: "dict[str, str]", name: str, kind: str, now: float) -> "dict | None":
    value = cookies.get(name)
    if not value:
        return None
    payload = unsign(cfg, value, now)
    if payload is None or payload.get("k") != kind:
        return None
    return payload


def set_cookie(name: str, value: str, max_age: int) -> str:
    # No Domain attribute: host-only, so the cookie never reaches other subdomains.
    return f"{name}={value}; Path=/; Max-Age={max_age}; Secure; HttpOnly; SameSite=Lax"


def fallback_cookie(cfg: Config, now: float) -> str:
    payload = {"id": secrets.token_hex(8), "k": KIND_FALLBACK, "exp": int(now) + FALLBACK_TTL}
    return set_cookie(FALLBACK_COOKIE, sign(cfg, payload), FALLBACK_TTL)


def decide(cfg: Config, r: Request, now: float) -> Decision:
    cookies = parse_cookies(r.cookie)
    # The pass cookie comes first and applies to every request, assets
    # included: without the header Anubis would challenge a passed visitor's
    # CSS and JS, because that visitor never solved Anubis.
    passed = cookie_of_kind(cfg, cookies, PASS_COOKIE, KIND_PASS, now)
    if passed is not None:
        return Decision(200, "pass", {PASS_HEADER: "1"}, cookie_id=str(passed.get("id", "")))
    if r.method.upper() not in ("GET", "HEAD"):
        return Decision(200, "method")
    addr = parse_ip(r.real_ip)
    if addr is None:
        return Decision(200, "no-ip")
    if any(addr in net for net in cfg.trusted if addr.version == net.version):
        return Decision(200, "trusted")
    if not wants_html(r.accept):
        return Decision(200, "not-html")
    if not is_browser(r.ua):
        return Decision(200, "not-browser")
    arm = arm_for(cfg, r.real_ip)
    fb = cookie_of_kind(cfg, cookies, FALLBACK_COOKIE, KIND_FALLBACK, now)
    if fb is not None:
        return Decision(200, "fallback", arm=arm, cookie_id=str(fb.get("id", "")))
    if arm == ARM_ANUBIS:
        return Decision(200, "arm-anubis", arm=arm)
    body = PAGE.replace("__SITEKEY__", cfg.sitekey).replace("__ACTION__", cfg.action)
    headers = {"Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store"}
    return Decision(403, "challenge", headers, body, arm=arm)


class TokenCache:
    """Hashes of tokens already redeemed, kept for one token lifetime.

    Per replica: with two gate replicas a reuse that lands on the other pod is
    not caught here, which is why verify_ok logs token_hash for Loki.
    """

    def __init__(self, ttl: int = TOKEN_TTL) -> None:
        self.ttl = ttl
        self.seen: "dict[str, float]" = {}
        self.lock = threading.Lock()

    def first_use(self, key: str, now: float) -> bool:
        with self.lock:
            if len(self.seen) > 10000:
                self.seen = {k: exp for k, exp in self.seen.items() if exp > now}
            exp = self.seen.get(key)
            if exp is not None and exp > now:
                return False
            self.seen[key] = now + self.ttl
            return True


def siteverify_http(fields: dict, timeout: float) -> dict:
    data = urllib.parse.urlencode(fields).encode()
    with urllib.request.urlopen(urllib.request.Request(SITEVERIFY, data=data), timeout=timeout) as resp:
        return json.loads(resp.read())


def verify(cfg: Config, token: str, ip: str, now: float, siteverify: SiteverifyFn, cache: TokenCache) -> VerifyResult:
    if not token or len(token) > MAX_TOKEN_LEN:
        return VerifyResult(False, "verify_bad_token", detail={"token_len": len(token)})
    token_hash = hashlib.sha256(token.encode()).hexdigest()[:16]
    detail: dict = {"token_hash": token_hash}
    if not cache.first_use(token_hash, now):
        return VerifyResult(False, "verify_reuse", detail=detail)
    fields = {"secret": cfg.secret, "response": token, "remoteip": ip}
    try:
        result = siteverify(fields, SITEVERIFY_TIMEOUT)
    except urllib.error.HTTPError as e:
        if e.code >= 500:
            return admit(cfg, now, "verify_unavailable_admit", dict(detail, siteverify_error=f"http {e.code}"))
        return VerifyResult(False, "verify_fail", detail=dict(detail, siteverify_error=f"http {e.code}"))
    except (urllib.error.URLError, socket.timeout, TimeoutError, OSError, ValueError) as e:
        # A real token exists and Cloudflare could not judge it: admit, log it.
        return admit(cfg, now, "verify_unavailable_admit", dict(detail, siteverify_error=repr(e)[:200]))
    detail.update({
        "error_codes": result.get("error-codes", []),
        "sv_hostname": result.get("hostname", ""),
        "sv_action": result.get("action", ""),
    })
    if result.get("success") is True and result.get("hostname") == cfg.host and result.get("action") == cfg.action:
        return admit(cfg, now, "verify_ok", detail)
    return VerifyResult(False, "verify_fail", detail=detail)


def admit(cfg: Config, now: float, event: str, detail: dict) -> VerifyResult:
    cookie_id = secrets.token_hex(8)
    payload = {"id": cookie_id, "k": KIND_PASS, "exp": int(now) + PASS_TTL}
    return VerifyResult(True, event, set_cookie(PASS_COOKIE, sign(cfg, payload), PASS_TTL), dict(detail, cookie_id=cookie_id))


def format_event(record: dict, now: float) -> str:
    return json.dumps(dict(record, ts=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))), sort_keys=True)


def log(record: dict) -> None:
    print(format_event(record, time.time()), flush=True)


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Checking your browser</title>
<style>
:root{color-scheme:light dark}
body{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;max-width:36rem;margin:3rem auto;padding:0 16px;line-height:1.5;background:#fff;color:#1a1a1a}
@media (prefers-color-scheme:dark){body{background:#16181c;color:#e6e6e6}}
#widget{min-height:70px;margin:1.5rem 0}
</style>
<script>
var gateDone = false, gateInteractive = false;
function gateStatus(t) { document.getElementById("status").textContent = t; }
function gatePost(path, body) {
  return fetch(path, {method: "POST", credentials: "same-origin",
    headers: {"Content-Type": "application/json"}, body: JSON.stringify(body)});
}
// Asks for the other check (Anubis). The server never admits on this call.
function gateFallback(reason) {
  if (gateDone) return;
  gateDone = true;
  gateStatus("Switching to another check...");
  gatePost("/_gate/fallback", {reason: String(reason).slice(0, 100)}).then(
    function () { location.reload(); },
    function () { gateStatus("Could not reach the server. Reload the page to try again."); });
}
window.onTurnstileLoad = function () {
  gateStatus("Running the check...");
  turnstile.render("#widget", {
    sitekey: "__SITEKEY__",
    action: "__ACTION__",
    theme: "auto",
    callback: function (token) {
      if (gateDone) return;
      gateDone = true;
      gateStatus("Verifying...");
      gatePost("/_gate/verify", {token: token})
        .then(function (r) { return r.json(); })
        .then(function (j) {
          if (j.ok) { gateStatus("Done. Loading the page..."); location.reload(); }
          else { gateStatus("The check did not pass. Reload the page to try again."); }
        }, function () { gateStatus("Could not reach the server. Reload the page to try again."); });
    },
    "error-callback": function (code) { gateFallback("widget-error-" + code); return true; },
    "unsupported-callback": function () { gateFallback("unsupported"); },
    "before-interactive-callback": function () { gateInteractive = true; gateStatus("Please complete the check above."); }
  });
};
setTimeout(function () { if (!gateDone && !gateInteractive) gateFallback("no-callback-15s"); }, 15000);
</script>
<script src="https://challenges.cloudflare.com/turnstile/v0/api.js?onload=onTurnstileLoad&render=explicit" async defer
  onerror="gateFallback('script-error')"></script>
</head><body><main>
<h1>Checking your browser</h1>
<p>Before showing this page, the site checks that the visitor is a person. It usually takes a few seconds and happens once per browser.</p>
<div id="widget"></div>
<p id="status" role="status" aria-live="polite">Loading the check...</p>
<noscript><p>This check needs JavaScript. Enable it and reload the page.</p></noscript>
</main></body></html>
"""


def load_config() -> Config:
    return Config(
        sitekey=os.environ["TURNSTILE_SITEKEY"],
        secret=os.environ["TURNSTILE_SECRET"],
        cookie_key=os.environ["COOKIE_KEY"].encode(),
        arm_salt=os.environ["ARM_SALT"],
        host=os.environ["GATE_HOST"],
        action=os.environ.get("TURNSTILE_ACTION", "forgejo-gate"),
        trusted=parse_cidrs(os.environ.get("TRUSTED_CIDRS", ",".join(DEFAULT_TRUSTED_CIDRS))),
    )


def make_handler(cfg: Config, cache: TokenCache) -> "type[BaseHTTPRequestHandler]":
    class Handler(BaseHTTPRequestHandler):
        server_version = "turnstile-gate"
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt: str, *args: object) -> None:  # structured events only
            return

        def real_ip(self) -> str:
            return self.headers.get("X-Real-Ip", "") or self.client_address[0]

        def send(self, code: int, body: str = "", headers: "dict[str, str] | None" = None) -> None:
            data = body.encode()
            self.send_response(code)
            hdrs = {"Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store"}
            hdrs.update(headers or {})
            for k, v in hdrs.items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)

        def do_HEAD(self) -> None:
            self.do_GET()

        def do_GET(self) -> None:
            path = urllib.parse.urlparse(self.path).path
            if path == "/healthz":
                return self.send(200, "ok")
            if path != "/auth":
                return self.send(404, "not found")
            h = self.headers
            r = Request(method=h.get("X-Forwarded-Method", "GET"), real_ip=h.get("X-Real-Ip", ""),
                        accept=h.get("Accept", ""), ua=h.get("User-Agent", ""), cookie=h.get("Cookie", ""),
                        uri=h.get("X-Forwarded-Uri", ""))
            d = decide(cfg, r, time.time())
            if d.reason in ("challenge", "arm-anubis", "fallback") or (d.reason == "pass" and wants_html(r.accept)):
                log({"event": "decision", "reason": d.reason, "arm": d.arm or arm_for(cfg, r.real_ip),
                     "ip": r.real_ip, "ua": r.ua, "uri": r.uri[:300], "cookie_id": d.cookie_id})
            return self.send(d.status, d.body, d.headers)

        def read_json(self) -> dict:
            length = min(int(self.headers.get("Content-Length", "0") or 0), 16384)
            try:
                data = json.loads(self.rfile.read(length) or b"{}")
            except ValueError:
                return {}
            return data if isinstance(data, dict) else {}

        def do_POST(self) -> None:
            path = urllib.parse.urlparse(self.path).path
            body = self.read_json()
            ip, ua = self.real_ip(), self.headers.get("User-Agent", "")
            if path == "/_gate/verify":
                token = body.get("token", "")
                res = verify(cfg, token if isinstance(token, str) else "", ip, time.time(), siteverify_http, cache)
                log(dict(res.detail, event=res.event, arm=arm_for(cfg, ip), ip=ip, ua=ua))
                headers = {"Content-Type": "application/json"}
                if res.set_cookie:
                    headers["Set-Cookie"] = res.set_cookie
                return self.send(200, json.dumps({"ok": res.admitted}), headers)
            if path == "/_gate/fallback":
                reason = str(body.get("reason", ""))[:100]
                header = fallback_cookie(cfg, time.time())
                log({"event": "fallback_set", "reason": reason, "arm": arm_for(cfg, ip), "ip": ip, "ua": ua})
                return self.send(200, json.dumps({"ok": True}), {"Content-Type": "application/json", "Set-Cookie": header})
            return self.send(404, "not found")

    return Handler


if __name__ == "__main__":
    config = load_config()
    log({"event": "start", "sitekey": config.sitekey, "host": config.host})
    server = ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("PORT", "8080"))), make_handler(config, TokenCache()))
    server.daemon_threads = True
    server.serve_forever()
