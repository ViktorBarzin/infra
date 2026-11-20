# Webhook body mapping of the notify pipe (notify.tf). Authentik runs this as
# a function body on every User change and POSTs the result to apprise-api
# /add/notify, which replaces the whole stored config. It renders each
# person's Channels from their attributes, tagged u-<username>-push and
# u-<username>-email. Which alert goes to which tag is the notify adapter's
# job (stacks/notify/files/subs.py), so this file knows nothing about alerts.
# The ${...} markers are Apprise template values; apprise-api fills them from
# its environment (stacks/notify/main.tf), so no secret is stored here or in
# Apprise's config. The push URL's ":version", ":type" and ":attachments" drop
# those fields from Apprise's JSON body: HA's notify service answers 400 to
# any of them. Tests: test_notify_render.py.
import json
import re

from authentik.core.models import User

HOSTS = {"ha-sofia": "ha-sofia.viktorbarzin.me", "ha-london": "ha-london.viktorbarzin.me"}
TOKENS = {"ha-sofia": "${ha_sofia_token}", "ha-london": "${ha_london_token}"}
EMAIL = (
    "mailtos://mail.viktorbarzin.me:587?user=alertmanager@viktorbarzin.me&pass=${smtp_password}"
    "&from=alertmanager@viktorbarzin.me&name=Homelab&to="
)


def tag(name):
    # The adapter (stacks/notify/files/subs.py) uses the same rule.
    return re.sub(r"[^a-z0-9]+", "-", name.strip().lower()).strip("-")


# apprise-api refuses a config without a URL, which would keep the previous
# config. This one is never sent to: every send names a tag it does not carry.
urls = [{"json://127.0.0.1:9/": [{"tag": "placeholder"}]}]
for person in User.objects.filter(is_active=True, attributes__has_key="notify"):
    settings = person.attributes.get("notify") or {}
    instance = settings.get("push_instance")
    service = (settings.get("push_service") or "").strip()
    if instance in HOSTS and re.fullmatch(r"[a-z0-9_]+", service):
        url = "jsons://%s/api/services/notify/%s?+Authorization=Bearer%%20%s&:version&:type&:attachments" % (
            HOSTS[instance],
            service,
            TOKENS[instance],
        )
        urls.append({url: [{"tag": "u-%s-push" % tag(person.username)}]})
    address = (settings.get("email") or person.email or "").strip()
    if re.fullmatch(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", address):
        urls.append({EMAIL + address: [{"tag": "u-%s-email" % tag(person.username)}]})

config = {
    "version": 1,
    "template": {"ha_sofia_token": None, "ha_london_token": None, "smtp_password": None},
    "urls": urls,
}
# JSON is valid YAML, and json.dumps quotes every value safely.
return {"format": "yaml", "config": json.dumps(config)}
