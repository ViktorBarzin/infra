"""Report the health of changedetection's deal watches to the Pushgateway.

changedetection posts a Slack line when a watched price drops, and says
nothing otherwise. A watch that stopped checking, or that cannot find the
price any more, looks the same as a price that did not move. This job reads
every watch in the "deals" group through changedetection's API and pushes
one set of gauges per watch, so Prometheus can tell the two apart
(alerts DealWatch* in stacks/monitoring).

It replaces the whole Pushgateway group on each run (HTTP PUT), so a watch
deleted in changedetection stops being reported. It exits non-zero when the
API cannot be read, and then pushes nothing: the success timestamp ages and
DealWatchExporterStale fires.

Stdlib only; runs on python:alpine with no install step.
Runbook: docs/runbooks/deal-watches.md
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable, Mapping

# changedetection's global default between checks (Settings > Fetching),
# used by a watch that sets no interval of its own. Ours is 3 h.
DEFAULT_INTERVAL_S = 3 * 3600

UNIT_S = {"weeks": 604800, "days": 86400, "hours": 3600, "minutes": 60, "seconds": 1}

ApiGet = Callable[[str], Any]


@dataclass(frozen=True)
class WatchStatus:
    uuid: str
    title: str
    paused: bool
    last_checked: int
    interval_s: int
    failing: bool
    notification_failing: bool
    price: float | None
    target: float | None


def interval_seconds(tbc: Mapping[str, Any] | None) -> int:
    total = sum(int(v) * UNIT_S[k] for k, v in (tbc or {}).items() if k in UNIT_S and v)
    return total or DEFAULT_INTERVAL_S


def _float(v: Any) -> float | None:
    return float(v) if v not in (None, "", False) else None


def collect(api_get: ApiGet, tag: str) -> list[WatchStatus]:
    out = []
    for uuid in sorted(api_get(f"watch?tag={tag}")):
        w = api_get(f"watch/{uuid}")
        state = w.get("processor_state_restock_diff") or {}
        config = w.get("processor_config_restock_diff") or {}
        out.append(WatchStatus(
            uuid=uuid,
            title=w.get("title") or w.get("url") or uuid,
            paused=bool(w.get("paused")),
            last_checked=int(w.get("last_checked") or 0),
            interval_s=interval_seconds(w.get("time_between_check")),
            failing=bool(w.get("last_error")),
            notification_failing=bool(w.get("last_notification_error")),
            price=_float(state.get("price")),
            target=_float(config.get("price_change_min")),
        ))
    return out


def _label(v: str) -> str:
    return v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def _num(v: float) -> str:
    return f"{v:g}" if isinstance(v, float) else str(v)


def render(statuses: list[WatchStatus], now: int) -> str:
    gauges: dict[str, list[str]] = {
        "deal_watch_last_checked_timestamp_seconds": [],
        "deal_watch_check_interval_seconds": [],
        "deal_watch_check_failing": [],
        "deal_watch_notification_failing": [],
        "deal_watch_paused": [],
        "deal_watch_price": [],
        "deal_watch_target_price": [],
    }
    for s in statuses:
        lab = f'{{uuid="{_label(s.uuid)}",title="{_label(s.title)}"}}'
        gauges["deal_watch_last_checked_timestamp_seconds"].append(f"{lab} {s.last_checked}")
        gauges["deal_watch_check_interval_seconds"].append(f"{lab} {s.interval_s}")
        gauges["deal_watch_check_failing"].append(f"{lab} {int(s.failing)}")
        gauges["deal_watch_notification_failing"].append(f"{lab} {int(s.notification_failing)}")
        gauges["deal_watch_paused"].append(f"{lab} {int(s.paused)}")
        if s.price is not None:
            gauges["deal_watch_price"].append(f"{lab} {_num(s.price)}")
        if s.target is not None:
            gauges["deal_watch_target_price"].append(f"{lab} {_num(s.target)}")
    lines = []
    for name, samples in gauges.items():
        lines.append(f"# TYPE {name} gauge")
        lines.extend(f"{name}{sample}" for sample in samples)
    lines.append("# TYPE deal_watches_total gauge")
    lines.append(f"deal_watches_total {len(statuses)}")
    lines.append("# TYPE deal_watches_exporter_last_success_timestamp_seconds gauge")
    lines.append(f"deal_watches_exporter_last_success_timestamp_seconds {now}")
    return "\n".join(lines) + "\n"


def api_key_from_env(env: Mapping[str, str]) -> str:
    return json.loads(env["CHANGEDETECTION_CREDENTIALS"])["changedetection"]["api_key"]


def http_api(base: str, key: str) -> ApiGet:
    def api_get(path: str) -> Any:
        req = urllib.request.Request(f"{base.rstrip('/')}/api/v1/{path}", headers={"x-api-key": key})
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    return api_get


def push(url: str, body: str) -> None:
    req = urllib.request.Request(url, data=body.encode(), method="PUT",
                                 headers={"Content-Type": "text/plain; version=0.0.4"})
    with urllib.request.urlopen(req, timeout=30):
        pass


def main() -> int:
    env = os.environ
    api = http_api(env.get("CHANGEDETECTION_URL", "http://changedetection.changedetection.svc.cluster.local"),
                   api_key_from_env(env))
    statuses = collect(api, tag=env.get("DEAL_TAG", "deals"))
    push(env["PUSHGATEWAY_URL"], render(statuses, now=int(time.time())))
    for s in statuses:
        age_h = (time.time() - s.last_checked) / 3600 if s.last_checked else float("inf")
        print(f"{s.title}: price {s.price} target {s.target}, checked {age_h:.1f} h ago, "
              f"failing={s.failing} notify_failing={s.notification_failing} paused={s.paused}")
    print(f"pushed {len(statuses)} deal watch(es)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
