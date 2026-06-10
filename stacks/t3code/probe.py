"""t3-probe: differential path-health probe behind the t3 drop attribution.

Holds long-lived WebSockets to t3-dispatch's /probe/ws echo endpoint via two
routes that differ ONLY in the Cloudflare segment, plus an HTTP heartbeat
against the t3-serve process itself:

  leg=cloudflare  wss://T3_HOST/probe/ws connected to the address PUBLIC DNS
                  returns (DoH @1.1.1.1) -> WAN -> CF edge -> tunnel ->
                  cloudflared -> Traefik -> t3-dispatch
  leg=internal    same URL pinned to the internal Traefik LB -> Traefik ->
                  t3-dispatch (no Cloudflare)
  leg=t3serve     GET http://DEVVM:3773/api/auth/session every 10s; an
                  event-loop stall in the user's `t3 serve` delays/times-out
                  this regardless of auth

Attribution: cloudflare drops alone -> Cloudflare/WAN segment; cloudflare +
internal together -> Traefik/dispatch/devvm network; t3serve latency spikes ->
the serve process (memory/IO stalls); all legs clean while a human drops ->
their last mile, infra exonerated. Mirrors the real t3 client's resilience
protocol (10s heartbeat, ~20s watchdog) so probe drops mean a real client
would have dropped too.
"""

import asyncio
import json
import logging
import time

import aiohttp
from aiohttp.abc import AbstractResolver
from prometheus_client import Counter, Gauge, Histogram, start_http_server

T3_HOST = "t3.viktorbarzin.me"
TRAEFIK_LB = "10.0.20.203"
DEVVM = "10.0.10.10"
T3_SERVE_PORT = 3773
DOH_URL = "https://1.1.1.1/dns-query"
HEARTBEAT_SECONDS = 10
RTT_TIMEOUT_SECONDS = 20  # mirror the t3 client watchdog
METRICS_PORT = 9108

log = logging.getLogger("t3probe")

CONNECTED = Gauge("t3probe_connected", "1 while the leg's connection is up", ["leg"])
DISCONNECTS = Counter(
    "t3probe_disconnects_total", "Connection deaths by leg and reason", ["leg", "reason"]
)
RTT = Histogram(
    "t3probe_rtt_seconds",
    "Heartbeat round-trip (WS echo / HTTP GET) per leg",
    ["leg"],
    buckets=[0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 20],
)
CONNECTION_AGE = Histogram(
    "t3probe_connection_age_seconds",
    "Age of a WS connection when it died",
    ["leg"],
    buckets=[10, 30, 60, 300, 900, 3600, 14400, 86400],
)
LAST_DISCONNECT = Gauge(
    "t3probe_last_disconnect_timestamp", "Unix time of the leg's last death", ["leg"]
)


class PinnedResolver(AbstractResolver):
    """Resolve T3_HOST to one fixed address; Host/SNI/cert stay hostname-true."""

    def __init__(self, address):
        self.address = address

    async def resolve(self, host, port=0, family=0):
        return [
            {
                "hostname": host,
                "host": self.address,
                "port": port,
                "family": 2,  # AF_INET
                "proto": 0,
                "flags": 0,
            }
        ]

    async def close(self):
        pass


class DoHResolver(AbstractResolver):
    """Resolve via Cloudflare DoH so the answer is the PUBLIC (proxied) one.

    The cluster's own DNS is split-horizon since 2026-06-10 (pods get internal
    answers for *.viktorbarzin.me), which would silently collapse this leg
    onto the internal route — public resolution must bypass it.
    """

    async def resolve(self, host, port=0, family=0):
        async with aiohttp.ClientSession() as s:
            async with s.get(
                DOH_URL,
                params={"name": host, "type": "A"},
                headers={"accept": "application/dns-json"},
                timeout=aiohttp.ClientTimeout(total=10),
            ) as resp:
                answers = (await resp.json(content_type=None)).get("Answer", [])
        addrs = [a["data"] for a in answers if a.get("type") == 1]
        if not addrs:
            raise OSError(f"DoH returned no A records for {host}")
        return [
            {
                "hostname": host,
                "host": addrs[0],
                "port": port,
                "family": 2,
                "proto": 0,
                "flags": 0,
            }
        ]

    async def close(self):
        pass


async def ws_leg(leg, resolver):
    url = f"wss://{T3_HOST}/probe/ws"
    attempts = 0
    while True:
        CONNECTED.labels(leg).set(0)
        established = None
        reason = "connect_failed"
        try:
            connector = aiohttp.TCPConnector(resolver=resolver, force_close=True)
            async with aiohttp.ClientSession(connector=connector) as session:
                async with session.ws_connect(
                    url, timeout=aiohttp.ClientWSTimeout(ws_close=10), heartbeat=None
                ) as ws:
                    established = time.monotonic()
                    attempts = 0
                    CONNECTED.labels(leg).set(1)
                    log.info("%s: connected", leg)
                    while True:
                        sent = time.monotonic()
                        await ws.send_str(f"ping {time.time_ns()}")
                        msg = await ws.receive(timeout=RTT_TIMEOUT_SECONDS)
                        if msg.type != aiohttp.WSMsgType.TEXT:
                            reason = f"closed_{msg.type.name.lower()}"
                            break
                        RTT.labels(leg).observe(time.monotonic() - sent)
                        await asyncio.sleep(HEARTBEAT_SECONDS)
        except asyncio.TimeoutError:
            reason = "rtt_timeout" if established else "connect_timeout"
        except (aiohttp.ClientError, OSError) as e:
            reason = "connect_failed" if not established else "io_error"
            log.warning("%s: %s: %s", leg, reason, e)
        CONNECTED.labels(leg).set(0)
        DISCONNECTS.labels(leg, reason).inc()
        LAST_DISCONNECT.labels(leg).set(time.time())
        if established is not None:
            CONNECTION_AGE.labels(leg).observe(time.monotonic() - established)
            log.info("%s: died after %.0fs (%s)", leg, time.monotonic() - established, reason)
        attempts += 1
        await asyncio.sleep(min(3 * attempts, 30))


async def t3serve_leg():
    leg = "t3serve"
    url = f"http://{DEVVM}:{T3_SERVE_PORT}/api/auth/session"
    timeout = aiohttp.ClientTimeout(total=RTT_TIMEOUT_SECONDS)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        while True:
            sent = time.monotonic()
            try:
                async with session.get(url) as resp:
                    await resp.read()
                    RTT.labels(leg).observe(time.monotonic() - sent)
                    CONNECTED.labels(leg).set(1 if resp.status == 200 else 0)
                    if resp.status != 200:
                        DISCONNECTS.labels(leg, f"http_{resp.status}").inc()
                        LAST_DISCONNECT.labels(leg).set(time.time())
            except asyncio.TimeoutError:
                CONNECTED.labels(leg).set(0)
                DISCONNECTS.labels(leg, "rtt_timeout").inc()
                LAST_DISCONNECT.labels(leg).set(time.time())
            except (aiohttp.ClientError, OSError) as e:
                CONNECTED.labels(leg).set(0)
                DISCONNECTS.labels(leg, "connect_failed").inc()
                LAST_DISCONNECT.labels(leg).set(time.time())
                log.warning("%s: %s", leg, e)
            await asyncio.sleep(HEARTBEAT_SECONDS)


async def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    start_http_server(METRICS_PORT)
    await asyncio.gather(
        ws_leg("cloudflare", DoHResolver()),
        ws_leg("internal", PinnedResolver(TRAEFIK_LB)),
        t3serve_leg(),
    )


if __name__ == "__main__":
    asyncio.run(main())
