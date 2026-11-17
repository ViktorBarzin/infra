"""The notify pipe's config renderer, run against fake Authentik users.

files/notify_render.py is the body of the webhook body mapping in notify.tf.
Authentik runs it as a function body with `user`, `notification` and
`request` in scope. These tests fill in the Terraform placeholder the same
way notify.tf does and run it with a fake authentik.core.models.User.

Run: python3 -m unittest discover -s stacks/authentik -p 'test_*.py'
"""

import json
import os
import sys
import textwrap
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOPICS = {"internet": "Sofia internet uplink"}


class FakeUser:
    def __init__(self, username, account_email="", active=True, **notify):
        self.username = username
        self.email = account_email
        self.is_active = active
        self.attributes = {"notify": notify} if notify else {}


class FakeManager:
    users = []

    def filter(self, **kw):
        assert kw == {"is_active": True, "attributes__has_key": "notify"}, kw
        return [u for u in self.users if u.is_active and "notify" in u.attributes]


def render(users):
    FakeManager.users = users
    models = types.ModuleType("authentik.core.models")
    models.User = type("User", (), {"objects": FakeManager()})
    for name in ("authentik", "authentik.core"):
        sys.modules.setdefault(name, types.ModuleType(name))
    sys.modules["authentik.core.models"] = models
    with open(os.path.join(HERE, "files", "notify_render.py"), encoding="utf-8") as f:
        body = f.read().replace("__TOPICS__", json.dumps(sorted(TOPICS)))
    src = "def mapping(user, notification, request):\n" + textwrap.indent(body, "    ")
    scope = {}
    exec(src, scope)
    result = scope["mapping"](None, None, None)
    assert result["format"] == "yaml"
    return json.loads(result["config"])


def urls(config):
    """{url: tag} for every URL except the placeholder."""
    out = {}
    for entry in config["urls"]:
        ((url, opts),) = entry.items()
        if url.startswith("json://127.0.0.1"):
            continue
        out[url] = opts[0]["tag"]
    return out


VIKTOR_PUSH = "jsons://ha-london.viktorbarzin.me/api/services/notify/mobile_app_viktor_barzins_iphone_17?+Authorization=Bearer%20${ha_london_token}&:version&:type&:attachments"


def email_url(to):
    return ("mailtos://mail.viktorbarzin.me:587?user=alertmanager@viktorbarzin.me&pass=${smtp_password}"
            "&from=alertmanager@viktorbarzin.me&name=Homelab&to=" + to)


class RenderTest(unittest.TestCase):
    def test_template_names_are_declared(self):
        config = render([])
        self.assertEqual(config["version"], 1)
        self.assertEqual(config["template"], {"ha_sofia_token": None, "ha_london_token": None, "smtp_password": None})

    def test_empty_config_still_has_a_url(self):
        # apprise-api refuses a config with no URL, which would leave the old one in place.
        self.assertEqual(len(render([])["urls"]), 1)
        self.assertEqual(urls(render([])), {})

    def test_push_topic_and_email_default(self):
        u = FakeUser("vbarzin", "me@example.com", push_instance="ha-london",
                     push_service="mobile_app_viktor_barzins_iphone_17",
                     topics={"internet": "push"}, default="email")
        self.assertEqual(urls(render([u])), {VIKTOR_PUSH: "topic-internet", email_url("me@example.com"): "person-vbarzin"})

    def test_one_channel_carries_several_tags(self):
        u = FakeUser("some.person", push_instance="ha-sofia", push_service="mobile_app_someones_iphone",
                     topics={"internet": "push"}, default="push")
        ((url, tag),) = urls(render([u])).items()
        self.assertTrue(url.startswith("jsons://ha-sofia.viktorbarzin.me/api/services/notify/mobile_app_someones_iphone?"))
        self.assertIn("${ha_sofia_token}", url)
        self.assertEqual(tag, "person-some-person, topic-internet")

    def test_email_field_wins_over_account_email(self):
        u = FakeUser("a", "account@example.com", email="other@example.com", default="email")
        self.assertEqual(urls(render([u])), {email_url("other@example.com"): "person-a"})

    def test_channel_without_subscription_is_left_out(self):
        u = FakeUser("a", "a@example.com", push_instance="ha-sofia", push_service="mobile_app_x", topics={"internet": "off"})
        self.assertEqual(urls(render([u])), {})

    def test_unknown_topic_is_ignored(self):
        u = FakeUser("a", "a@example.com", topics={"made-up": "email"})
        self.assertEqual(urls(render([u])), {})

    def test_push_choice_without_push_channel_is_ignored(self):
        u = FakeUser("a", "a@example.com", topics={"internet": "push"}, default="email")
        self.assertEqual(urls(render([u])), {email_url("a@example.com"): "person-a"})

    def test_bad_service_name_cannot_rewrite_the_url(self):
        u = FakeUser("a", push_instance="ha-sofia", push_service="x?evil=1", default="push")
        self.assertEqual(urls(render([u])), {})

    def test_unknown_instance_is_ignored(self):
        u = FakeUser("a", push_instance="evil.example.com", push_service="mobile_app_x", default="push")
        self.assertEqual(urls(render([u])), {})

    def test_bad_email_cannot_add_query_fields(self):
        u = FakeUser("a", email="x@example.com&to=y@example.com", default="email")
        self.assertEqual(urls(render([u])), {})

    def test_inactive_users_are_skipped(self):
        u = FakeUser("a", "a@example.com", active=False, default="email")
        self.assertEqual(urls(render([u])), {})


if __name__ == "__main__":
    unittest.main()
