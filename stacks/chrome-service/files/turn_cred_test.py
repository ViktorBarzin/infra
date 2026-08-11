#!/usr/bin/env python3
"""Unit tests for turn_cred.py (pure functions + the file-writing entrypoint).

Run: cd files && python3 -m unittest turn_cred_test
"""
import base64
import hashlib
import hmac
import json
import os
import tempfile
import unittest

import turn_cred


class MintTurnCredTest(unittest.TestCase):
    def test_username_is_expiry_colon_name(self):
        u, _ = turn_cred.mint("s3cret", "chrome-service", ttl=600, now=1000)
        self.assertEqual(u, "1600:chrome-service")

    def test_password_is_base64_hmac_sha1_of_username(self):
        secret, name, ttl, now = "s3cret", "chrome-service", 600, 1000
        u, p = turn_cred.mint(secret, name, ttl=ttl, now=now)
        # Recompute independently — this is coturn's use-auth-secret contract.
        want = base64.b64encode(
            hmac.new(secret.encode(), u.encode(), hashlib.sha1).digest()
        ).decode()
        self.assertEqual(p, want)

    def test_no_secret_yields_no_credential(self):
        self.assertEqual(turn_cred.mint("", "chrome-service", ttl=600, now=1000), ("", ""))

    def test_distinct_secrets_yield_distinct_passwords(self):
        _, a = turn_cred.mint("secret-a", "n", ttl=60, now=0)
        _, b = turn_cred.mint("secret-b", "n", ttl=60, now=0)
        self.assertNotEqual(a, b)

    def test_ttl_moves_the_expiry(self):
        u1, _ = turn_cred.mint("s", "n", ttl=60, now=0)
        u2, _ = turn_cred.mint("s", "n", ttl=120, now=0)
        self.assertEqual((u1, u2), ("60:n", "120:n"))


class IceServersTest(unittest.TestCase):
    URLS = ("turn:10.0.20.200:3478", "turn:turn.example:3478", "stun:turn.example:3478")

    def test_with_credential_backend_carries_turn_only(self):
        backend, _ = turn_cred.ice_servers(*self.URLS, username="u", password="p")
        self.assertEqual(
            backend, [{"urls": ["turn:10.0.20.200:3478"], "username": "u", "credential": "p"}]
        )

    def test_with_credential_frontend_prefers_turn_then_stun(self):
        _, frontend = turn_cred.ice_servers(*self.URLS, username="u", password="p")
        self.assertEqual(
            frontend,
            [
                {"urls": ["turn:turn.example:3478"], "username": "u", "credential": "p"},
                {"urls": ["stun:turn.example:3478"]},
            ],
        )

    def test_without_credential_backend_is_empty(self):
        backend, _ = turn_cred.ice_servers(*self.URLS, username="", password="")
        self.assertEqual(backend, [])

    def test_without_credential_frontend_still_keeps_stun(self):
        # An empty frontend makes Chrome emit an unresolvable mDNS candidate and
        # the peer connection never establishes, so STUN is unconditional.
        _, frontend = turn_cred.ice_servers(*self.URLS, username="", password="")
        self.assertEqual(frontend, [{"urls": ["stun:turn.example:3478"]}])


class WriteIceFilesTest(unittest.TestCase):
    def test_writes_two_json_files_neko_can_parse(self):
        with tempfile.TemporaryDirectory() as d:
            turn_cred.write_ice_files(
                d,
                secret="s3cret",
                name="chrome-service",
                ttl=600,
                now=1000,
                backend_url="turn:10.0.20.200:3478",
                frontend_url="turn:turn.example:3478",
                stun_url="stun:turn.example:3478",
            )
            with open(os.path.join(d, "backend.json")) as fh:
                backend = json.load(fh)
            with open(os.path.join(d, "frontend.json")) as fh:
                frontend = json.load(fh)

        self.assertEqual(backend[0]["username"], "1600:chrome-service")
        self.assertEqual(frontend[-1], {"urls": ["stun:turn.example:3478"]})

    def test_files_are_single_line_so_a_shell_export_of_them_is_valid(self):
        # The neko container does `export NEKO_..._BACKEND="$(cat backend.json)"`;
        # an embedded newline would truncate the JSON the server parses.
        with tempfile.TemporaryDirectory() as d:
            turn_cred.write_ice_files(
                d,
                secret="s3cret",
                name="n",
                ttl=60,
                now=0,
                backend_url="turn:b:3478",
                frontend_url="turn:f:3478",
                stun_url="stun:f:3478",
            )
            for fname in ("backend.json", "frontend.json"):
                with open(os.path.join(d, fname)) as fh:
                    body = fh.read()
                self.assertNotIn("\n", body, "%s must be one line" % fname)


if __name__ == "__main__":
    unittest.main()
