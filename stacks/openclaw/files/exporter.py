#!/usr/bin/env python3
"""OpenClaw / Codex usage exporter.

Reads ~/.openclaw/agents/*/sessions/*.jsonl (assistant messages with usage)
and ~/.openclaw/agents/*/agent/auth-state.json (OAuth profiles), then exposes
Prometheus text-format metrics on :9099/metrics. Stdlib only — no pip install
needed at startup.

Metrics (all cumulative-since-session-start; use Prometheus increase()/rate()
for windowed views):

  openclaw_codex_messages_total{provider,model,session_kind}    counter
  openclaw_codex_input_tokens_total{provider,model}             counter
  openclaw_codex_output_tokens_total{provider,model}            counter
  openclaw_codex_cache_read_tokens_total{provider,model}        counter
  openclaw_codex_cache_write_tokens_total{provider,model}       counter
  openclaw_codex_message_errors_total{provider,model,reason}    counter
  openclaw_codex_active_sessions{kind}                          gauge
  openclaw_codex_oauth_expiry_seconds{provider,account}         gauge
  openclaw_codex_last_run_timestamp                             gauge
  openclaw_codex_exporter_scrape_duration_ms                    gauge
"""
import glob
import json
import os
import re
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from threading import Lock

OPENCLAW_HOME = os.environ.get("OPENCLAW_HOME", "/home/node/.openclaw")
PORT = int(os.environ.get("METRICS_PORT", "9099"))
CACHE_SEC = float(os.environ.get("CACHE_SEC", "5"))
SKIP_FRAGMENTS = (".broken.", ".reset.", ".deleted.", ".bak.")
SESSION_RE = re.compile(r"^([0-9a-f-]{36})\.jsonl$")

_lock = Lock()
_cache = {"text": "", "ts": 0.0}


def _esc(value: str) -> str:
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def _line(name: str, labels: dict, value) -> str:
    if labels:
        rendered = ",".join(f'{k}="{_esc(v)}"' for k, v in sorted(labels.items()))
        return f"{name}{{{rendered}}} {value}"
    return f"{name} {value}"


def _kind_for(session_id: str, sessions_index: dict) -> str:
    for key, val in sessions_index.items():
        if val.get("sessionId") != session_id:
            continue
        if key.startswith("agent:main:cron:"):
            return "cron"
        if key.startswith("telegram:slash:"):
            return "telegram-slash"
        if key.startswith("agent:main:"):
            return "main"
        surface = (val.get("origin") or {}).get("surface")
        if surface:
            return surface
        return key.split(":", 1)[0]
    return "unknown"


def _parse_ts(value):
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        except ValueError:
            return 0.0
    return 0.0


def _build_text() -> str:
    start = time.monotonic()
    out = []

    sessions_index: dict = {}
    for sp in glob.glob(os.path.join(OPENCLAW_HOME, "agents/*/sessions/sessions.json")):
        try:
            with open(sp) as f:
                sessions_index.update(json.load(f))
        except Exception:
            pass

    msg_count: dict = {}
    in_tok: dict = {}
    out_tok: dict = {}
    cr_tok: dict = {}
    cw_tok: dict = {}
    err_count: dict = {}
    latest_ts = 0.0

    for jsonl in glob.glob(os.path.join(OPENCLAW_HOME, "agents/*/sessions/*.jsonl")):
        bn = os.path.basename(jsonl)
        if any(s in bn for s in SKIP_FRAGMENTS):
            continue
        m = SESSION_RE.match(bn)
        if not m:
            continue
        sid = m.group(1)
        kind = _kind_for(sid, sessions_index)
        try:
            with open(jsonl) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except Exception:
                        continue
                    if obj.get("type") != "message":
                        continue
                    msg = obj.get("message") or {}
                    if msg.get("role") != "assistant":
                        continue
                    provider = msg.get("provider") or "unknown"
                    model = msg.get("model") or "unknown"
                    usage = msg.get("usage") or {}
                    ts = _parse_ts(obj.get("timestamp"))
                    if ts > latest_ts:
                        latest_ts = ts
                    if msg.get("stopReason") == "error":
                        reason = (msg.get("errorMessage") or "unknown")[:80]
                        ek = (provider, model, reason)
                        err_count[ek] = err_count.get(ek, 0) + 1
                        continue
                    mk = (provider, model, kind)
                    msg_count[mk] = msg_count.get(mk, 0) + 1
                    pm = (provider, model)
                    in_tok[pm] = in_tok.get(pm, 0) + (usage.get("input") or 0)
                    out_tok[pm] = out_tok.get(pm, 0) + (usage.get("output") or 0)
                    cr_tok[pm] = cr_tok.get(pm, 0) + (usage.get("cacheRead") or 0)
                    cw_tok[pm] = cw_tok.get(pm, 0) + (usage.get("cacheWrite") or 0)
        except Exception:
            pass

    out.append("# HELP openclaw_codex_messages_total Cumulative assistant messages")
    out.append("# TYPE openclaw_codex_messages_total counter")
    for (p, mdl, k), c in msg_count.items():
        out.append(_line("openclaw_codex_messages_total",
                         {"provider": p, "model": mdl, "session_kind": k}, c))

    for name, src, hlp in [
        ("openclaw_codex_input_tokens_total", in_tok, "Cumulative input tokens"),
        ("openclaw_codex_output_tokens_total", out_tok, "Cumulative output tokens"),
        ("openclaw_codex_cache_read_tokens_total", cr_tok, "Cumulative cache-read tokens"),
        ("openclaw_codex_cache_write_tokens_total", cw_tok, "Cumulative cache-write tokens"),
    ]:
        out.append(f"# HELP {name} {hlp}")
        out.append(f"# TYPE {name} counter")
        for (p, mdl), c in src.items():
            out.append(_line(name, {"provider": p, "model": mdl}, c))

    out.append("# HELP openclaw_codex_message_errors_total Cumulative assistant errors")
    out.append("# TYPE openclaw_codex_message_errors_total counter")
    for (p, mdl, r), c in err_count.items():
        out.append(_line("openclaw_codex_message_errors_total",
                         {"provider": p, "model": mdl, "reason": r}, c))

    out.append("# HELP openclaw_codex_active_sessions Active sessions in sessions.json")
    out.append("# TYPE openclaw_codex_active_sessions gauge")
    kc: dict = {}
    for k in sessions_index:
        if k.startswith("agent:main:cron:"):
            kk = "cron"
        elif k.startswith("telegram:slash:"):
            kk = "telegram-slash"
        elif k.startswith("agent:main:"):
            kk = "main"
        else:
            kk = k.split(":", 1)[0]
        kc[kk] = kc.get(kk, 0) + 1
    for k, c in kc.items():
        out.append(_line("openclaw_codex_active_sessions", {"kind": k}, c))

    if latest_ts:
        out.append("# HELP openclaw_codex_last_run_timestamp Unix ts of newest assistant message")
        out.append("# TYPE openclaw_codex_last_run_timestamp gauge")
        out.append(_line("openclaw_codex_last_run_timestamp", {}, latest_ts))

    out.append("# HELP openclaw_codex_oauth_expiry_seconds Seconds until OAuth token expires")
    out.append("# TYPE openclaw_codex_oauth_expiry_seconds gauge")
    now = time.time()
    for af in glob.glob(os.path.join(OPENCLAW_HOME, "agents/*/agent/auth-profiles.json")):
        try:
            with open(af) as f:
                data = json.load(f)
        except Exception:
            continue
        # Schema: {"version": 1, "profiles": {"<id>": {...}}}.
        # `expires` is Unix milliseconds.
        for profile in (data.get("profiles") or {}).values():
            exp_ms = profile.get("expires")
            if not isinstance(exp_ms, (int, float)):
                continue
            exp_ts = exp_ms / 1000.0
            out.append(_line(
                "openclaw_codex_oauth_expiry_seconds",
                {
                    "provider": profile.get("provider", "unknown"),
                    "account": profile.get("email") or profile.get("account") or "unknown",
                    "plan": profile.get("chatgptPlanType") or "unknown",
                },
                max(0, exp_ts - now),
            ))

    out.append("# HELP openclaw_codex_exporter_scrape_duration_ms Last scrape duration ms")
    out.append("# TYPE openclaw_codex_exporter_scrape_duration_ms gauge")
    out.append(_line("openclaw_codex_exporter_scrape_duration_ms", {},
                     (time.monotonic() - start) * 1000))

    return "\n".join(out) + "\n"


class Handler(BaseHTTPRequestHandler):
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
        with _lock:
            now = time.time()
            if now - _cache["ts"] > CACHE_SEC:
                try:
                    _cache["text"] = _build_text()
                except Exception as exc:  # noqa: BLE001
                    _cache["text"] = (
                        f'openclaw_codex_exporter_errors_total{{kind="scrape"}} 1\n'
                        f'# scrape error: {_esc(str(exc))[:200]}\n'
                    )
                _cache["ts"] = now
            body = _cache["text"].encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args, **kwargs):
        pass


def main():
    print(f"openclaw exporter listening on :{PORT}", flush=True)
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
