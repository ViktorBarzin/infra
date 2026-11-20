"""Tests for the settings page. Run: python3 -m unittest"""

import os
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request

import page
import subs

URL = "https://notify.example"
CATALOG = [
    {"name": "R730 Host", "alerts": [
        {"name": "HighCPUTemperature", "summary": "CPU <hot>", "severity": "warning"},
        {"name": "SSDHighWriteRate", "summary": "", "severity": ""},
    ]},
    {"name": "Storage", "alerts": [{"name": "PVFillingUp", "summary": "PV filling", "severity": "warning"}]},
]


class StubRules:
    def catalog(self):
        return CATALOG

    def groups_of(self, name):
        return [g["name"] for g in CATALOG for a in g["alerts"] if a["name"] == name]


class StubDirectory:
    def __init__(self):
        self.users = {
            "me@example.com": {
                "pk": 7,
                "username": "me@example.com",
                "email": "me@example.com",
                "attributes": {"notify": {
                    "push_instance": "ha-london",
                    "push_service": "mobile_app_my_phone",
                    "groups": {"R730 Host": "push"},
                    "alerts": {"SSDHighWriteRate": "off", "DevvmJournalSilent": "email"},
                }},
            }
        }
        self.saved = []
        self.down = False

    def user(self, username):
        if self.down:
            raise subs.Unavailable("down")
        return self.users.get(username)

    def save(self, user, notify):
        self.saved.append((user["pk"], notify))


class PageTest(unittest.TestCase):
    def setUp(self):
        fd, self.proof_file = tempfile.mkstemp()
        os.write(fd, b"proof123\n")
        os.close(fd)
        self.directory = StubDirectory()
        self.server = page.make_server(("127.0.0.1", 0), self.directory, StubRules(), self.proof_file, URL)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = "http://127.0.0.1:%d" % self.server.server_port

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        os.unlink(self.proof_file)

    def request(self, path, data=None, proof="proof123", user="me@example.com", origin=URL):
        headers = {}
        if proof:
            headers["X-Notify-Ingress-Proof"] = proof
        if user:
            headers["X-authentik-username"] = user
        if origin:
            headers["Origin"] = origin
        body = urllib.parse.urlencode(data).encode() if data is not None else None
        req = urllib.request.Request(self.base + path, body, headers)

        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args):
                return None

        try:
            resp = urllib.request.build_opener(NoRedirect).open(req)
            return resp.status, resp.read().decode(), resp.headers
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode(), e.headers

    def test_without_ingress_proof_is_refused(self):
        self.assertEqual(self.request("/", proof=None)[0], 403)
        self.assertEqual(self.request("/", proof="guess")[0], 403)

    def test_without_identity_is_refused(self):
        self.assertEqual(self.request("/", user=None)[0], 403)

    def test_unknown_account_is_refused(self):
        self.assertEqual(self.request("/", user="stranger@example.com")[0], 403)

    def test_full_page_lists_groups_and_current_choices(self):
        status, html, _ = self.request("/")
        self.assertEqual(status, 200)
        self.assertIn("R730 Host", html)
        self.assertIn("CPU &lt;hot&gt;", html)
        self.assertNotIn("CPU <hot>", html)
        self.assertIn('name="g:R730 Host" value="push" checked', html)
        self.assertIn('name="a:SSDHighWriteRate" value="off" checked', html)
        self.assertIn('name="a:HighCPUTemperature" value="inherit" checked', html)
        self.assertIn('value="mobile_app_my_phone"', html)
        self.assertIn('placeholder="me@example.com"', html)

    def test_full_page_lists_chosen_alerts_outside_any_group(self):
        _, html, _ = self.request("/")
        self.assertIn('name="a:DevvmJournalSilent" value="email" checked', html)

    def test_alert_page_offers_the_alert_and_its_group(self):
        status, html, _ = self.request("/a/HighCPUTemperature")
        self.assertEqual(status, 200)
        self.assertIn('name="a:HighCPUTemperature" value="push" checked', html)
        self.assertIn('name="g:R730 Host" value="push" checked', html)
        self.assertIn('name="next" value="/a/HighCPUTemperature"', html)

    def test_alert_page_for_an_alert_outside_any_group(self):
        status, html, _ = self.request("/a/SomeLokiAlert")
        self.assertEqual(status, 200)
        self.assertIn('name="a:SomeLokiAlert" value="off" checked', html)
        self.assertNotIn('name="g:', html)

    def test_alert_page_refuses_a_bad_name(self):
        self.assertEqual(self.request("/a/%3Cscript%3E")[0], 404)

    def test_save_writes_and_redirects(self):
        status, _, headers = self.request("/save", {"a:PVFillingUp": "push", "next": "/a/PVFillingUp"})
        self.assertEqual(status, 303)
        self.assertEqual(headers["Location"], "/a/PVFillingUp?saved=1")
        pk, notify = self.directory.saved[0]
        self.assertEqual(pk, 7)
        self.assertEqual(notify["alerts"], {"SSDHighWriteRate": "off", "DevvmJournalSilent": "email", "PVFillingUp": "push"})

    def test_save_from_another_site_is_refused(self):
        self.assertEqual(self.request("/save", {"a:PVFillingUp": "push"}, origin="https://evil.example")[0], 403)
        self.assertEqual(self.request("/save", {"a:PVFillingUp": "push"}, origin=None)[0], 403)
        self.assertEqual(self.directory.saved, [])

    def test_save_never_redirects_off_site(self):
        _, _, headers = self.request("/save", {"next": "//evil.example/x"})
        self.assertEqual(headers["Location"], "/?saved=1")

    def test_invalid_form_shows_the_reason(self):
        self.directory.users["me@example.com"]["attributes"]["notify"]["push_instance"] = "none"
        status, html, _ = self.request("/save", {"g:Storage": "push", "next": "/"})
        self.assertEqual(status, 400)
        self.assertIn("Set up your phone first", html)
        self.assertEqual(self.directory.saved, [])

    def test_authentik_down_is_503(self):
        self.directory.down = True
        self.assertEqual(self.request("/")[0], 503)

    def test_saved_banner(self):
        _, html, _ = self.request("/?saved=1")
        self.assertIn("Saved.", html)


if __name__ == "__main__":
    unittest.main()
