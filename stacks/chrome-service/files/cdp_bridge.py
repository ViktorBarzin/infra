#!/usr/bin/env python3
"""CDP-aware proxy: 0.0.0.0:9222 → 127.0.0.1:9223 with Host header rewriting.

Why this exists:
  Stock Chrome binaries silently ignore --remote-debugging-address (the flag is
  gated by a build-time switch most distributions don't set), so CDP always
  binds 127.0.0.1:<port>. Worse, Chrome enforces DNS rebinding protection on
  the HTTP DevTools endpoint: any Host header that isn't `localhost`,
  `127.0.0.1`, or `[::1]` returns 500 "Host header is specified and is not an
  IP address or localhost". There is no `--remote-allow-hosts` flag in stock
  Chrome 130 (verified by binary string search).

  This means a raw TCP forwarder doesn't work — clients hitting the K8s
  Service DNS get 500 because Chrome rejects the Host header.

What this script does:
  - Listens on 0.0.0.0:9222 (the public CDP port the K8s Service exposes).
  - For each TCP connection from a CDP client:
      1. Read the HTTP request line + headers.
      2. Rewrite `Host: <whatever>` to `Host: localhost:9222`, remembering
         the original value (for response rewriting).
      3. Open a connection to Chrome at 127.0.0.1:9223 and forward the
         modified request line + headers + body.
      4. Read Chrome's HTTP response. If it's 101 Switching Protocols
         (WebSocket upgrade), forward it as-is and switch to raw byte piping
         in both directions (CDP frames are binary, no further parsing).
      5. Otherwise it's a regular HTTP/JSON response. Substitute
         `localhost:9222` (the URL Chrome composed from the rewritten Host)
         back to the client's original Host header value. Forward.
  - The Microsoft playwright image ships python3 but not socat, hence this
    stdlib-only helper.

Limitations:
  - Only HTTP/1.x supported (CDP doesn't use HTTP/2).
  - Body is assumed to fit in one read for non-WS responses (CDP JSON
    responses are kilobytes, well within limits).
  - No SSL/TLS — the cluster network is the trust boundary.
"""

import os
import socket
import sys
import threading


LISTEN_ADDR = os.environ.get("BRIDGE_LISTEN_ADDR", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("BRIDGE_LISTEN_PORT", "9222"))
TARGET_ADDR = os.environ.get("BRIDGE_TARGET_ADDR", "127.0.0.1")
TARGET_PORT = int(os.environ.get("BRIDGE_TARGET_PORT", "9223"))
INTERNAL_HOST = f"localhost:{LISTEN_PORT}"


def recv_until(sock: socket.socket, marker: bytes, max_bytes: int = 65536) -> bytes:
    """Read from sock until marker is seen or max_bytes hit. Returns everything read."""
    buf = b""
    while marker not in buf and len(buf) < max_bytes:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
    return buf


def rewrite_host(headers: bytes, new_host: str) -> tuple[bytes, str | None]:
    """Replace the Host header. Returns (new_headers, original_host)."""
    lines = headers.split(b"\r\n")
    original = None
    out = []
    for line in lines:
        if line.lower().startswith(b"host:"):
            original = line.split(b":", 1)[1].strip().decode("latin-1")
            out.append(f"Host: {new_host}".encode("latin-1"))
        else:
            out.append(line)
    return b"\r\n".join(out), original


def pipe(src: socket.socket, dst: socket.socket) -> None:
    """Raw byte pipe used after WS upgrade."""
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            src.shutdown(socket.SHUT_RD)
        except OSError:
            pass
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle(client: socket.socket) -> None:
    upstream: socket.socket | None = None
    try:
        # Read until end-of-headers.
        head_buf = recv_until(client, b"\r\n\r\n")
        if b"\r\n\r\n" not in head_buf:
            return
        head, tail = head_buf.split(b"\r\n\r\n", 1)
        new_head, original_host = rewrite_host(head, INTERNAL_HOST)

        upstream = socket.create_connection((TARGET_ADDR, TARGET_PORT), timeout=5)
        # `create_connection(timeout=5)` sets the socket's timeout to 5s,
        # which then applies to all subsequent recv() calls too. After a WS
        # upgrade either side can stay silent for minutes — leave timeouts
        # off so the pipe doesn't blow up the connection on idle.
        upstream.settimeout(None)
        upstream.sendall(new_head + b"\r\n\r\n" + tail)

        # Read response headers from upstream.
        resp_head_buf = recv_until(upstream, b"\r\n\r\n")
        if b"\r\n\r\n" not in resp_head_buf:
            return
        resp_head, resp_tail = resp_head_buf.split(b"\r\n\r\n", 1)
        first_line = resp_head.split(b"\r\n", 1)[0].decode("latin-1", errors="replace")

        # Match any 101 status (Chrome's CDP says "101 WebSocket Protocol
        # Handshake", not the canonical "101 Switching Protocols"). Sniff the
        # status code from the first line, e.g. "HTTP/1.1 101 ...".
        parts = first_line.split(" ", 2)
        status_code = parts[1] if len(parts) >= 2 else ""

        if status_code == "101":
            # WS upgrade. Forward as-is and start raw pipe.
            client.sendall(resp_head + b"\r\n\r\n" + resp_tail)
            t1 = threading.Thread(target=pipe, args=(client, upstream), daemon=True)
            t2 = threading.Thread(target=pipe, args=(upstream, client), daemon=True)
            t1.start()
            t2.start()
            t1.join()
            t2.join()
            return

        # Regular HTTP response. Determine body length (Content-Length only —
        # CDP doesn't use chunked encoding for /json/* endpoints) and rewrite.
        content_length = 0
        for line in resp_head.split(b"\r\n"):
            if line.lower().startswith(b"content-length:"):
                try:
                    content_length = int(line.split(b":", 1)[1].strip())
                except ValueError:
                    pass
                break

        body = resp_tail
        while len(body) < content_length:
            chunk = upstream.recv(65536)
            if not chunk:
                break
            body += chunk
        # Truncate any extra bytes that came past content_length (shouldn't
        # happen with stock chrome but defensive against pipelined responses).
        if content_length and len(body) > content_length:
            body = body[:content_length]

        # Rewrite the URLs Chrome composed using its localhost Host so callers
        # can follow them back through this bridge.
        if original_host:
            body = body.replace(INTERNAL_HOST.encode(), original_host.encode())

        # Rebuild response headers: drop any existing Content-Length / Connection
        # header and force `Connection: close` + the new Content-Length. This
        # keeps the bridge one-request-per-connection (no keep-alive); avoids a
        # whole class of upstream/downstream desync issues, especially because
        # Node's ws library will open a fresh TCP for the WS upgrade rather
        # than trying to reuse the HTTP probe's connection.
        new_lines = []
        for line in resp_head.split(b"\r\n"):
            l = line.lower()
            if l.startswith(b"content-length:") or l.startswith(b"connection:"):
                continue
            new_lines.append(line)
        new_lines.append(f"Content-Length: {len(body)}".encode())
        new_lines.append(b"Connection: close")
        resp_head = b"\r\n".join(new_lines)

        client.sendall(resp_head + b"\r\n\r\n" + body)
    except Exception as e:
        sys.stderr.write(f"[cdp-bridge] handle error: {e}\n")
    finally:
        try:
            client.close()
        except OSError:
            pass
        if upstream is not None:
            try:
                upstream.close()
            except OSError:
                pass


def main() -> int:
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((LISTEN_ADDR, LISTEN_PORT))
    listener.listen(64)
    sys.stderr.write(
        f"[cdp-bridge] HTTP-aware proxy listening on {LISTEN_ADDR}:{LISTEN_PORT} → "
        f"{TARGET_ADDR}:{TARGET_PORT} (rewriting Host → {INTERNAL_HOST})\n"
    )
    while True:
        client, _ = listener.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    sys.exit(main() or 0)
