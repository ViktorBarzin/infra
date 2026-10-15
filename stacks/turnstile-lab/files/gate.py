"""Turnstile lab gate: throwaway experiment, see stacks/turnstile-lab/main.tf.

GET /            no valid cookie -> page with the Turnstile widget; valid cookie -> "passed" page
POST /verify     {"token": "..."} -> calls siteverify, logs the full JSON, sets a signed cookie on success
POST /hold       {"token": "..."} parks a token WITHOUT verifying it (page opened with ?hold=1)
POST /verify-held  verifies the parked token now; call twice to test single use, wait to test lifetime
POST /event      client-side widget events (error-callback codes, script load failure, timeouts)
GET /debug       last 50 verify results and client events as JSON
GET /logout      clears the cookie
GET /healthz     liveness
"""

import base64
import collections
import hashlib
import hmac
import html
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SITEKEY = os.environ["TURNSTILE_SITEKEY"]
SECRET = os.environ["TURNSTILE_SECRET"]
COOKIE_KEY = hashlib.sha256(("cookie:" + SECRET).encode()).digest()
COOKIE_NAME = "tslab"
COOKIE_TTL = 30 * 24 * 3600
SITEVERIFY = "https://challenges.cloudflare.com/turnstile/v0/siteverify"

RING: "collections.deque[dict]" = collections.deque(maxlen=50)
RING_LOCK = threading.Lock()
HELD: dict = {}  # token-rules experiment: one unredeemed token parked by POST /hold


def log(record: dict) -> None:
    record["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(json.dumps(record, sort_keys=True), flush=True)
    masked = dict(record)
    ip = masked.get("client_ip", "")
    if ip:
        masked["client_ip"] = ip.rsplit(".", 1)[0] + ".x" if "." in ip else ip.rsplit(":", 2)[0] + ":x"
    masked.pop("xff", None)
    with RING_LOCK:
        RING.append(masked)


def sign(payload: dict) -> str:
    body = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
    mac = hmac.new(COOKIE_KEY, body.encode(), hashlib.sha256).hexdigest()
    return body + "." + mac


def unsign(value: str) -> "dict | None":
    try:
        body, mac = value.rsplit(".", 1)
    except ValueError:
        return None
    want = hmac.new(COOKIE_KEY, body.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(mac, want):
        return None
    payload = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
    if payload.get("exp", 0) < time.time():
        return None
    return payload


PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Turnstile lab</title>
<style>
body{font-family:system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 16px;background:#fafafa;color:#111}
pre{background:#eee;padding:.5rem;white-space:pre-wrap;word-break:break-all;font-size:.8rem}
#status{font-weight:600}
</style>
<script>
var T0 = Date.now();
function ev(kind, detail) {
  var line = (((Date.now()-T0)/1000).toFixed(1)) + "s " + kind + " " + (detail||"");
  var p = document.getElementById("log"); if (p) p.textContent += line + "\\n";
  try { navigator.sendBeacon("/event", JSON.stringify({kind: kind, detail: String(detail||""), t_ms: Date.now()-T0})); } catch (e) {}
}
function setStatus(s){ document.getElementById("status").textContent = s; }
window.onTurnstileLoad = function () {
  ev("api-loaded");
  window.__widget = turnstile.render("#widget", {
    sitekey: "__SITEKEY__",
    action: "lab-gate",
    cData: "cd" + T0,
    callback: function (token) {
      window.__lastToken = token;
      ev("callback", "token len " + token.length);
      setStatus("token received, verifying...");
      var hold = location.search.indexOf("hold=1") >= 0;
      fetch(hold ? "/hold" : "/verify", {method: "POST", headers: {"Content-Type": "application/json"},
        body: JSON.stringify({token: token})})
        .then(function (r) { return r.json(); })
        .then(function (j) {
          document.getElementById("result").textContent = JSON.stringify(j, null, 2);
          if (j.held) { setStatus("token parked, not verified"); return; }
          if (j.success) { setStatus("PASSED"); setTimeout(function(){ if(!window.__noReload) location.reload(); }, 1500); }
          else setStatus("siteverify rejected: " + (j["error-codes"]||[]).join(","));
        })
        .catch(function (e) { ev("verify-fetch-failed", e); setStatus("verify request failed"); });
    },
    "error-callback": function (code) { ev("error-callback", code); setStatus("widget error " + code); return true; },
    "expired-callback": function () { ev("expired-callback"); },
    "timeout-callback": function () { ev("timeout-callback"); },
    "before-interactive-callback": function () { ev("before-interactive-callback"); setStatus("interactive challenge shown"); },
    "after-interactive-callback": function () { ev("after-interactive-callback"); },
    "unsupported-callback": function () { ev("unsupported-callback"); setStatus("browser unsupported"); }
  });
};
setTimeout(function () { if (typeof turnstile === "undefined") { ev("api-not-loaded-after-10s"); setStatus("Turnstile script never loaded (fail-open candidate)"); } }, 10000);
</script>
<script src="https://challenges.cloudflare.com/turnstile/v0/api.js?onload=onTurnstileLoad&render=explicit" async defer
  onerror="ev('script-onerror','api.js failed to load'); setStatus('Turnstile script failed to load (fail-open candidate)');"></script>
</head><body>
<h1>Turnstile lab</h1>
<p>Throwaway experiment. Checking whether Cloudflare Turnstile can gate this site.</p>
<p>Status: <span id="status">loading widget...</span></p>
<div id="widget"></div>
<h3>siteverify result</h3><pre id="result">(none yet)</pre>
<h3>client events</h3><pre id="log"></pre>
<p><a href="/debug">/debug</a></p>
</body></html>
"""

PASSED = """<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Turnstile lab</title>
<style>body{font-family:system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 16px;background:#fafafa;color:#111}
pre{background:#eee;padding:.5rem;white-space:pre-wrap;word-break:break-all;font-size:.8rem}</style></head>
<body><h1>PASSED</h1><p>A valid lab cookie is present, so the widget was skipped.</p>
<pre>__COOKIE__</pre><p><a href="/logout">clear cookie and try again</a> | <a href="/debug">/debug</a></p></body></html>
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "turnstile-lab"

    def client(self) -> dict:
        h = self.headers
        ip = h.get("Cf-Connecting-Ip") or (h.get("X-Forwarded-For", "").split(",")[0].strip()) or self.client_address[0]
        return {"client_ip": ip, "xff": h.get("X-Forwarded-For", ""), "ua": h.get("User-Agent", ""),
                "cf_ray": h.get("Cf-Ray", ""), "cf_ipcountry": h.get("Cf-Ipcountry", "")}

    def send(self, code: int, body: str, ctype: str = "text/html; charset=utf-8", headers: "dict | None" = None) -> None:
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def cookie(self) -> "dict | None":
        for part in self.headers.get("Cookie", "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == COOKIE_NAME:
                return unsign(v)
        return None

    def log_message(self, fmt: str, *args: object) -> None:  # access log off; we log structured events
        return

    def do_GET(self) -> None:
        path = urllib.parse.urlparse(self.path).path
        if path == "/healthz":
            return self.send(200, "ok", "text/plain")
        if path == "/debug":
            with RING_LOCK:
                items = list(RING)
            return self.send(200, json.dumps(items[::-1], indent=2), "application/json")
        if path == "/logout":
            return self.send(302, "", headers={"Location": "/", "Set-Cookie": f"{COOKIE_NAME}=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax"})
        if path != "/":
            return self.send(404, "not found", "text/plain")
        c = self.cookie()
        if c:
            return self.send(200, PASSED.replace("__COOKIE__", html.escape(json.dumps(c, indent=2))))
        log({"event": "challenge-served", **self.client()})
        return self.send(200, PAGE.replace("__SITEKEY__", SITEKEY))

    def do_POST(self) -> None:
        path = urllib.parse.urlparse(self.path).path
        length = min(int(self.headers.get("Content-Length", "0") or 0), 65536)
        raw = self.rfile.read(length)
        if path == "/event":
            try:
                ev = json.loads(raw or b"{}")
            except ValueError:
                ev = {"raw": raw[:500].decode(errors="replace")}
            log({"event": "client-event", "client_event": ev, **self.client()})
            return self.send(204, "")
        if path not in ("/verify", "/hold", "/verify-held"):
            return self.send(404, "not found", "text/plain")
        try:
            token = json.loads(raw).get("token", "")
        except ValueError:
            token = urllib.parse.parse_qs(raw.decode()).get("cf-turnstile-response", [""])[0]
        cl = self.client()
        if path == "/hold":
            HELD.clear()
            HELD.update({"token": token, "at": time.time(), "verifies": 0})
            log({"event": "token-held", "token_prefix": token[:12], "token_len": len(token), **cl})
            return self.send(200, json.dumps({"held": True, "token_len": len(token)}), "application/json")
        if path == "/verify-held":
            if not HELD:
                return self.send(404, json.dumps({"error": "no held token"}), "application/json")
            token = HELD["token"]
            HELD["verifies"] += 1
            cl["held_age_s"] = int(time.time() - HELD["at"])
            cl["held_verify_n"] = HELD["verifies"]
        form = urllib.parse.urlencode({"secret": SECRET, "response": token, "remoteip": cl["client_ip"]}).encode()
        t0 = time.time()
        try:
            with urllib.request.urlopen(urllib.request.Request(SITEVERIFY, data=form), timeout=10) as r:
                result = json.loads(r.read())
        except urllib.error.HTTPError as e:  # siteverify answers 4xx with a JSON body on bad input
            body = e.read()
            try:
                result = json.loads(body)
            except ValueError:
                result = {"success": False, "lab_error": repr(e), "body": body[:500].decode(errors="replace")}
            result["lab_http_status"] = e.code
        except Exception as e:  # noqa: BLE001 - lab: record any failure mode verbatim
            result = {"success": False, "lab_error": repr(e)}
        log({"event": "siteverify", "siteverify": result, "siteverify_ms": int((time.time() - t0) * 1000),
             "token_prefix": token[:12], "token_len": len(token), **cl})
        headers = {}
        if result.get("success") and path == "/verify":
            payload = {"exp": int(time.time()) + COOKIE_TTL, "ip": cl["client_ip"], "hostname": result.get("hostname")}
            headers["Set-Cookie"] = f"{COOKIE_NAME}={sign(payload)}; Path=/; Max-Age={COOKIE_TTL}; Secure; HttpOnly; SameSite=Lax"
        return self.send(200, json.dumps(result), "application/json", headers)


if __name__ == "__main__":
    print(json.dumps({"event": "start", "sitekey": SITEKEY}), flush=True)
    sys.stdout.flush()
    ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("PORT", "8080"))), Handler).serve_forever()
