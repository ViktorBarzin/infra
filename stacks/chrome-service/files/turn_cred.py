#!/usr/bin/env python3
"""Mint a coturn TURN-REST credential and write neko's ICE-server JSON.

Runs as an initContainer in the chrome-service pod. neko takes its ICE servers
from env (NEKO_WEBRTC_ICESERVERS_BACKEND/_FRONTEND), and env can't be computed
at pod start, so this writes the two JSON documents to a shared emptyDir and the
neko container's command exports them before exec'ing supervisord.

The proxy stack mints the equivalent credential inside its Python broker at
browser-creation time (stacks/proxy/files/broker/broker.py `mint_turn_cred`);
the chrome-service master is a plain Deployment with no broker, hence this.
Re-minting on every pod start means there is no long-lived credential to rotate
by hand, and Reloader restarts the pod when the synced secret changes.

BACKEND = the URL neko itself uses to allocate a relay (coturn's LB IP, reached
direct in-cluster). FRONTEND = the URLs handed to the viewer's browser (coturn's
public name + STUN). coturn advertises relay candidates on its `external-ip`
either way.
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import time


def mint(secret, name, ttl, now):
    """coturn `use-auth-secret` ephemeral credential (the TURN REST API):

        username = "<unix-expiry>:<name>"
        password = base64(HMAC-SHA1(secret, username))

    Returns ("", "") when no secret is configured, which callers treat as
    "relay disabled" rather than as an error.
    """
    if not secret:
        return "", ""
    username = "%d:%s" % (int(now) + int(ttl), name)
    password = base64.b64encode(
        hmac.new(secret.encode(), username.encode(), hashlib.sha1).digest()
    ).decode()
    return username, password


def ice_servers(backend_url, frontend_url, stun_url, username, password):
    """Build (backend, frontend) ICE-server lists in neko's v3 schema.

    STUN is unconditional on the frontend: with an empty frontend list Chrome
    emits an unresolvable mDNS candidate and the peer connection never
    establishes (observed in the proxy stack).
    """
    backend = []
    frontend = [{"urls": [stun_url]}]
    if username:
        backend.append({"urls": [backend_url], "username": username, "credential": password})
        frontend.insert(0, {"urls": [frontend_url], "username": username, "credential": password})
    return backend, frontend


def write_ice_files(out_dir, secret, name, ttl, now, backend_url, frontend_url, stun_url):
    """Write backend.json + frontend.json into out_dir. Returns (backend, frontend).

    Both files are a single line: the neko container reads them with
    `export NEKO_...="$(cat …)"`, and an embedded newline would truncate the
    JSON the server parses.
    """
    username, password = mint(secret, name, ttl, now)
    backend, frontend = ice_servers(backend_url, frontend_url, stun_url, username, password)
    for fname, doc in (("backend.json", backend), ("frontend.json", frontend)):
        with open(os.path.join(out_dir, fname), "w") as fh:
            fh.write(json.dumps(doc, separators=(",", ":")))
    return backend, frontend


def main():
    out_dir = os.environ.get("ICE_DIR", "/ice")
    secret = os.environ.get("TURN_SECRET", "")
    backend, _ = write_ice_files(
        out_dir,
        secret=secret,
        name=os.environ.get("TURN_NAME", "chrome-service"),
        ttl=int(os.environ.get("TURN_TTL", str(30 * 24 * 3600))),
        now=time.time(),
        backend_url=os.environ.get("COTURN_BACKEND_URL", "turn:10.0.20.205:3478"),
        frontend_url=os.environ.get("COTURN_FRONTEND_URL", "turn:turn.viktorbarzin.me:3478"),
        stun_url=os.environ.get("COTURN_STUN_URL", "stun:turn.viktorbarzin.me:3478"),
    )
    # Log the shape, never the credential.
    if backend:
        print("turn_cred: minted relay credential, expiry=%s" % backend[0]["username"].split(":")[0])
    else:
        print("turn_cred: NO TURN_SECRET — relay disabled, STUN only", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
