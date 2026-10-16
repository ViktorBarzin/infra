"""Turnstile gate for the public *.viktorbarzin.me sites (see stacks/turnstile-gate/main.tf).

Traefik forwardAuth -> nginx shim -> GET /auth here. A 200 carrying
X-Turnstile-Pass: 1 means "let it through, skip Anubis"; a 200 without it means
"Anubis decides"; a 403 is the Turnstile page, served on the URL the visitor
asked for. Two variants, chosen per site by the middleware's query string:

  standard  sites with no Anubis of their own. Only an untrusted browser asking
            for an HTML page is checked; everything else skips Anubis.
  strict    sites fronted by their own Anubis. Only a Turnstile pass skips it,
            so a crawler cannot dodge the check by not asking for HTML.

GET  /auth[?variant=strict]   forwardAuth decision (stateless)
POST /verify                  token -> siteverify -> pass cookie for the whole domain (30 days)
POST /fallback                fallback cookie (1 h): the visitor gets Anubis, never a pass
OPTIONS /verify, /fallback    CORS preflight (the page calls these cross-origin)
GET  /healthz                 readiness

/verify and /fallback are served on the challenge host (challenge.viktorbarzin.me)
and, for the canary's old page, on forgejo's /_gate/ path.

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
PASS_TTL = 30 * 24 * 3600
FALLBACK_TTL = 3600
TOKEN_TTL = 300  # Turnstile token lifetime; siteverify accepts reuse within it (measured), so we refuse it
MAX_TOKEN_LEN = 2048
SITEVERIFY_TIMEOUT = 5.0

# The global switch (local.mode in main.tf).
MODE_ON = "on"          # challenge as designed
MODE_ANUBIS = "anubis"  # never challenge; browsers asking for HTML go to Anubis instead
MODE_OPEN = "open"      # never challenge; sites behave as they did before Turnstile
MODES = (MODE_ON, MODE_ANUBIS, MODE_OPEN)

# Mirrors var.trusted_local_cidrs in modules/kubernetes/anubis_instance, the
# canonical list. Matched against X-Real-Ip, which the real-ip plugin sets from
# the TCP peer, so it cannot be forged from the internet.
DEFAULT_TRUSTED_CIDRS = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "fc00::/7", "fe80::/10"]

# A browser-style user agent that says it is a bot. Anubis verifies the search
# engines by IP and challenges the rest, so these go to Anubis, not Turnstile.
DECLARED_BOT = re.compile(r"bot|crawl|spider|slurp", re.IGNORECASE)

Network = Union[ipaddress.IPv4Network, ipaddress.IPv6Network]
Address = Union[ipaddress.IPv4Address, ipaddress.IPv6Address]


@dataclass
class Config:
    sitekey: str
    secret: str
    cookie_key: bytes
    domain: str
    challenge_origin: str
    action: str
    mode: str
    trusted: "list[Network]"


@dataclass
class Request:
    method: str
    real_ip: str
    accept: str
    ua: str
    cookie: str
    uri: str
    host: str
    strict: bool


@dataclass
class Decision:
    status: int
    reason: str
    headers: "dict[str, str]" = field(default_factory=dict)
    body: str = ""
    cookie_id: str = ""


@dataclass
class VerifyResult:
    admitted: bool
    event: str
    set_cookie: str = ""
    detail: dict = field(default_factory=dict)


SiteverifyFn = Callable[[dict, float], dict]


def parse_mode(value: str) -> str:
    return value if value in MODES else MODE_ON


def parse_cidrs(value: str) -> "list[Network]":
    return [ipaddress.ip_network(c.strip()) for c in value.split(",") if c.strip()]


def parse_cookies(header: str) -> "dict[str, str]":
    out: "dict[str, str]" = {}
    for name, value in cookie_pairs(header):
        out[name] = value
    return out


def cookie_pairs(header: str) -> "list[tuple[str, str]]":
    pairs = []
    for part in header.split(";"):
        name, sep, value = part.strip().partition("=")
        if sep and name:
            pairs.append((name, value))
    return pairs


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


def parse_ip(value: str) -> "Address | None":
    try:
        addr = ipaddress.ip_address(value.strip())
    except ValueError:
        return None
    if isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped:
        return addr.ipv4_mapped
    return addr


def host_allowed(cfg: Config, host: str) -> bool:
    host = host.lower()
    return host == cfg.domain or host.endswith("." + cfg.domain)


def cors_headers(cfg: Config, origin: str) -> "dict[str, str]":
    parsed = urllib.parse.urlsplit(origin)
    if parsed.scheme != "https" or parsed.port is not None or parsed.path or not host_allowed(cfg, parsed.hostname or ""):
        return {}
    return {
        "Access-Control-Allow-Origin": origin,
        "Access-Control-Allow-Credentials": "true",
        "Vary": "Origin",
    }


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


def cookie_of_kind(cfg: Config, header: str, name: str, kind: str, now: float) -> "dict | None":
    # A browser can send the same name twice (the canary's host-only cookie and
    # the domain cookie), so any valid one counts.
    for n, value in cookie_pairs(header):
        if n != name:
            continue
        payload = unsign(cfg, value, now)
        if payload is not None and payload.get("k") == kind:
            return payload
    return None


def set_cookie(cfg: Config, name: str, value: str, max_age: int) -> str:
    # Domain-wide: one solve covers every site (decision 5 in the design doc).
    return f"{name}={value}; Domain={cfg.domain}; Path=/; Max-Age={max_age}; Secure; HttpOnly; SameSite=Lax"


def fallback_cookie(cfg: Config, now: float) -> str:
    payload = {"id": secrets.token_hex(8), "k": KIND_FALLBACK, "exp": int(now) + FALLBACK_TTL}
    return set_cookie(cfg, FALLBACK_COOKIE, sign(cfg, payload), FALLBACK_TTL)


def decide(cfg: Config, r: Request, now: float) -> Decision:
    # The pass comes first and covers every request, assets included.
    passed = cookie_of_kind(cfg, r.cookie, PASS_COOKIE, KIND_PASS, now)
    if passed is not None:
        return Decision(200, "pass", {PASS_HEADER: "1"}, cookie_id=str(passed.get("id", "")))
    # Strict sites have their own Anubis: anything that is not a pass goes there.
    skip = {} if r.strict else {PASS_HEADER: "1"}
    if cfg.mode == MODE_OPEN:
        return Decision(200, "mode-open", dict(skip))
    if r.method.upper() not in ("GET", "HEAD"):
        return Decision(200, "method", dict(skip))
    addr = parse_ip(r.real_ip)
    if addr is None:
        return Decision(200, "no-ip", dict(skip))
    if any(addr in net for net in cfg.trusted if addr.version == net.version):
        return Decision(200, "trusted", dict(skip))
    fb = cookie_of_kind(cfg, r.cookie, FALLBACK_COOKIE, KIND_FALLBACK, now)
    if fb is not None:
        return Decision(200, "fallback", cookie_id=str(fb.get("id", "")))
    if not r.ua.startswith("Mozilla/"):
        return Decision(200, "not-browser", dict(skip))
    if DECLARED_BOT.search(r.ua):
        return Decision(200, "declared-bot")
    if not wants_html(r.accept):
        return Decision(200, "not-html", dict(skip))
    if cfg.mode == MODE_ANUBIS:
        return Decision(200, "mode-anubis")
    body = (PAGE.replace("__SITEKEY__", cfg.sitekey).replace("__ACTION__", cfg.action)
            .replace("__ORIGIN__", cfg.challenge_origin))
    headers = {"Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store"}
    return Decision(403, "challenge", headers, body)


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
    hostname = str(result.get("hostname", ""))
    detail.update({
        "error_codes": result.get("error-codes", []),
        "sv_hostname": hostname,
        "sv_action": result.get("action", ""),
    })
    if result.get("success") is True and host_allowed(cfg, hostname) and result.get("action") == cfg.action:
        return admit(cfg, now, "verify_ok", detail)
    return VerifyResult(False, "verify_fail", detail=detail)


def admit(cfg: Config, now: float, event: str, detail: dict) -> VerifyResult:
    cookie_id = secrets.token_hex(8)
    payload = {"id": cookie_id, "k": KIND_PASS, "exp": int(now) + PASS_TTL}
    return VerifyResult(True, event, set_cookie(cfg, PASS_COOKIE, sign(cfg, payload), PASS_TTL),
                        dict(detail, cookie_id=cookie_id))


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
var gateOrigin = "__ORIGIN__";
var gateDone = false, gateInteractive = false;
function gateStatus(t) { document.getElementById("status").textContent = t; }
// text/plain keeps this a simple CORS request (no preflight); the server reads JSON either way.
function gatePost(path, body) {
  return fetch(gateOrigin + path, {method: "POST", credentials: "include",
    headers: {"Content-Type": "text/plain"}, body: JSON.stringify(body)});
}
// Asks for the other check (Anubis). The server never admits on this call.
function gateFallback(reason) {
  if (gateDone) return;
  gateDone = true;
  gateStatus("Switching to another check...");
  gatePost("/fallback", {reason: String(reason).slice(0, 100)}).then(
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
      gatePost("/verify", {token: token})
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
        domain=os.environ.get("GATE_DOMAIN", "viktorbarzin.me"),
        challenge_origin=os.environ["CHALLENGE_ORIGIN"],
        action=os.environ.get("TURNSTILE_ACTION", "site-gate"),
        mode=parse_mode(os.environ.get("GATE_MODE", MODE_ON)),
        trusted=parse_cidrs(os.environ.get("TRUSTED_CIDRS", ",".join(DEFAULT_TRUSTED_CIDRS))),
    )


VERIFY_PATHS = ("/verify", "/_gate/verify")
FALLBACK_PATHS = ("/fallback", "/_gate/fallback")


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
            url = urllib.parse.urlparse(self.path)
            if url.path == "/healthz":
                return self.send(200, "ok")
            if url.path != "/auth":
                return self.send(404, "not found")
            h = self.headers
            strict = urllib.parse.parse_qs(url.query).get("variant", [""])[0] == "strict"
            r = Request(method=h.get("X-Forwarded-Method", "GET"), real_ip=h.get("X-Real-Ip", ""),
                        accept=h.get("Accept", ""), ua=h.get("User-Agent", ""), cookie=h.get("Cookie", ""),
                        uri=h.get("X-Forwarded-Uri", ""), host=h.get("X-Forwarded-Host", ""), strict=strict)
            d = decide(cfg, r, time.time())
            if d.reason in ("challenge", "fallback", "declared-bot") or (d.reason == "pass" and wants_html(r.accept)):
                log({"event": "decision", "reason": d.reason, "variant": "strict" if strict else "standard",
                     "host": r.host, "ip": r.real_ip, "ua": r.ua, "uri": r.uri[:300], "cookie_id": d.cookie_id})
            return self.send(d.status, d.body, d.headers)

        def do_OPTIONS(self) -> None:
            path = urllib.parse.urlparse(self.path).path
            cors = cors_headers(cfg, self.headers.get("Origin", ""))
            if path not in VERIFY_PATHS + FALLBACK_PATHS or not cors:
                return self.send(404, "not found")
            return self.send(204, "", dict(cors, **{
                "Access-Control-Allow-Methods": "POST",
                "Access-Control-Allow-Headers": "Content-Type",
                "Access-Control-Max-Age": "86400",
            }))

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
            origin = self.headers.get("Origin", "")
            headers = dict(cors_headers(cfg, origin), **{"Content-Type": "application/json"})
            if path in VERIFY_PATHS:
                token = body.get("token", "")
                res = verify(cfg, token if isinstance(token, str) else "", ip, time.time(), siteverify_http, cache)
                log(dict(res.detail, event=res.event, ip=ip, ua=ua, origin=origin))
                if res.set_cookie:
                    headers["Set-Cookie"] = res.set_cookie
                return self.send(200, json.dumps({"ok": res.admitted}), headers)
            if path in FALLBACK_PATHS:
                reason = str(body.get("reason", ""))[:100]
                headers["Set-Cookie"] = fallback_cookie(cfg, time.time())
                log({"event": "fallback_set", "reason": reason, "ip": ip, "ua": ua, "origin": origin})
                return self.send(200, json.dumps({"ok": True}), headers)
            return self.send(404, "not found")

    return Handler


if __name__ == "__main__":
    config = load_config()
    log({"event": "start", "sitekey": config.sitekey, "domain": config.domain, "mode": config.mode})
    server = ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("PORT", "8080"))), make_handler(config, TokenCache()))
    server.daemon_threads = True
    server.serve_forever()
