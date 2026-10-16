"""Unit tests for gate.py. Run: python3 -m unittest discover -s stacks/turnstile-gate/files"""

import ipaddress
import json
import socket
import unittest
import urllib.error

import gate

DOMAIN = "viktorbarzin.me"
SITE = "blog.viktorbarzin.me"
NOW = 1_800_000_000.0
HTML = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
CHROME = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36"
GOOGLEBOT = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
UNTRUSTED = "203.0.113.7"


def make_config(**over: object) -> gate.Config:
    base = dict(
        sitekey="0x4AAAAsitekey",
        secret="widget-secret",
        cookie_key=b"k" * 32,
        domain=DOMAIN,
        challenge_origin="https://challenge.viktorbarzin.me",
        action="site-gate",
        mode=gate.MODE_ON,
        trusted=[ipaddress.ip_network(c) for c in gate.DEFAULT_TRUSTED_CIDRS],
    )
    base.update(over)
    return gate.Config(**base)  # type: ignore[arg-type]


CFG = make_config()


def req(**over: object) -> gate.Request:
    base: dict = dict(method="GET", real_ip=UNTRUSTED, accept=HTML, ua=CHROME, cookie="",
                      uri="/posts/hello", host=SITE, strict=False)
    base.update(over)
    return gate.Request(**base)


def signed(kind: str = gate.KIND_PASS, name: str = gate.PASS_COOKIE, cfg: gate.Config = CFG, now: float = NOW) -> str:
    value = gate.sign(cfg, {"id": "abc123", "k": kind, "exp": int(now) + 3600})
    return f"other=1; {name}={value}"


PASS = signed()
FALLBACK = signed(kind=gate.KIND_FALLBACK, name=gate.FALLBACK_COOKIE)


class DecideCase(unittest.TestCase):
    def assertSkip(self, d: gate.Decision, reason: str) -> None:
        """200 with the header: no Anubis, straight to the site."""
        self.assertEqual((d.status, d.reason, d.headers.get(gate.PASS_HEADER)), (200, reason, "1"))

    def assertAnubis(self, d: gate.Decision, reason: str) -> None:
        """200 without the header: the visitor gets Anubis."""
        self.assertEqual(d.status, 200)
        self.assertEqual(d.reason, reason)
        self.assertNotIn(gate.PASS_HEADER, d.headers)

    def assertChallenge(self, d: gate.Decision) -> None:
        self.assertEqual((d.status, d.reason), (403, "challenge"))
        self.assertNotIn(gate.PASS_HEADER, d.headers)


class StandardVariantTest(DecideCase):
    """Sites with no Anubis of their own: only HTML pages for browsers are checked."""

    def test_untrusted_browser_html_gets_the_challenge(self) -> None:
        self.assertChallenge(gate.decide(CFG, req(), NOW))

    def test_head_is_treated_like_get(self) -> None:
        self.assertChallenge(gate.decide(CFG, req(method="HEAD"), NOW))

    def test_pass_cookie_skips_anubis_on_every_request(self) -> None:
        for accept in (HTML, "text/css,*/*;q=0.1", "*/*"):
            d = gate.decide(CFG, req(accept=accept, cookie=PASS), NOW)
            self.assertSkip(d, "pass")
            self.assertEqual(d.cookie_id, "abc123")

    def test_writes_trusted_and_missing_ip_skip(self) -> None:
        for m in ("POST", "PUT", "PATCH", "DELETE", "OPTIONS"):
            self.assertSkip(gate.decide(CFG, req(method=m), NOW), "method")
        for ip in ("10.0.10.10", "192.168.1.5", "172.16.0.9", "100.64.1.2", "fd00::1", "fe80::1"):
            self.assertSkip(gate.decide(CFG, req(real_ip=ip), NOW), "trusted")
        for ip in ("", "not-an-ip"):
            self.assertSkip(gate.decide(CFG, req(real_ip=ip), NOW), "no-ip")

    def test_public_ipv6_is_not_trusted(self) -> None:
        self.assertChallenge(gate.decide(CFG, req(real_ip="2a00:23c6::1"), NOW))

    def test_non_browser_clients_skip(self) -> None:
        # Phone apps, git, curl, feed readers: these sites have no check today.
        for ua in ("git/2.43.0", "curl/8.5.0", "okhttp/4.12.0", "Immich_Android_1.120", ""):
            self.assertSkip(gate.decide(CFG, req(ua=ua), NOW), "not-browser")

    def test_non_html_requests_from_browsers_skip(self) -> None:
        for accept in ("text/css,*/*;q=0.1", "image/avif,image/webp,*/*", "*/*", "application/json", ""):
            self.assertSkip(gate.decide(CFG, req(accept=accept), NOW), "not-html")

    def test_browser_ua_declaring_a_bot_goes_to_anubis(self) -> None:
        # Anubis lets IP-verified search engines through and challenges the rest.
        for ua in (GOOGLEBOT, "Mozilla/5.0 (compatible; bingbot/2.0)", "Mozilla/5.0 (compatible; Discordbot/2.0)"):
            self.assertAnubis(gate.decide(CFG, req(ua=ua), NOW), "declared-bot")

    def test_fallback_cookie_goes_to_anubis_and_never_passes(self) -> None:
        self.assertAnubis(gate.decide(CFG, req(cookie=FALLBACK), NOW), "fallback")

    def test_bad_pass_cookies_do_not_pass(self) -> None:
        good = PASS.split(gate.PASS_COOKIE + "=", 1)[1]
        body, mac = good.rsplit(".", 1)
        for c in (f"{gate.PASS_COOKIE}={body}.{'0' * len(mac)}", f"{gate.PASS_COOKIE}={body[:-2]}xx.{mac}",
                  f"{gate.PASS_COOKIE}=garbage", signed(now=NOW - 7200),
                  signed(cfg=make_config(cookie_key=b"x" * 32)),
                  signed(kind=gate.KIND_FALLBACK, name=gate.PASS_COOKIE)):
            self.assertChallenge(gate.decide(CFG, req(cookie=c), NOW))


class StrictVariantTest(DecideCase):
    """The Anubis sites: only a Turnstile pass skips Anubis, as in the canary."""

    def strict(self, **over: object) -> gate.Decision:
        return gate.decide(CFG, req(strict=True, **over), NOW)

    def test_challenge_and_pass(self) -> None:
        self.assertChallenge(self.strict())
        self.assertSkip(self.strict(accept="*/*", cookie=PASS), "pass")

    def test_everything_else_goes_to_anubis(self) -> None:
        cases = {
            "method": dict(method="POST"),
            "trusted": dict(real_ip="10.0.10.10"),
            "no-ip": dict(real_ip=""),
            "not-browser": dict(ua="curl/8.5.0"),
            "declared-bot": dict(ua=GOOGLEBOT),
            "not-html": dict(accept="*/*"),
            "fallback": dict(cookie=FALLBACK),
        }
        for reason, over in cases.items():
            self.assertAnubis(self.strict(**over), reason)


class ModeTest(DecideCase):
    def test_open_mode_never_challenges(self) -> None:
        cfg = make_config(mode=gate.MODE_OPEN)
        self.assertSkip(gate.decide(cfg, req(), NOW), "mode-open")
        # Strict sites keep their own Anubis, exactly as before the canary.
        self.assertAnubis(gate.decide(cfg, req(strict=True), NOW), "mode-open")

    def test_anubis_mode_sends_browsers_to_anubis(self) -> None:
        cfg = make_config(mode=gate.MODE_ANUBIS)
        self.assertAnubis(gate.decide(cfg, req(), NOW), "mode-anubis")
        self.assertAnubis(gate.decide(cfg, req(strict=True), NOW), "mode-anubis")
        # Requests that skip in "on" mode still skip.
        self.assertSkip(gate.decide(cfg, req(accept="*/*"), NOW), "not-html")

    def test_pass_still_honoured_in_every_mode(self) -> None:
        for mode in gate.MODES:
            d = gate.decide(make_config(mode=mode), req(cookie=PASS), NOW)
            self.assertEqual(d.headers.get(gate.PASS_HEADER), "1", mode)

    def test_parse_mode(self) -> None:
        self.assertEqual(gate.parse_mode("anubis"), gate.MODE_ANUBIS)
        self.assertEqual(gate.parse_mode("bogus"), gate.MODE_ON)


class ChallengePageTest(unittest.TestCase):
    def test_page_posts_to_the_challenge_host(self) -> None:
        d = gate.decide(CFG, req(), NOW)
        self.assertIn("0x4AAAAsitekey", d.body)
        self.assertIn('"site-gate"', d.body)
        self.assertIn('"https://challenge.viktorbarzin.me"', d.body)
        self.assertIn('credentials: "include"', d.body)
        self.assertEqual(d.headers.get("Cache-Control"), "no-store")
        self.assertTrue(d.headers.get("Content-Type", "").startswith("text/html"))


class HostTest(unittest.TestCase):
    def test_host_allowed(self) -> None:
        for h in ("viktorbarzin.me", "blog.viktorbarzin.me", "a.b.viktorbarzin.me", "BLOG.viktorbarzin.me"):
            self.assertTrue(gate.host_allowed(CFG, h), h)
        for h in ("evilviktorbarzin.me", "viktorbarzin.me.evil.com", "", "example.com"):
            self.assertFalse(gate.host_allowed(CFG, h), h)

    def test_cors_only_for_https_origins_in_the_domain(self) -> None:
        h = gate.cors_headers(CFG, "https://blog.viktorbarzin.me")
        self.assertEqual(h["Access-Control-Allow-Origin"], "https://blog.viktorbarzin.me")
        self.assertEqual(h["Access-Control-Allow-Credentials"], "true")
        self.assertEqual(h["Vary"], "Origin")
        for origin in ("http://blog.viktorbarzin.me", "https://evil.com", "https://blog.viktorbarzin.me.evil.com",
                       "https://blog.viktorbarzin.me:8443", "null", ""):
            self.assertEqual(gate.cors_headers(CFG, origin), {}, origin)


class CookieTest(unittest.TestCase):
    def test_round_trip_and_expiry(self) -> None:
        v = gate.sign(CFG, {"id": "x", "k": gate.KIND_PASS, "exp": int(NOW) + 10})
        self.assertEqual(gate.unsign(CFG, v, NOW)["id"], "x")  # type: ignore[index]
        self.assertIsNone(gate.unsign(CFG, v, NOW + 11))

    def test_cookie_covers_the_whole_domain(self) -> None:
        h = gate.set_cookie(CFG, gate.PASS_COOKIE, "v", 100)
        for attr in ("Path=/", "Max-Age=100", "Domain=viktorbarzin.me", "Secure", "HttpOnly", "SameSite=Lax"):
            self.assertIn(attr, h)

    def test_fallback_cookie_cannot_act_as_a_pass(self) -> None:
        h = gate.fallback_cookie(CFG, NOW)
        self.assertTrue(h.startswith(gate.FALLBACK_COOKIE + "="))
        self.assertIn("Max-Age=3600", h)
        value = h.split("=", 1)[1].split(";", 1)[0]
        d = gate.decide(CFG, req(cookie=f"{gate.PASS_COOKIE}={value}"), NOW)
        self.assertNotIn(gate.PASS_HEADER, d.headers)


class FakeSiteverify:
    def __init__(self, result: "dict | Exception") -> None:
        self.result = result
        self.calls: "list[dict]" = []

    def __call__(self, fields: dict, timeout: float) -> dict:
        self.calls.append(fields)
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


OK = {"success": True, "hostname": SITE, "action": "site-gate", "error-codes": []}


class VerifyTest(unittest.TestCase):
    def verify(self, token: str, sv: FakeSiteverify, cache: "gate.TokenCache | None" = None) -> gate.VerifyResult:
        return gate.verify(CFG, token, UNTRUSTED, NOW, sv, cache or gate.TokenCache())

    def test_success_sets_a_domain_pass_cookie(self) -> None:
        sv = FakeSiteverify(dict(OK))
        r = self.verify("tok-1", sv)
        self.assertTrue(r.admitted)
        self.assertEqual(r.event, "verify_ok")
        self.assertIn("Domain=viktorbarzin.me", r.set_cookie)
        self.assertEqual((sv.calls[0]["secret"], sv.calls[0]["response"], sv.calls[0]["remoteip"]),
                         ("widget-secret", "tok-1", UNTRUSTED))
        value = r.set_cookie.split("=", 1)[1].split(";", 1)[0]
        self.assertEqual(gate.unsign(CFG, value, NOW)["k"], gate.KIND_PASS)  # type: ignore[index]

    def test_any_site_in_the_domain_is_accepted(self) -> None:
        for host in ("forgejo.viktorbarzin.me", "viktorbarzin.me", "cc.viktorbarzin.me"):
            self.assertTrue(self.verify("tok-" + host, FakeSiteverify(dict(OK, hostname=host))).admitted, host)

    def test_rejections(self) -> None:
        cases = {
            "success-false": {"success": False, "error-codes": ["invalid-input-response"]},
            "foreign-hostname": dict(OK, hostname="evil.example"),
            "lookalike-hostname": dict(OK, hostname="evilviktorbarzin.me"),
            "wrong-action": dict(OK, action="other"),
        }
        for name, result in cases.items():
            r = self.verify("tok-" + name, FakeSiteverify(result))
            self.assertEqual((r.admitted, r.set_cookie, r.event), (False, "", "verify_fail"), name)

    def test_empty_or_huge_token_never_calls_siteverify(self) -> None:
        for token in ("", "x" * 5000):
            sv = FakeSiteverify(dict(OK))
            self.assertFalse(self.verify(token, sv).admitted)
            self.assertEqual(sv.calls, [])

    def test_reused_token_is_rejected(self) -> None:
        sv, cache = FakeSiteverify(dict(OK)), gate.TokenCache()
        self.assertTrue(self.verify("tok-reuse", sv, cache).admitted)
        r = self.verify("tok-reuse", sv, cache)
        self.assertEqual((r.admitted, r.event, len(sv.calls)), (False, "verify_reuse", 1))

    def test_token_cache_forgets_after_lifetime(self) -> None:
        c = gate.TokenCache(ttl=300)
        self.assertTrue(c.first_use("a", NOW))
        self.assertFalse(c.first_use("a", NOW + 299))
        self.assertTrue(c.first_use("a", NOW + 301))

    def test_siteverify_unavailable_admits(self) -> None:
        for exc in (socket.timeout("timed out"), urllib.error.URLError("down"),
                    urllib.error.HTTPError(gate.SITEVERIFY, 503, "unavailable", {}, None)):  # type: ignore[arg-type]
            r = self.verify("tok-x", FakeSiteverify(exc))
            self.assertEqual((r.admitted, r.event), (True, "verify_unavailable_admit"), repr(exc))

    def test_siteverify_4xx_is_a_rejection(self) -> None:
        r = self.verify("tok-y", FakeSiteverify(urllib.error.HTTPError(gate.SITEVERIFY, 400, "bad", {}, None)))  # type: ignore[arg-type]
        self.assertFalse(r.admitted)


class ParseTest(unittest.TestCase):
    def test_cookie_parsing(self) -> None:
        self.assertEqual(gate.parse_cookies("a=1; b=two=2;c"), {"a": "1", "b": "two=2"})

    def test_first_valid_duplicate_cookie_wins(self) -> None:
        # A host-only canary cookie and the new domain cookie can both be sent.
        value = PASS.split(gate.PASS_COOKIE + "=", 1)[1]
        for cookies in (f"{gate.PASS_COOKIE}=garbage; {gate.PASS_COOKIE}={value}",
                        f"{gate.PASS_COOKIE}={value}; {gate.PASS_COOKIE}=garbage"):
            d = gate.decide(CFG, req(cookie=cookies), NOW)
            self.assertEqual(d.headers.get(gate.PASS_HEADER), "1", cookies)

    def test_wants_html(self) -> None:
        self.assertTrue(gate.wants_html(HTML))
        self.assertTrue(gate.wants_html("TEXT/HTML"))
        self.assertFalse(gate.wants_html("text/html;q=0"))
        self.assertFalse(gate.wants_html("*/*"))

    def test_trusted_cidrs_from_env_string(self) -> None:
        self.assertEqual([str(n) for n in gate.parse_cidrs("10.0.0.0/8, fc00::/7")], ["10.0.0.0/8", "fc00::/7"])

    def test_log_line_is_json(self) -> None:
        self.assertEqual(json.loads(gate.format_event({"event": "x"}, NOW))["event"], "x")


if __name__ == "__main__":
    unittest.main()
