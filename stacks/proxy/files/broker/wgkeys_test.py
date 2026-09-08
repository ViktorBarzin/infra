#!/usr/bin/env python3
"""Tests for wgkeys.py — correctness pinned to the RFC 7748 X25519 test vector.

    python3 -m unittest wgkeys_test -v
"""
import base64
import binascii
import unittest

import wgkeys


class X25519RFCVector(unittest.TestCase):
    def test_rfc7748_section_5_2_vector(self):
        # RFC 7748 §5.2, first test vector.
        scalar = binascii.unhexlify(
            "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4")
        u = binascii.unhexlify(
            "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")
        expect = "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"
        got = binascii.hexlify(wgkeys._x25519(scalar, u)).decode()
        self.assertEqual(got, expect)


class Keypair(unittest.TestCase):
    def test_public_is_deterministic_from_private(self):
        priv, pub = wgkeys.genkeypair()
        self.assertEqual(wgkeys.public_from_private(priv), pub)

    def test_keys_are_32_byte_base64(self):
        priv, pub = wgkeys.genkeypair()
        self.assertEqual(len(base64.b64decode(priv)), 32)
        self.assertEqual(len(base64.b64decode(pub)), 32)

    def test_distinct_keypairs(self):
        a, _ = wgkeys.genkeypair()
        b, _ = wgkeys.genkeypair()
        self.assertNotEqual(a, b)

    def test_private_is_clamped(self):
        priv, _ = wgkeys.genkeypair()
        raw = bytearray(base64.b64decode(priv))
        self.assertEqual(raw[0] & 7, 0)          # low 3 bits clear
        self.assertEqual(raw[31] & 128, 0)       # high bit clear
        self.assertEqual(raw[31] & 64, 64)       # bit 254 set


if __name__ == "__main__":
    unittest.main()
