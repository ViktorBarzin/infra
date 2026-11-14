"""The guest-invite guards, run against fake Authentik objects.

validate-invite-code (invite-flow.tf) and invitation-made-by-cloud-inviter
(cloud-inviter.tf) are Authentik expression policies. These tests take each
expression body out of the .tf file, fill in its Terraform interpolations,
and run it the way Authentik does: as the body of a function of `request`.

Run: python3 -m unittest discover -s stacks/authentik -p 'test_*.py'
"""

import datetime
import os
import re
import sys
import textwrap
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
NOW = datetime.datetime(2026, 11, 14, 12, 0, tzinfo=datetime.timezone.utc)
INVITER_PK = 42
ADMIN_PK = 7


def read(name):
    with open(os.path.join(HERE, name), encoding="utf-8") as f:
        return f.read()


def local(name):
    """A plain local from cloud-inviter.tf: a quoted string or a number."""
    match = re.search(rf"^\s*{name}\s*=\s*(\"[^\"]*\"|\d+)", read("cloud-inviter.tf"), re.M)
    if not match:
        raise AssertionError(f"local {name} not found")
    return match.group(1).strip('"')


def expression(tf_file, resource):
    """The heredoc body of `resource "authentik_policy_expression" "<resource>"`."""
    text = read(tf_file)
    start = text.index(f'resource "authentik_policy_expression" "{resource}"')
    body = re.search(r"<<-EOT\n(.*?)\n\s*EOT", text[start:], re.S)
    if not body:
        raise AssertionError(f"no heredoc in {resource}")
    code = textwrap.dedent(body.group(1))
    values = {
        "authentik_user.cloud_inviter.id": str(INVITER_PK),
        "local.cloud_guest_group_name": local("cloud_guest_group_name"),
        "local.cloud_invite_max_days": local("cloud_invite_max_days"),
    }
    for key, value in values.items():
        code = code.replace("${" + key + "}", value)
    if "${" in code:
        raise AssertionError(f"unfilled interpolation in {resource}: {code}")
    return code


class Invitation:
    """The fields of authentik's Invitation the policies read."""

    store = []

    def __init__(self, fixed_data, created_by_id=ADMIN_PK, single_use=True,
                 expires=None, expiring=True):
        self.fixed_data = fixed_data
        self.created_by_id = created_by_id
        self.single_use = single_use
        self.expires = expires
        self.expiring = expiring

    class objects:  # noqa: N801 - Django's manager name
        @staticmethod
        def filter(fixed_data__code):
            return [i for i in Invitation.store if (i.fixed_data or {}).get("code") == fixed_data__code]


def install_fakes():
    timezone = types.ModuleType("django.utils.timezone")
    timezone.now = lambda: NOW
    utils = types.ModuleType("django.utils")
    utils.timezone = timezone
    models = types.ModuleType("authentik.stages.invitation.models")
    models.Invitation = Invitation
    for name in ("django", "authentik", "authentik.stages", "authentik.stages.invitation"):
        sys.modules.setdefault(name, types.ModuleType(name))
    sys.modules["django.utils"] = utils
    sys.modules["django.utils.timezone"] = timezone
    sys.modules["authentik.stages.invitation.models"] = models


def compile_policy(code):
    source = "def policy(request, ak_logger=None):\n" + textwrap.indent(code, "    ")
    scope = {}
    exec(compile(source, "<policy>", "exec"), scope)  # noqa: S102 - the policy under test
    return scope["policy"]


class Request:
    def __init__(self, context):
        self.context = context


install_fakes()
VALIDATE = compile_policy(expression("invite-flow.tf", "validate_invite_code"))
REFUSE = compile_policy(expression("cloud-inviter.tf", "cloud_inviter_invitation"))
GUESTS = local("cloud_guest_group_name")


def cloud(**overrides):
    fields = {
        "fixed_data": {"code": "R7KM4Q", "target_group": GUESTS},
        "created_by_id": INVITER_PK,
        "single_use": True,
        "expires": NOW + datetime.timedelta(days=7),
        "expiring": True,
    }
    fields.update(overrides)
    return Invitation(**fields)


def validate(typed="r7k-m4q"):
    request = Request({"prompt_data": {"invite_code": typed, "email": "guest@example.com"}})
    return VALIDATE(request), request.context["prompt_data"]


class ValidateInviteCode(unittest.TestCase):
    def setUp(self):
        Invitation.store = []

    def test_an_admin_code_keeps_working_in_any_shape(self):
        Invitation.store = [Invitation({"code": "R7KM4Q", "target_group": "Proxy Users", "note": "x"},
                                       single_use=False)]
        ok, pd = validate()
        self.assertTrue(ok)
        self.assertEqual(pd["attributes.invite_group"], "Proxy Users")

    def test_a_cloud_code_in_the_guarded_shape_is_accepted(self):
        Invitation.store = [cloud()]
        ok, pd = validate()
        self.assertTrue(ok)
        self.assertEqual(pd["attributes.invite_group"], GUESTS)
        self.assertEqual(pd["invite_code"], "R7KM4Q")

    def test_a_cloud_code_used_just_after_it_was_made_passes_the_skew_margin(self):
        Invitation.store = [cloud(expires=NOW + datetime.timedelta(days=7, minutes=5))]
        self.assertTrue(validate()[0])

    def test_refused_cloud_codes_create_no_account(self):
        cases = {
            "another group": cloud(fixed_data={"code": "R7KM4Q", "target_group": "Home Server Admins"}),
            "extra fixed_data": cloud(fixed_data={"code": "R7KM4Q", "target_group": GUESTS,
                                                  "attributes.cloud_apps_email_vouched": True}),
            "an email in fixed_data": cloud(fixed_data={"code": "R7KM4Q", "target_group": GUESTS,
                                                        "email": "victim@example.com"}),
            "no target_group": cloud(fixed_data={"code": "R7KM4Q"}),
            "multi use": cloud(single_use=False),
            "no expiry": cloud(expires=None),
            "never expiring": cloud(expiring=False),
            "eight days left": cloud(expires=NOW + datetime.timedelta(days=8)),
            "a year left": cloud(expires=NOW + datetime.timedelta(days=365)),
            "expired": cloud(expires=NOW - datetime.timedelta(minutes=1)),
        }
        for name, invitation in cases.items():
            with self.subTest(name):
                Invitation.store = [invitation]
                ok, pd = validate()
                self.assertFalse(ok)
                self.assertNotIn("attributes.invite_group", pd)

    def test_a_refused_cloud_code_does_not_hide_a_valid_one_with_the_same_code(self):
        Invitation.store = [cloud(fixed_data={"code": "R7KM4Q", "target_group": "Home Server Admins"}),
                            Invitation({"code": "R7KM4Q", "target_group": "Proxy Users"})]
        ok, pd = validate()
        self.assertTrue(ok)
        self.assertEqual(pd["attributes.invite_group"], "Proxy Users")

    def test_no_code_or_an_unknown_code_is_refused(self):
        Invitation.store = [cloud()]
        self.assertFalse(validate("")[0])
        self.assertFalse(validate("AAA-AAA")[0])


class RefuseOnInvitationStageFlows(unittest.TestCase):
    def test_a_cloud_inviter_invitation_includes_the_deny_stage(self):
        self.assertTrue(REFUSE(Request({"invitation": cloud()})))

    def test_other_invitations_and_none_pass(self):
        self.assertFalse(REFUSE(Request({"invitation": Invitation({"attributes.proxy_only": True})})))
        self.assertFalse(REFUSE(Request({})))


class DenyStageWiring(unittest.TestCase):
    """The binding must keep the stage in the plan and fail closed."""

    def test_binding_settings(self):
        text = read("cloud-inviter.tf")
        binding = text[text.index('resource "authentik_flow_stage_binding" "cloud_guest_invite_deny"'):]
        binding = binding[: binding.index("\n}\n")]
        self.assertRegex(binding, r"evaluate_on_plan\s*=\s*false")
        self.assertRegex(binding, r"re_evaluate_policies\s*=\s*true")
        policy = text[text.index('resource "authentik_policy_binding" "cloud_guest_invite_deny"'):]
        self.assertRegex(policy, r"failure_result\s*=\s*true")
        self.assertIn('"invitation-enrollment"', text)


if __name__ == "__main__":
    unittest.main()
