"""Alerts when a raw torrent row reaches the shared Stremio account.

London devices must never torrent themselves (Viktor 2026-11-23; the London
ISP objects to BitTorrent). Torrent rows reach them only as HTTPS rows from the
"P2P via Sofia" addon (p2p_row.py). A row with an infoHash would make the
device torrent from its own network again: Torrentio installed directly, or
P2P turned back on in Viktor's main AIOStreams config.

Each run reads the account's addons with a saved session key (no sign-in, so
no login traffic against Stremio's API), asks every stream addon that serves
IMDb ids for three fixed titles, and pushes per addon the number of rows that
carry an infoHash. Alert StremioTorrentRowsOnAccount fires on any.
One attempt per run; a dead session key fails the run (StremioTorrentGuardStale).

Standard library only. Tests: cd files && python3 -m unittest test_torrent_row_guard
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field

API = "https://api.strem.io/api"
# A film, a long-running series and a new Bulgarian season with torrent-only releases.
TITLES = (("movie", "tt1375666"), ("series", "tt0903747:1:1"), ("series", "tt1909015:6:2"))
PUSHGATEWAY = "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/stremio-torrent-guard"


def post_or_get(url: str, body: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, headers={"User-Agent": "torrent-row-guard",
                                                             "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


@dataclass
class Result:
    ok: bool
    torrent_rows: dict = field(default_factory=dict)
    failed: list = field(default_factory=list)
    error: str = ""


def serves_imdb_streams(manifest: dict) -> bool:
    for res in manifest.get("resources") or []:
        if res == "stream":
            prefixes = manifest.get("idPrefixes")
            types = manifest.get("types") or []
        elif isinstance(res, dict) and res.get("name") == "stream":
            prefixes = res.get("idPrefixes", manifest.get("idPrefixes"))
            types = res.get("types", manifest.get("types")) or []
        else:
            continue
        if prefixes is not None and not any(p == "tt" or "tt".startswith(p) for p in prefixes):
            return False
        return bool({"movie", "series"} & set(types))
    return False


def check(auth_key: str, fetch=post_or_get) -> Result:
    try:
        reply = fetch(f"{API}/addonCollectionGet", {"type": "AddonCollectionGet", "authKey": auth_key, "update": True})
    except (urllib.error.URLError, TimeoutError, ValueError) as e:
        return Result(ok=False, error=repr(e))
    if "result" not in reply:
        return Result(ok=False, error=json.dumps(reply.get("error") or reply)[:200])
    result = Result(ok=True)
    for a in reply["result"].get("addons") or []:
        url, manifest = a.get("transportUrl") or "", a.get("manifest") or {}
        if url.startswith("http://127.0.0.1") or not serves_imdb_streams(manifest):
            continue
        base = url.rsplit("/manifest.json", 1)[0]
        name = manifest.get("name") or base
        count = 0
        try:
            for kind, media_id in TITLES:
                streams = fetch(f"{base}/stream/{kind}/{urllib.parse.quote(media_id, safe=':')}.json").get("streams") or []
                count += sum(1 for s in streams if s.get("infoHash"))
        except (urllib.error.URLError, TimeoutError, ValueError) as e:
            print(f"{name}: not checked: {e!r}", file=sys.stderr)
            result.failed.append(name)
            continue
        result.torrent_rows[name] = count
    return result


def label(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def metrics(result: Result, now: float | None = None) -> str:
    lines = ["# TYPE stremio_torrent_rows gauge"]
    lines += [f'stremio_torrent_rows{{addon="{label(n)}"}} {c}' for n, c in sorted(result.torrent_rows.items())]
    lines.append("# TYPE stremio_torrent_guard_addon_failed gauge")
    lines += [f'stremio_torrent_guard_addon_failed{{addon="{label(n)}"}} 1' for n in result.failed]
    lines.append("# TYPE stremio_torrent_guard_success gauge")
    lines.append(f"stremio_torrent_guard_success {1 if result.ok else 0}")
    lines.append("# TYPE stremio_torrent_guard_last_run_timestamp gauge")
    lines.append(f"stremio_torrent_guard_last_run_timestamp {int(now if now is not None else time.time())}")
    return "\n".join(lines) + "\n"


def main() -> int:
    result = check(os.environ["STREMIO_AUTH_KEY"])
    print(json.dumps({"ok": result.ok, "torrent_rows": result.torrent_rows, "failed": result.failed, "error": result.error}))
    body = metrics(result).encode()
    try:
        # PUT replaces the job's group, so an addon that left the account drops out.
        urllib.request.urlopen(urllib.request.Request(PUSHGATEWAY, data=body, method="PUT"), timeout=10)
    except (urllib.error.URLError, TimeoutError) as e:
        print(f"pushgateway: {e!r}", file=sys.stderr)
    return 0 if result.ok else 1


if __name__ == "__main__":
    sys.exit(main())
