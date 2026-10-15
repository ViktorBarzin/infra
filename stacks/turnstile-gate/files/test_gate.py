"""Unit tests for gate.py. Run: python3 -m unittest discover -s stacks/turnstile-gate/files"""

import ipaddress
import json
import socket
import unittest
import urllib.error

import gate

HOST = "forgejo.viktorbarzin.me"
NOW = 1_800_000_000.0
HTML = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
CHROME = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36"


def make_config(**over: object) -> gate.Config:
    base = dict(
        sitekey="0x4AAAAsitekey",
        secret="widget-secret",
        cookie_key=b"k" * 32,
        arm_salt="test-salt",
        host=HOST,
        action="forgejo-gate",
        trusted=[ipaddress.ip_network(c) for c in gate.DEFAULT_TRUSTED_CIDRS],
    )
    base.update(over)
    return gate.Config(**base)  # type: ignore[arg-type]


CFG = make_config()


def ip_in_arm(cfg: gate.Config, arm: str) -> str:
    for i in range(1, 255):
        ip = f"203.0.113.{i}"
        if gate.arm_for(cfg, ip) == arm:
            return ip
    raise AssertionError("no ip found for arm " + arm)


TS_IP = ip_in_arm(CFG, gate.ARM_TURNSTILE)
AN_IP = ip_in_arm(CFG, gate.ARM_ANUBIS)


def req(**over: str) -> gate.Request:
    base = dict(method="GET", real_ip=TS_IP, accept=HTML, ua=CHROME, cookie="", uri="/viktor/infra/commits/branch/master")
    base.update(over)
    return gate.Request(**base)


def pass_cookie(cfg: gate.Config = CFG, now: float = NOW, kind: str = gate.KIND_PASS, name: str = gate.PASS_COOKIE) -> str:
    value = gate.sign(cfg, {"id": "abc123", "k": kind, "exp": int(now) + 3600})
    return f"other=1; {name}={value}"


class DecideTest(unittest.TestCase):
    def assertOpen(self, d: gate.Decision, reason: str) -> None:
        self.assertEqual(d.status, 200)
        self.assertNotIn(gate.PASS_HEADER, d.headers)
        self.assertEqual(d.reason, reason)

    def test_non_get_methods_are_not_challenged(self) -> None:
        for m in ("POST", "PUT", "PATCH", "DELETE", "OPTIONS"):
            self.assertOpen(gate.decide(CFG, req(method=m), NOW), "method")

    def test_head_is_treated_like_get(self) -> None:
        self.assertEqual(gate.decide(CFG, req(method="HEAD"), NOW).status, 403)

    def test_trusted_networks_skip_the_gate(self) -> None:
        for ip in ("10.0.10.10", "10.10.3.4", "192.168.1.5", "172.16.0.9", "100.64.1.2", "fd00::1", "fe80::1"):
            self.assertOpen(gate.decide(CFG, req(real_ip=ip), NOW), "trusted")

    def test_public_ipv6_is_not_trusted(self) -> None:
        d = gate.decide(CFG, req(real_ip="2a00:23c6::1"), NOW)
        self.assertIn(d.reason, ("arm-anubis", "challenge"))

    def test_missing_or_garbage_ip_fails_open(self) -> None:
        self.assertOpen(gate.decide(CFG, req(real_ip=""), NOW), "no-ip")
        self.assertOpen(gate.decide(CFG, req(real_ip="not-an-ip"), NOW), "no-ip")

    def test_non_html_requests_are_not_challenged(self) -> None:
        for accept in ("text/css,*/*;q=0.1", "image/avif,image/webp,*/*", "*/*", "application/json", ""):
            self.assertOpen(gate.decide(CFG, req(accept=accept), NOW), "not-html")

    def test_declared_bots_are_left_to_anubis(self) -> None:
        for ua in ("Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
                   "Mozilla/5.0 (compatible; bingbot/2.0)", "git/2.43.0", "curl/8.5.0", ""):
            self.assertOpen(gate.decide(CFG, req(ua=ua), NOW), "not-browser")

    def test_valid_pass_cookie_sets_header_even_on_assets(self) -> None:
        # Assets must carry the header too, or Anubis challenges a passed
        # visitor's CSS and JS and the page renders broken.
        for accept in (HTML, "text/css,*/*;q=0.1", "*/*"):
            d = gate.decide(CFG, req(accept=accept, cookie=pass_cookie()), NOW)
            self.assertEqual(d.status, 200)
            self.assertEqual(d.headers.get(gate.PASS_HEADER), "1")
            self.assertEqual(d.reason, "pass")
            self.assertEqual(d.cookie_id, "abc123")

    def test_pass_cookie_works_in_either_arm(self) -> None:
        d = gate.decide(CFG, req(real_ip=AN_IP, cookie=pass_cookie()), NOW)
        self.assertEqual(d.headers.get(gate.PASS_HEADER), "1")

    def test_tampered_expired_and_foreign_cookies_do_not_pass(self) -> None:
        good = pass_cookie().split(gate.PASS_COOKIE + "=", 1)[1]
        body, mac = good.rsplit(".", 1)
        bad = [
            f"{gate.PASS_COOKIE}={body}.{'0' * len(mac)}",
            f"{gate.PASS_COOKIE}={body[:-2]}xx.{mac}",
            f"{gate.PASS_COOKIE}=garbage",
            pass_cookie(now=NOW - 7200),
            pass_cookie(cfg=make_config(cookie_key=b"x" * 32)),
            # a fallback cookie's payload moved into the pass cookie name
            pass_cookie(kind=gate.KIND_FALLBACK, name=gate.PASS_COOKIE),
        ]
        for c in bad:
            d = gate.decide(CFG, req(cookie=c), NOW)
            self.assertNotIn(gate.PASS_HEADER, d.headers, c)
            self.assertEqual(d.status, 403, c)

    def test_fallback_cookie_drops_to_anubis_and_never_passes(self) -> None:
        c = pass_cookie(kind=gate.KIND_FALLBACK, name=gate.FALLBACK_COOKIE)
        self.assertOpen(gate.decide(CFG, req(cookie=c), NOW), "fallback")

    def test_anubis_arm_is_left_alone(self) -> None:
        self.assertOpen(gate.decide(CFG, req(real_ip=AN_IP), NOW), "arm-anubis")

    def test_turnstile_arm_gets_the_challenge_page(self) -> None:
        d = gate.decide(CFG, req(), NOW)
        self.assertEqual(d.status, 403)
        self.assertEqual(d.reason, "challenge")
        self.assertIn("0x4AAAAsitekey", d.body)
        self.assertIn('"forgejo-gate"', d.body)
        self.assertIn("/_gate/verify", d.body)
        self.assertIn("/_gate/fallback", d.body)
        self.assertEqual(d.headers.get("Cache-Control"), "no-store")
        self.assertTrue(d.headers.get("Content-Type", "").startswith("text/html"))


class ArmTest(unittest.TestCase):
    def test_deterministic(self) -> None:
        self.assertEqual(gate.arm_for(CFG, "198.51.100.7"), gate.arm_for(CFG, "198.51.100.7"))

    def test_roughly_even_split(self) -> None:
        arms = [gate.arm_for(CFG, f"198.51.{i // 256}.{i % 256}") for i in range(2000)]
        share = arms.count(gate.ARM_TURNSTILE) / len(arms)
        self.assertGreater(share, 0.45)
        self.assertLess(share, 0.55)

    def test_salt_changes_assignment(self) -> None:
        other = make_config(arm_salt="another")
        ips = [f"198.51.100.{i}" for i in range(1, 60)]
        self.assertNotEqual([gate.arm_for(CFG, i) for i in ips], [gate.arm_for(other, i) for i in ips])

    def test_ipv6_privacy_addresses_in_one_64_share_an_arm(self) -> None:
        arms = {gate.arm_for(CFG, f"2a00:23c6:1234:5678::{i:x}") for i in range(1, 50)}
        self.assertEqual(len(arms), 1)


class CookieTest(unittest.TestCase):
    def test_round_trip(self) -> None:
        v = gate.sign(CFG, {"id": "x", "k": gate.KIND_PASS, "exp": int(NOW) + 10})
        self.assertEqual(gate.unsign(CFG, v, NOW)["id"], "x")  # type: ignore[index]

    def test_expired(self) -> None:
        v = gate.sign(CFG, {"id": "x", "k": gate.KIND_PASS, "exp": int(NOW) - 1})
        self.assertIsNone(gate.unsign(CFG, v, NOW))

    def test_set_cookie_attributes(self) -> None:
        h = gate.set_cookie(gate.PASS_COOKIE, "v", 100)
        for attr in ("Path=/", "Max-Age=100", "Secure", "HttpOnly", "SameSite=Lax"):
            self.assertIn(attr, h)
        self.assertNotIn("Domain=", h)  # host-only


class FakeSiteverify:
    def __init__(self, result: "dict | Exception") -> None:
        self.result = result
        self.calls: "list[dict]" = []

    def __call__(self, fields: dict, timeout: float) -> dict:
        self.calls.append(fields)
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


OK = {"success": True, "hostname": HOST, "action": "forgejo-gate", "error-codes": []}


class VerifyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.seen = gate.TokenCache()

    def verify(self, token: str, sv: FakeSiteverify) -> gate.VerifyResult:
        return gate.verify(CFG, token, TS_IP, NOW, sv, self.seen)

    def test_success_sets_pass_cookie(self) -> None:
        sv = FakeSiteverify(dict(OK))
        r = self.verify("tok-1", sv)
        self.assertTrue(r.admitted)
        self.assertEqual(r.event, "verify_ok")
        self.assertIn(gate.PASS_COOKIE + "=", r.set_cookie)
        self.assertEqual(sv.calls[0]["secret"], "widget-secret")
        self.assertEqual(sv.calls[0]["response"], "tok-1")
        self.assertEqual(sv.calls[0]["remoteip"], TS_IP)
        value = r.set_cookie.split("=", 1)[1].split(";", 1)[0]
        payload = gate.unsign(CFG, value, NOW)
        self.assertEqual(payload["k"], gate.KIND_PASS)  # type: ignore[index]

    def test_rejections(self) -> None:
        cases = {
            "success-false": {"success": False, "error-codes": ["invalid-input-response"]},
            "wrong-hostname": dict(OK, hostname="evil.example"),
            "wrong-action": dict(OK, action="other"),
        }
        for name, result in cases.items():
            r = gate.verify(CFG, "tok-" + name, TS_IP, NOW, FakeSiteverify(result), gate.TokenCache())
            self.assertFalse(r.admitted, name)
            self.assertEqual(r.set_cookie, "", name)
            self.assertEqual(r.event, "verify_fail", name)

    def test_empty_or_huge_token_never_calls_siteverify(self) -> None:
        for token in ("", "x" * 5000):
            sv = FakeSiteverify(dict(OK))
            r = self.verify(token, sv)
            self.assertFalse(r.admitted)
            self.assertEqual(sv.calls, [])

    def test_reused_token_is_rejected(self) -> None:
        sv = FakeSiteverify(dict(OK))
        self.assertTrue(self.verify("tok-reuse", sv).admitted)
        r = self.verify("tok-reuse", sv)
        self.assertFalse(r.admitted)
        self.assertEqual(r.event, "verify_reuse")
        self.assertEqual(len(sv.calls), 1)

    def test_token_cache_forgets_after_lifetime(self) -> None:
        c = gate.TokenCache(ttl=300)
        self.assertTrue(c.first_use("a", NOW))
        self.assertFalse(c.first_use("a", NOW + 299))
        self.assertTrue(c.first_use("a", NOW + 301))

    def test_siteverify_unavailable_admits(self) -> None:
        for exc in (socket.timeout("timed out"), urllib.error.URLError("down"),
                    urllib.error.HTTPError(gate.SITEVERIFY, 503, "unavailable", {}, None)):  # type: ignore[arg-type]
            r = gate.verify(CFG, "tok-x", TS_IP, NOW, FakeSiteverify(exc), gate.TokenCache())
            self.assertTrue(r.admitted, repr(exc))
            self.assertEqual(r.event, "verify_unavailable_admit")
            self.assertIn(gate.PASS_COOKIE + "=", r.set_cookie)

    def test_siteverify_4xx_is_a_rejection(self) -> None:
        r = self.verify("tok-y", FakeSiteverify(urllib.error.HTTPError(gate.SITEVERIFY, 400, "bad", {}, None)))  # type: ignore[arg-type]
        self.assertFalse(r.admitted)


class FallbackTest(unittest.TestCase):
    def test_sets_short_fallback_cookie_only(self) -> None:
        h = gate.fallback_cookie(CFG, NOW)
        self.assertTrue(h.startswith(gate.FALLBACK_COOKIE + "="))
        self.assertIn("Max-Age=3600", h)
        value = h.split("=", 1)[1].split(";", 1)[0]
        payload = gate.unsign(CFG, value, NOW)
        self.assertEqual(payload["k"], gate.KIND_FALLBACK)  # type: ignore[index]
        # and that value cannot act as a pass cookie
        d = gate.decide(CFG, req(cookie=f"{gate.PASS_COOKIE}={value}"), NOW)
        self.assertNotIn(gate.PASS_HEADER, d.headers)


class ParseTest(unittest.TestCase):
    def test_cookie_parsing(self) -> None:
        self.assertEqual(gate.parse_cookies("a=1; b=two=2;c"), {"a": "1", "b": "two=2"})

    def test_wants_html(self) -> None:
        self.assertTrue(gate.wants_html(HTML))
        self.assertTrue(gate.wants_html("TEXT/HTML"))
        self.assertFalse(gate.wants_html("text/html;q=0"))
        self.assertFalse(gate.wants_html("*/*"))

    def test_trusted_cidrs_from_env_string(self) -> None:
        nets = gate.parse_cidrs("10.0.0.0/8, fc00::/7")
        self.assertEqual([str(n) for n in nets], ["10.0.0.0/8", "fc00::/7"])

    def test_log_line_is_json(self) -> None:
        line = gate.format_event({"event": "x", "ip": "1.2.3.4"}, NOW)
        self.assertEqual(json.loads(line)["event"], "x")


if __name__ == "__main__":
    unittest.main()
