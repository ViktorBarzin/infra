#!/usr/bin/env python3
"""Pure-stdlib WireGuard key generation (X25519, RFC 7748).

The broker runs on a stock python:3.12-slim (no `wg` binary, no pip — the
chrome-broker pattern), but it must mint a WireGuard keypair per gateway and per
browser so browsers can join their country gateway over WireGuard. Python's
stdlib has no X25519, so we implement the fixed RFC 7748 curve op here. Security
rests on os.urandom for the private scalar + the standard curve; correctness is
pinned by the RFC 7748 §5.2 test vector in wgkeys_test.py.
"""
import base64
import os

_P = 2 ** 255 - 19
_A24 = 121665


def _cswap(swap, a, b):
    return (b, a) if swap else (a, b)


def _x25519(scalar, u_bytes):
    """RFC 7748 X25519 scalar multiplication; scalar+u are 32 little-endian bytes."""
    k = bytearray(scalar)
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    k = int.from_bytes(k, "little")
    u = int.from_bytes(u_bytes, "little") & ((1 << 255) - 1)

    x1, x2, z2, x3, z3, swap = u, 1, 0, u, 1, 0
    for t in range(254, -1, -1):
        kt = (k >> t) & 1
        swap ^= kt
        x2, x3 = _cswap(swap, x2, x3)
        z2, z3 = _cswap(swap, z2, z3)
        swap = kt
        A = (x2 + z2) % _P
        AA = A * A % _P
        B = (x2 - z2) % _P
        BB = B * B % _P
        E = (AA - BB) % _P
        C = (x3 + z3) % _P
        D = (x3 - z3) % _P
        DA = D * A % _P
        CB = C * B % _P
        x3 = pow(DA + CB, 2, _P)
        z3 = x1 * pow(DA - CB, 2, _P) % _P
        x2 = AA * BB % _P
        z2 = E * ((AA + _A24 * E) % _P) % _P
    x2, x3 = _cswap(swap, x2, x3)
    z2, z3 = _cswap(swap, z2, z3)
    res = x2 * pow(z2, _P - 2, _P) % _P
    return res.to_bytes(32, "little")


_BASEPOINT = b"\x09" + b"\x00" * 31


def public_from_private(priv_b64):
    """Derive the base64 WireGuard public key from a base64 private key."""
    return base64.b64encode(_x25519(base64.b64decode(priv_b64), _BASEPOINT)).decode()


def genkeypair():
    """Return (private_b64, public_b64) — a fresh WireGuard keypair."""
    priv = bytearray(os.urandom(32))
    priv[0] &= 248
    priv[31] &= 127
    priv[31] |= 64
    priv_b64 = base64.b64encode(bytes(priv)).decode()
    return priv_b64, public_from_private(priv_b64)
