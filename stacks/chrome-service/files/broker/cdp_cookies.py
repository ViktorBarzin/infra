#!/usr/bin/env python3
"""Read a Chrome browser's cookies over raw CDP and shape them like Playwright.

Why not playwright / patchright
-------------------------------
``connect_over_cdp`` attaches at the BROWSER level, enumerates every existing
target and asserts that each one carries a ``browserContextId``. A service
worker that outlives the context which registered it has none, so the assert
kills the node driver and the caller gets nothing back.

That is not theoretical here. On 2026-09-18 a single orphaned target on the
chrome-service master,

    Error: targetInfo: { "type": "service_worker",
                         "targetId": "B5E87D875D63402AA259A3349AEFD7D8", ... }

broke every ``GET /seed`` on the broker (343 errors, five
ChromePoolSeedExportFailing episodes) and all ten hourly snapshot-harvester
runs between 13:23 and 23:23, until the master pod was recreated at 01:38 the
next morning. ``f1-stream/backend/cdp.py`` hit the same assert on pool workers
and moved to raw CDP for the same reason.

This module issues ONE browser-level command, ``Storage.getCookies``. It never
lists targets and never attaches to one, so an orphan cannot take it down.

Why stdlib only
---------------
Same constraint as ``cdp_bridge.py``: the Playwright image ships no websocket
package, and the seed path should not gain a pip dependency it has to install
before it can answer. The client below speaks just enough of RFC 6455 to send
one command and read one reply.

What is NOT covered
-------------------
localStorage. Playwright collects it per origin by evaluating in a page, which
needs the target attachment this module exists to avoid. Measured against the
live master on 2026-09-19: ``storage_state()`` returned 225 cookies and an
EMPTY ``origins`` list, because a freshly connected CDP client only knows the
origins of pages open at that moment (here, chrome://newtab). The seed carries
cookies; ``origins`` was always ``[]``.
"""

import base64
import json
import os
import socket
import struct
import urllib.parse
import urllib.request

# Playwright's default when Chrome reports no sameSite for a cookie. Verified
# against the live master on 2026-09-19: the cookies CDP returns without a
# sameSite come back from storage_state() as "Lax".
DEFAULT_SAME_SITE = "Lax"

_OP_CONT, _OP_TEXT, _OP_BIN, _OP_CLOSE, _OP_PING, _OP_PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA


class _Framer:
    """The client half of an RFC 6455 connection, one command deep."""

    def __init__(self, sock: socket.socket, leftover: bytes = b"") -> None:
        self._sock = sock
        self._buf = leftover

    def _read(self, n: int) -> bytes:
        while len(self._buf) < n:
            chunk = self._sock.recv(65536)
            if not chunk:
                raise ConnectionError("CDP websocket closed by the browser")
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def send(self, opcode: int, payload: bytes) -> None:
        header = bytearray([0x80 | opcode])
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < 1 << 16:
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        mask = os.urandom(4)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self._sock.sendall(bytes(header) + masked)

    def _frame(self) -> tuple[bool, int, bytes]:
        b0, b1 = self._read(2)
        fin, opcode = bool(b0 & 0x80), b0 & 0x0F
        length = b1 & 0x7F
        if length == 126:
            length = struct.unpack(">H", self._read(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._read(8))[0]
        mask = self._read(4) if b1 & 0x80 else b""
        payload = self._read(length) if length else b""
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return fin, opcode, payload

    def message(self) -> bytes:
        """Next application message, answering pings and joining continuations."""
        data, started = b"", False
        while True:
            fin, opcode, payload = self._frame()
            if opcode == _OP_CLOSE:
                raise ConnectionError("CDP websocket closed by the browser")
            if opcode == _OP_PING:
                self.send(_OP_PONG, payload)
                continue
            if opcode == _OP_PONG:
                continue
            if opcode in (_OP_TEXT, _OP_BIN):
                data, started = payload, True
            elif opcode == _OP_CONT and started:
                data += payload
            if fin and started:
                return data

    def close(self) -> None:
        try:
            self.send(_OP_CLOSE, b"")
        except OSError:
            pass
        self._sock.close()


def _handshake(ws_url: str, timeout: float) -> _Framer:
    parts = urllib.parse.urlsplit(ws_url)
    sock = socket.create_connection((parts.hostname, parts.port or 80), timeout=timeout)
    sock.settimeout(timeout)
    path = parts.path + (("?" + parts.query) if parts.query else "")
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {parts.netloc}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {base64.b64encode(os.urandom(16)).decode()}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    )
    sock.sendall(request.encode("latin-1"))
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("CDP websocket closed during the upgrade")
        head += chunk
    headers, leftover = head.split(b"\r\n\r\n", 1)
    status = headers.split(b"\r\n", 1)[0].decode("latin-1", "replace")
    if " 101 " not in status:
        raise ConnectionError(f"CDP websocket upgrade refused: {status}")
    return _Framer(sock, leftover)


def as_storage_state_cookie(cookie: dict) -> dict:
    """One CDP Network.Cookie in the shape Playwright's storageState uses.

    Playwright keeps name/value/domain/path/expires/httpOnly/secure as-is, fills
    a missing sameSite with "Lax", splits CDP's partitionKey object into a
    partitionKey string plus _crHasCrossSiteAncestor, and drops the fields it
    has no slot for (priority, session, size, sourcePort, sourceScheme).
    """
    out = {
        "name": cookie["name"],
        "value": cookie["value"],
        "domain": cookie["domain"],
        "path": cookie["path"],
        "expires": cookie.get("expires", -1),
        "httpOnly": cookie.get("httpOnly", False),
        "secure": cookie.get("secure", False),
        "sameSite": cookie.get("sameSite") or DEFAULT_SAME_SITE,
    }
    partition = cookie.get("partitionKey")
    if isinstance(partition, dict):
        out["partitionKey"] = partition.get("topLevelSite")
        out["_crHasCrossSiteAncestor"] = partition.get("hasCrossSiteAncestor", False)
    elif partition:
        out["partitionKey"] = partition
    return out


def storage_state(cdp_base: str, timeout: float = 20.0) -> dict:
    """The master's cookies as a Playwright storageState dict.

    `origins` is always empty — see the module docstring.
    """
    version_url = cdp_base.rstrip("/") + "/json/version"
    with urllib.request.urlopen(version_url, timeout=timeout) as resp:
        ws_url = json.loads(resp.read())["webSocketDebuggerUrl"]
    framer = _handshake(ws_url, timeout)
    try:
        framer.send(_OP_TEXT, json.dumps({"id": 1, "method": "Storage.getCookies"}).encode())
        while True:
            message = json.loads(framer.message())
            if message.get("id") != 1:
                continue
            if "error" in message:
                raise RuntimeError(f"Storage.getCookies failed: {message['error']}")
            cookies = message["result"]["cookies"]
            break
    finally:
        framer.close()
    return {"cookies": [as_storage_state_cookie(c) for c in cookies], "origins": []}


if __name__ == "__main__":
    # Hand-check the master: python3 cdp_cookies.py [cdp-base-url]
    import sys

    base = sys.argv[1] if len(sys.argv) > 1 else os.environ.get(
        "MASTER_CDP_URL", "http://chrome-service.chrome-service.svc:9222")
    json.dump(storage_state(base), sys.stdout)
