"""Drive the iOS rig phone over Wi-Fi from the devvm, with no Mac in the loop.

`homelab ios wifi-fg` runs this as a long-lived service. It holds one
RemotePairing tunnel to the phone (pymobiledevice3, userspace, no root), keeps
the developer disk image mounted, keeps WebDriverAgent running while its
free-team signature is valid, and serves a small HTTP API on loopback that the
Go CLI calls. One process has to own the tunnel anyway: WDA lives only as long
as the process that launched its XCUITest session.

The pairing comes from the London Mac (docs/runbooks/ios-test-rig.md):
~/.pymobiledevice3/remote_<UDID>.plist, with `host_identifier` set to the
Mac's host id, because the phone stores the host under the id of the machine
that paired it.
"""

import asyncio
import json
import logging
import os
import socket
import time
import urllib.error
import urllib.request
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, TypeVar

log = logging.getLogger("ios-rig-wifi")

T = TypeVar("T")

# The phone's RemotePairing control channel. 49152 is where iOS 26 put it on
# the rig phone; it is not guaranteed, so a miss falls back to a port scan.
DEFAULT_PAIRING_PORT = 49152
SCAN_RANGE = (49152, 65535)
WDA_PORT = 8100


@dataclass
class Config:
    udid: str
    host: str
    fallback_ip: str
    listen: str
    wda_bundle_id: str
    state_dir: Path
    scan_cooldown: float

    @classmethod
    def from_env(cls) -> "Config":
        env = os.environ.get
        return cls(
            udid=env("IOS_RIG_UDID", "00008110-001614D03442801E"),
            host=env("IOS_RIG_PHONE_HOST", "iphone-london.viktorbarzin.lan"),
            # The Flint's static lease (scripts/london-flint/provision.sh), used
            # when the name does not resolve.
            fallback_ip=env("IOS_RIG_PHONE_ADDR", "192.168.9.205"),
            listen=env("IOS_RIG_WIFI_LISTEN", "127.0.0.1:8102"),
            wda_bundle_id=env("IOS_RIG_WDA_BUNDLE_ID", "me.viktorbarzin.wda") + ".xctrunner",
            state_dir=Path(env("IOS_RIG_STATE_DIR", str(Path.home() / ".local/state/ios-rig"))),
            scan_cooldown=float(env("IOS_RIG_SCAN_COOLDOWN_SECONDS", "300")),
        )


# ---------------------------------------------------------------- pure logic


def resolve_phone(host: str, fallback_ip: str, resolver: Callable[[str], str] = socket.gethostbyname) -> str:
    """The phone's address by name, or the pinned lease when DNS has no
    answer, so a Technitium outage does not take the rig with it."""
    try:
        return resolver(host)
    except OSError:
        return fallback_ip


def candidate_ports(cached: int | None, scanned: list[int]) -> list[int]:
    """Order to try pairing ports in: the last one that worked, the usual one,
    then whatever a scan found. No duplicates, order kept."""
    out: list[int] = []
    for p in [cached, DEFAULT_PAIRING_PORT, *scanned]:
        if p is not None and p not in out:
            out.append(p)
    return out


def should_scan(last_failed_scan: float | None, now: float, cooldown: float) -> bool:
    """A scan is 16k connection attempts. Without a cooldown a phone that is
    simply away turns the reconnect loop into a port scanner (the Mac
    discovery had exactly this bug, see #13488). A clock that went backwards
    reads as "long ago" so recovery is never blocked."""
    if last_failed_scan is None:
        return True
    elapsed = now - last_failed_scan
    return elapsed < 0 or elapsed >= cooldown


def summarise_battery(raw: dict[str, Any] | None) -> dict[str, Any] | None:
    """The few fields that answer "is it on the charger and how full"."""
    if not raw:
        return None
    return {
        "percent": raw.get("CurrentCapacity"),
        "charging": bool(raw.get("IsCharging")),
        "external_power": bool(raw.get("ExternalConnected")),
        "fully_charged": bool(raw.get("FullyCharged")),
    }


SAFARI_SETTINGS_HINT = (
    "Safari automation is switched off on the phone: Settings > Apps > Safari > Advanced, "
    "turn on Web Inspector and Remote Automation"
)


def launch_failure_reason(bundle_id: str, message: str) -> str:
    """A refused launch is almost always a lapsed free-team signature."""
    if "failed to launch process" in message.lower():
        return (
            f"iOS refused to launch {bundle_id}: if it is a sideloaded app, its free-team signature has "
            "most likely expired (7 days); rebuild it with `homelab ios install <dir>`. Otherwise check "
            "the bundle id with `homelab ios apps`."
        )
    return message


def wda_failure_reason(message: str) -> str:
    """Turn an XCUITest launch error into what a person can act on."""
    low = message.lower()
    if "provisioning profile has expired" in low:
        return (
            "WDA would not launch: its free-team signature expired (7 days). "
            "Re-sign it: plug the phone into the Mac and run the wda-resign job."
        )
    if "failed to launch process" in low:
        return (
            "iOS refused to launch WDA: its 7-day signature may have expired (doctor's last-resign shows "
            "when it was signed), or the launch raced another session that was ending. The service retries."
        )
    if "not trusted" in low:
        return "WDA's developer certificate is not trusted: Settings > General > VPN & Device Management > Trust."
    if "testmanagerd" in low or "no such service" in low:
        return "Developer services are missing: the developer disk image is not mounted."
    return message


# ---------------------------------------------------------------- the device


class PhoneUnavailable(RuntimeError):
    pass


@dataclass
class WdaState:
    task: asyncio.Task | None = None
    last_error: str | None = None
    started_at: float | None = None
    attempts: int = 0


@dataclass
class Rig:
    cfg: Config
    _rsd: Any = None
    _tunnel: Any = None
    _lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    _connected_port: int | None = None
    _last_error: str | None = None
    wda: WdaState = field(default_factory=WdaState)

    # -- addressing

    def _phone_ip(self) -> str:
        return resolve_phone(self.cfg.host, self.cfg.fallback_ip)

    def _read_state(self, name: str) -> str | None:
        try:
            return (self.cfg.state_dir / name).read_text().strip()
        except OSError:
            return None

    def _write_state(self, name: str, value: str) -> None:
        self.cfg.state_dir.mkdir(parents=True, exist_ok=True)
        (self.cfg.state_dir / name).write_text(value)

    async def _scan(self, ip: str) -> list[int]:
        last = self._read_state("scan-failed")
        last_ts = float(last) if last else None
        if not should_scan(last_ts, time.time(), self.cfg.scan_cooldown):
            return []
        sem = asyncio.Semaphore(256)

        async def probe(port: int) -> int | None:
            async with sem:
                try:
                    _, w = await asyncio.wait_for(asyncio.open_connection(ip, port), 2)
                    w.close()
                    return port
                except (TimeoutError, OSError):
                    return None

        found = [p for p in await asyncio.gather(*(probe(p) for p in range(SCAN_RANGE[0], SCAN_RANGE[1] + 1))) if p]
        # 62078 is classic lockdown and 8100 is WDA; neither is the pairing channel.
        found = [p for p in found if p not in (62078, WDA_PORT)]
        if not found:
            self._write_state("scan-failed", str(time.time()))
        return found

    # -- tunnel

    async def _open(self) -> Any:
        from pymobiledevice3.remote import userspace_tunnel as ut
        from pymobiledevice3.remote.tunnel_service import create_core_device_tunnel_service_using_remotepairing

        ip = self._phone_ip()
        cached = self._read_state("pairing-port")
        ports = candidate_ports(int(cached) if cached else None, [])
        errors: list[str] = []

        async def attempt(port: int) -> Any:
            async def provider(serial, autopair, remotepairing_fallback=True):
                svc = await create_core_device_tunnel_service_using_remotepairing(self.cfg.udid, ip, port, autopair=False)
                return svc, None

            ut._create_no_root_tunnel_provider = provider
            tunnel = ut.UserspaceRsdTunnel(serial=self.cfg.udid)
            rsd = await asyncio.wait_for(tunnel.aopen(), 60)
            return tunnel, rsd

        for round_ in (0, 1):
            for port in ports:
                try:
                    self._tunnel, rsd = await attempt(port)
                    self._connected_port = port
                    self._write_state("pairing-port", str(port))
                    log.info("tunnel up to %s:%s (%s %s)", ip, port, rsd.product_type, rsd.product_version)
                    return rsd
                except Exception as e:  # noqa: BLE001 - every failure means "try the next port"
                    errors.append(f"{port}: {type(e).__name__} {e}"[:200])
            if round_ == 0:
                ports = [p for p in candidate_ports(None, await self._scan(ip)) if p not in ports]
                if not ports:
                    break
        raise PhoneUnavailable(f"no RemotePairing answer from {self.cfg.host} ({ip}): " + "; ".join(errors[-4:]))

    async def rsd(self) -> Any:
        async with self._lock:
            if self._rsd is None:
                try:
                    self._rsd = await self._open()
                    self._last_error = None
                    await self._ensure_ddi()
                except Exception as e:
                    self._last_error = str(e)
                    raise
            return self._rsd

    async def drop(self) -> None:
        async with self._lock:
            tunnel, self._tunnel, self._rsd = self._tunnel, None, None
            if tunnel is not None:
                try:
                    await tunnel.aclose()
                except Exception:
                    log.debug("tunnel close failed", exc_info=True)

    async def call(self, fn: Callable[[Any], Awaitable[T]]) -> T:
        """Run fn(rsd); on a transport error rebuild the tunnel and retry once."""
        for attempt in (0, 1):
            rsd = await self.rsd()
            try:
                return await fn(rsd)
            except (TimeoutError, ConnectionError, OSError, asyncio.IncompleteReadError) as e:
                log.warning("device call failed (%s), rebuilding the tunnel", e)
                await self.drop()
                if attempt:
                    raise PhoneUnavailable(str(e)) from e
        raise AssertionError("unreachable")

    async def _ensure_ddi(self) -> None:
        from pymobiledevice3.exceptions import AlreadyMountedError
        from pymobiledevice3.services.mobile_image_mounter import MobileImageMounterService, auto_mount

        async with MobileImageMounterService(lockdown=self._rsd) as m:
            if await m.is_image_mounted("Personalized"):
                return
        log.info("mounting the developer disk image")
        try:
            await auto_mount(self._rsd)
        except AlreadyMountedError:
            pass

    # -- operations

    async def screenshot(self) -> bytes:
        from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
        from pymobiledevice3.services.dvt.instruments.screenshot import Screenshot

        async def op(rsd: Any) -> bytes:
            async with DvtProvider(rsd) as dvt, Screenshot(dvt) as s:
                return await s.get_screenshot()

        return await self.call(op)

    async def apps(self, include_system: bool) -> dict[str, Any]:
        from pymobiledevice3.services.installation_proxy import InstallationProxyService

        async def op(rsd: Any) -> dict[str, Any]:
            async with InstallationProxyService(lockdown=rsd) as ip:
                apps = await ip.get_apps(application_type="Any" if include_system else "User")
            return {
                b: {
                    "name": a.get("CFBundleDisplayName") or a.get("CFBundleName"),
                    "version": a.get("CFBundleShortVersionString"),
                    "type": a.get("ApplicationType"),
                }
                for b, a in sorted(apps.items())
            }

        return await self.call(op)

    async def launch(self, bundle_id: str, args: list[str]) -> int:
        from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
        from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl

        async def op(rsd: Any) -> int:
            async with DvtProvider(rsd) as dvt, ProcessControl(dvt) as pc:
                try:
                    return await pc.launch(bundle_id, arguments=args)
                except Exception as e:
                    if isinstance(e, (ConnectionError, OSError)):
                        raise
                    raise RuntimeError(launch_failure_reason(bundle_id, str(e))) from e

        return await self.call(op)

    async def install(self, ipa: bytes) -> None:
        from pymobiledevice3.services.installation_proxy import InstallationProxyService

        async def op(rsd: Any) -> None:
            async with InstallationProxyService(lockdown=rsd) as ip:
                await ip.install_from_bytes(ipa)

        await self.call(op)

    async def location(self, lat: float | None, lon: float | None) -> None:
        from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
        from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation

        async def op(rsd: Any) -> None:
            async with DvtProvider(rsd) as dvt, LocationSimulation(dvt) as loc:
                if lat is None or lon is None:
                    await loc.clear()
                else:
                    await loc.set(lat, lon)

        await self.call(op)

    async def safari(self, url: str, script: str | None, settle: float) -> dict[str, Any]:
        """Open url in real Safari through Web Inspector automation. Needs
        Settings > Apps > Safari > Advanced > Web Inspector and Remote
        Automation on the phone; no signing is involved. Starting an
        automation session ends WDA's XCTest session (measured 2026-10-12);
        keep_wda restarts WDA about 30 seconds later."""
        from pymobiledevice3.exceptions import RemoteAutomationNotEnabledError, WebInspectorNotEnabledError
        from pymobiledevice3.services.web_protocol.driver import WebDriver
        from pymobiledevice3.services.webinspector import SAFARI, WebinspectorService

        async def op(rsd: Any) -> dict[str, Any]:
            inspector = WebinspectorService(lockdown=rsd)
            try:
                await inspector.connect()
            except (WebInspectorNotEnabledError, RemoteAutomationNotEnabledError) as e:
                raise RuntimeError(SAFARI_SETTINGS_HINT) from e
            try:
                try:
                    session = await inspector.automation_session(await inspector.open_app(SAFARI))
                except (WebInspectorNotEnabledError, RemoteAutomationNotEnabledError) as e:
                    raise RuntimeError(SAFARI_SETTINGS_HINT) from e
                driver = WebDriver(session)
                await driver.start_session()
                try:
                    await driver.get(url)
                    await asyncio.sleep(settle)
                    result = await driver.execute_script(script) if script else None
                    return {"title": await driver.get_title(), "url": await driver.get_current_url(), "result": result}
                finally:
                    await session.stop_session()
            finally:
                await inspector.close()

        return await self.call(op)

    async def battery(self) -> dict[str, Any] | None:
        from pymobiledevice3.services.diagnostics import DiagnosticsService

        async def op(rsd: Any) -> dict[str, Any] | None:
            async with DiagnosticsService(lockdown=rsd) as d:
                return summarise_battery(await d.get_battery())

        return await self.call(op)

    # -- WebDriverAgent

    def wda_url(self) -> str:
        return f"http://{self._phone_ip()}:{WDA_PORT}"

    def wda_ready(self) -> bool:
        try:
            with urllib.request.urlopen(self.wda_url() + "/status", timeout=3) as r:
                return bool(json.load(r).get("value", {}).get("ready"))
        except (OSError, ValueError, urllib.error.URLError):
            return False

    async def start_wda(self) -> None:
        from pymobiledevice3.services.dvt.testmanaged.xcuitest import TestConfig, XCUITestService

        if self.wda.task is not None and not self.wda.task.done():
            return
        rsd = await self.rsd()
        cfg = await TestConfig.create_for(rsd, self.cfg.wda_bundle_id)
        self.wda.attempts += 1
        self.wda.started_at = time.time()
        self.wda.task = asyncio.create_task(XCUITestService(rsd).run(cfg), name="wda")

    async def keep_wda(self) -> None:
        """Keep WDA up while it can be. After a failure, wait longer each time
        (capped at 30 minutes) so an expired signature costs one launch
        attempt per half hour, not one per loop."""
        while True:
            delay = 30.0
            try:
                if not self.wda_ready():
                    task = self.wda.task
                    if task is not None and task.done():
                        exc = task.exception()
                        self.wda.last_error = wda_failure_reason(str(exc)) if exc else "WDA exited"
                        self.wda.task = None
                        delay = min(1800.0, 30.0 * (2 ** min(self.wda.attempts, 6)))
                    elif task is None:
                        await self.start_wda()
                else:
                    self.wda.last_error = None
                    self.wda.attempts = 0
            except Exception as e:  # noqa: BLE001
                self.wda.last_error = wda_failure_reason(str(e))
                delay = min(1800.0, 30.0 * (2 ** min(self.wda.attempts, 6)))
            await asyncio.sleep(delay)

    async def status(self) -> dict[str, Any]:
        out: dict[str, Any] = {"host": self.cfg.host, "checked_at": datetime.now(UTC).isoformat()}
        try:
            rsd = await self.rsd()
            out.update(
                connected=True,
                pairing_port=self._connected_port,
                product_type=rsd.product_type,
                ios=rsd.product_version,
            )
        except Exception as e:  # noqa: BLE001
            out.update(connected=False, error=str(e) or self._last_error)
            return out
        try:
            out["battery"] = await self.battery()
        except Exception as e:  # noqa: BLE001
            out["battery_error"] = str(e)
        ready = self.wda_ready()
        out["wda"] = {"ready": ready, "url": self.wda_url() if ready else None, "error": None if ready else self.wda.last_error}
        return out


# ---------------------------------------------------------------- HTTP API


def build_app(rig: Rig) -> Any:
    from fastapi import FastAPI, HTTPException, Request
    from fastapi.responses import Response
    from pydantic import BaseModel

    app = FastAPI(title="ios-rig-wifi")

    class LaunchBody(BaseModel):
        bundle_id: str
        args: list[str] = []

    class SafariBody(BaseModel):
        url: str
        script: str | None = None
        settle: float = 2.0

    class LocationBody(BaseModel):
        lat: float | None = None
        lon: float | None = None

    async def guarded(coro: Awaitable[T]) -> T:
        try:
            return await coro
        except PhoneUnavailable as e:
            raise HTTPException(503, str(e)) from e
        except Exception as e:
            raise HTTPException(500, f"{type(e).__name__}: {e}") from e

    @app.get("/status")
    async def status() -> dict[str, Any]:
        return await rig.status()

    @app.get("/screenshot")
    async def screenshot() -> Response:
        return Response(await guarded(rig.screenshot()), media_type="image/png")

    @app.get("/apps")
    async def apps(system: bool = False) -> dict[str, Any]:
        return await guarded(rig.apps(system))

    @app.post("/launch")
    async def launch(body: LaunchBody) -> dict[str, Any]:
        return {"pid": await guarded(rig.launch(body.bundle_id, body.args))}

    @app.post("/install")
    async def install(request: Request) -> dict[str, Any]:
        await guarded(rig.install(await request.body()))
        return {"installed": True}

    @app.post("/safari")
    async def safari(body: SafariBody) -> dict[str, Any]:
        return await guarded(rig.safari(body.url, body.script, body.settle))

    @app.post("/location")
    async def location(body: LocationBody) -> dict[str, Any]:
        await guarded(rig.location(body.lat, body.lon))
        return {"simulated": body.lat is not None}

    @app.post("/reconnect")
    async def reconnect() -> dict[str, Any]:
        await rig.drop()
        return await rig.status()

    return app


async def serve(cfg: Config) -> None:
    import uvicorn

    rig = Rig(cfg)
    host, port = cfg.listen.rsplit(":", 1)
    server = uvicorn.Server(uvicorn.Config(build_app(rig), host=host, port=int(port), log_level="warning"))
    keeper = asyncio.create_task(rig.keep_wda(), name="keep-wda")
    try:
        await server.serve()
    finally:
        keeper.cancel()
        await rig.drop()


def main() -> None:
    logging.basicConfig(level=os.environ.get("IOS_RIG_LOG", "INFO"), format="%(levelname)s %(name)s: %(message)s")
    asyncio.run(serve(Config.from_env()))


if __name__ == "__main__":
    main()
