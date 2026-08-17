"""Unit tests for the pure roster derivation + offboarding-diff engine.

These exercise external behaviour only (parse -> validate -> derive -> diff);
no host I/O is touched. Mirrors the pure-core pytest style used elsewhere in
the monorepo. See PRD ViktorBarzin/infra#9 (modules #1 roster engine, #5
offboarding diff).
"""

import json
import textwrap

import pytest

import roster_engine as eng


def _roster(yaml_text: str) -> "eng.Roster":
    return eng.load_roster(textwrap.dedent(yaml_text))


# --------------------------------------------------------------------------
# load_roster: parsing + structural validation (module #1)
# --------------------------------------------------------------------------


def test_parses_user_fields_and_tier():
    r = _roster(
        """
        users:
          emo: {authentik_user: emil.barzin, k8s_user: emo, tier: power-user}
        """
    )
    u = r.users["emo"]
    assert u.os_user == "emo"
    assert u.authentik_user == "emil.barzin"
    assert u.k8s_user == "emo"
    assert u.tier == "power-user"
    assert u.namespaces == ()


def test_namespace_owner_carries_namespaces():
    r = _roster(
        """
        users:
          ancamilea: {authentik_user: ancaelena98, k8s_user: anca,
                      tier: namespace-owner, namespaces: [plotting-book]}
        """
    )
    assert r.users["ancamilea"].namespaces == ("plotting-book",)


def test_admin_tier_is_accepted():
    r = _roster(
        "users: {wizard: {authentik_user: vbarzin, k8s_user: wizard, tier: admin}}"
    )
    assert r.users["wizard"].tier == "admin"


def test_rejects_unknown_tier():
    with pytest.raises(eng.RosterError, match="tier"):
        _roster("users: {bob: {authentik_user: b, k8s_user: b, tier: wizard-king}}")


def test_rejects_missing_required_field():
    with pytest.raises(eng.RosterError, match="authentik_user"):
        _roster("users: {bob: {k8s_user: b, tier: power-user}}")


def test_namespace_owner_requires_namespaces():
    with pytest.raises(eng.RosterError, match="namespace"):
        _roster("users: {bob: {authentik_user: b, k8s_user: b, tier: namespace-owner}}")


def test_non_namespace_owner_must_not_set_namespaces():
    with pytest.raises(eng.RosterError, match="namespace"):
        _roster(
            "users: {bob: {authentik_user: b, k8s_user: b, tier: power-user, "
            "namespaces: [x]}}"
        )


def test_empty_roster_is_valid():
    assert _roster("users: {}").users == {}


def test_missing_users_key_is_valid_empty():
    assert _roster("{}").users == {}


# --------------------------------------------------------------------------
# code_layout + repos: per-user workspace layout (~/code/<repo> clones)
# --------------------------------------------------------------------------


def test_code_layout_defaults_to_single_with_no_repos():
    r = _roster("users: {emo: {authentik_user: e, k8s_user: emo, tier: power-user}}")
    assert r.users["emo"].code_layout == "single"
    assert r.users["emo"].repos == ()


def test_workspace_layout_carries_repos():
    r = _roster(
        """
        users:
          ancamilea: {authentik_user: ancaelena98, k8s_user: anca,
                      tier: namespace-owner, namespaces: [plotting-book],
                      code_layout: workspace, repos: [tripit]}
        """
    )
    u = r.users["ancamilea"]
    assert u.code_layout == "workspace"
    assert u.repos == ("tripit",)


def test_rejects_unknown_code_layout():
    with pytest.raises(eng.RosterError, match="code_layout"):
        _roster(
            "users: {bob: {authentik_user: b, k8s_user: b, tier: power-user, "
            "code_layout: flat}}"
        )


def test_repos_require_workspace_layout():
    # repos clone to ~/code/<name>, which only exists under the workspace layout.
    with pytest.raises(eng.RosterError, match="workspace"):
        _roster(
            "users: {bob: {authentik_user: b, k8s_user: b, tier: power-user, "
            "repos: [tripit]}}"
        )


@pytest.mark.parametrize("bad", ["../evil", "a/b", "", ".hidden", "-flag"])
def test_rejects_path_unsafe_repo_name(bad):
    # Repo names become root-executed clone/mv paths — reject anything that
    # isn't a plain leading-alphanumeric name.
    with pytest.raises(eng.RosterError, match="repo"):
        _roster(
            "users: {bob: {authentik_user: b, k8s_user: b, tier: power-user, "
            f"code_layout: workspace, repos: ['{bad}']" "}}"
        )


def test_rejects_infra_in_repos():
    # The infra clone is implicit at ~/code/infra for workspace users.
    with pytest.raises(eng.RosterError, match="implicit"):
        _roster(
            "users: {bob: {authentik_user: b, k8s_user: b, tier: power-user, "
            "code_layout: workspace, repos: [infra]}}"
        )


def test_derive_accounts_carry_code_layout_and_repos():
    r = _roster(
        """
        users:
          emo:       {authentik_user: e, k8s_user: emo, tier: power-user}
          ancamilea: {authentik_user: a, k8s_user: anca, tier: namespace-owner,
                      namespaces: [plotting-book], code_layout: workspace,
                      repos: [tripit]}
        """
    )
    ds = eng.derive_desired_state(r, {})
    assert ds.accounts["emo"].code_layout == "single"
    assert ds.accounts["emo"].repos == ()
    assert ds.accounts["ancamilea"].code_layout == "workspace"
    assert ds.accounts["ancamilea"].repos == ("tripit",)


def test_desired_state_dict_includes_code_layout_and_repos():
    # The JSON adapter is the contract the bash provisioner consumes via jq.
    r = _roster(
        "users: {ancamilea: {authentik_user: a, k8s_user: anca, "
        "tier: namespace-owner, namespaces: [plotting-book], "
        "code_layout: workspace, repos: [tripit]}}"
    )
    d = eng._desired_state_to_dict(eng.derive_desired_state(r, {}))
    assert d["accounts"]["ancamilea"]["code_layout"] == "workspace"
    assert d["accounts"]["ancamilea"]["repos"] == ["tripit"]


# --------------------------------------------------------------------------
# validate_tiers: roster tier vs live k8s_users (fail-loud, module #1)
# --------------------------------------------------------------------------


def test_validate_ok_when_tiers_match():
    r = _roster(
        "users: {ancamilea: {authentik_user: a, k8s_user: anca, "
        "tier: namespace-owner, namespaces: [plotting-book]}}"
    )
    assert eng.validate_tiers(r, {"anca": "namespace-owner"}) == []


def test_validate_flags_tier_mismatch_as_error():
    # roster says power-user, cluster says namespace-owner -> a real conflict -> ERROR (abort).
    r = _roster(
        "users: {ancamilea: {authentik_user: a, k8s_user: anca, tier: power-user}}"
    )
    issues = eng.validate_tiers(r, {"anca": "namespace-owner"})
    assert len(issues) == 1
    assert issues[0].severity == "error"
    assert issues[0].os_user == "ancamilea"
    assert "power-user" in issues[0].message and "namespace-owner" in issues[0].message


def test_validate_flags_netnew_absent_as_warn():
    # emo is power-user in the roster but has no k8s_users entry yet. Onboarding the
    # workstation should still proceed; the kubectl grant is pending -> WARN, not error.
    r = _roster("users: {emo: {authentik_user: e, k8s_user: emo, tier: power-user}}")
    issues = eng.validate_tiers(r, {})
    assert len(issues) == 1
    assert issues[0].severity == "warn"
    assert "emo" in issues[0].message and "k8s_users" in issues[0].message


def test_validate_skips_admin_tier():
    # wizard (admin) is cluster-admin via a separate mechanism, not k8s_users.
    r = _roster(
        "users: {wizard: {authentik_user: vbarzin, k8s_user: wizard, tier: admin}}"
    )
    assert eng.validate_tiers(r, {}) == []


def test_has_blocking_errors_distinguishes_mismatch_from_absent():
    mismatch = _roster(
        "users: {ancamilea: {authentik_user: a, k8s_user: anca, tier: power-user}}"
    )
    absent = _roster(
        "users: {emo: {authentik_user: e, k8s_user: emo, tier: power-user}}"
    )
    assert (
        eng.has_blocking_errors(
            eng.validate_tiers(mismatch, {"anca": "namespace-owner"})
        )
        is True
    )
    assert eng.has_blocking_errors(eng.validate_tiers(absent, {})) is False


# --------------------------------------------------------------------------
# derive_desired_state: accounts, sticky ports, ttyd map, dispatch (module #1)
# --------------------------------------------------------------------------

THREE = """
    users:
      wizard:    {authentik_user: vbarzin,     k8s_user: wizard, tier: admin}
      emo:       {authentik_user: emil.barzin, k8s_user: emo,    tier: power-user}
      ancamilea: {authentik_user: ancaelena98, k8s_user: anca,   tier: namespace-owner, namespaces: [plotting-book]}
"""

LIVE_PORTS = {"wizard": 3773, "emo": 3774, "ancamilea": 3775}


def test_derive_preserves_existing_sticky_ports():
    ds = eng.derive_desired_state(_roster(THREE), LIVE_PORTS)
    assert ds.ports == {"wizard": 3773, "emo": 3774, "ancamilea": 3775}


def test_derive_allocates_next_free_port_for_new_user():
    ds = eng.derive_desired_state(_roster(THREE), {"wizard": 3773})
    # emo + ancamilea are new -> next free from 3773 skipping the used 3773
    assert ds.ports["wizard"] == 3773
    assert sorted([ds.ports["emo"], ds.ports["ancamilea"]]) == [3774, 3775]


def test_derive_dispatch_keyed_by_authentik_user():
    ds = eng.derive_desired_state(_roster(THREE), LIVE_PORTS)
    assert ds.dispatch == {
        "vbarzin": {"os_user": "wizard", "port": 3773},
        "emil.barzin": {"os_user": "emo", "port": 3774},
        "ancaelena98": {"os_user": "ancamilea", "port": 3775},
    }


def test_derive_ttyd_map_has_one_mapping_per_user():
    ds = eng.derive_desired_state(_roster(THREE), LIVE_PORTS)
    body = [
        line
        for line in ds.ttyd_user_map.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    assert set(body) == {"vbarzin=wizard", "emil.barzin=emo", "ancaelena98=ancamilea"}


def _admins_body(ds):
    return [
        line
        for line in ds.ttyd_admins.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def test_derive_ttyd_admins_lists_only_the_admin_tier():
    # terminal-lobby's act-as switch reads this file to decide who may act as
    # another user. It cannot use Authentik group membership: every devvm user
    # is in "Home Server Admins" (that is how they reach the lobby host at
    # all), so the roster tier is the only thing that distinguishes them.
    ds = eng.derive_desired_state(_roster(THREE), LIVE_PORTS)
    assert _admins_body(ds) == ["wizard"]


def test_derive_ttyd_admins_is_empty_when_nobody_is_an_admin():
    # Fails closed by construction: no admin tier, no admins, and the act-as
    # feature is simply unavailable rather than open.
    roster = _roster(
        """
        users:
          emo: {authentik_user: emil.barzin, k8s_user: emo, tier: power-user}
        """
    )
    ds = eng.derive_desired_state(roster, {"emo": 3774})
    assert _admins_body(ds) == []


def test_derive_ttyd_admins_lists_every_admin():
    roster = _roster(
        """
        users:
          wizard: {authentik_user: vbarzin,     k8s_user: wizard, tier: admin}
          emo:    {authentik_user: emil.barzin, k8s_user: emo,    tier: admin}
        """
    )
    ds = eng.derive_desired_state(roster, {"wizard": 3773, "emo": 3774})
    assert sorted(_admins_body(ds)) == ["emo", "wizard"]


def test_derive_ttyd_admins_carries_a_do_not_edit_header():
    # Same provenance note as the user map: this file is regenerated hourly,
    # so a hand edit would be silently reverted.
    ds = eng.derive_desired_state(_roster(THREE), LIVE_PORTS)
    assert ds.ttyd_admins.startswith("#")
    assert "roster.yaml" in ds.ttyd_admins


def test_derive_accounts_assign_tier_groups_and_shell():
    ds = eng.derive_desired_state(_roster(THREE), LIVE_PORTS)
    assert ds.accounts["wizard"].groups == ("code-shared", "docker", "sudo")
    assert ds.accounts["emo"].groups == ()
    assert ds.accounts["ancamilea"].groups == ()
    assert ds.accounts["emo"].shell == "/bin/zsh"


def test_derive_is_deterministic():
    r = _roster(THREE)
    assert eng.derive_desired_state(r, LIVE_PORTS) == eng.derive_desired_state(
        r, LIVE_PORTS
    )


# --------------------------------------------------------------------------
# derive_desired_state: per-user playwright-mcp ports (reproducible browser MCP)
# --------------------------------------------------------------------------

# wizard (admin) IS a roster user, so playwright ports are allocated for every
# user incl. the admin, from PLAYWRIGHT_BASE_PORT=8931. The live in-session
# assignment is wizard 8931, emo 8932, ancamilea 8933.
LIVE_PLAYWRIGHT_PORTS = {"wizard": 8931, "emo": 8932, "ancamilea": 8933}


def test_derive_allocates_playwright_ports_for_all_users_incl_admin():
    ds = eng.derive_desired_state(_roster(THREE), {})
    # fresh box: sorted os_user order (ancamilea, emo, wizard) from 8931
    assert ds.playwright_ports == {"ancamilea": 8931, "emo": 8932, "wizard": 8933}


def test_derive_preserves_existing_sticky_playwright_ports():
    # Seeded with the live assignment -> preserved exactly (nobody's port moves).
    ds = eng.derive_desired_state(
        _roster(THREE), {}, existing_playwright_ports=LIVE_PLAYWRIGHT_PORTS
    )
    assert ds.playwright_ports == LIVE_PLAYWRIGHT_PORTS


def test_derive_allocates_next_free_playwright_port_for_new_user():
    # Existing users sticky; a brand-new user gets the next free port from 8931.
    ds = eng.derive_desired_state(
        _roster(THREE), {}, existing_playwright_ports={"wizard": 8931, "emo": 8932}
    )
    assert ds.playwright_ports["wizard"] == 8931
    assert ds.playwright_ports["emo"] == 8932
    assert ds.playwright_ports["ancamilea"] == 8933  # next free, skipping 8931/8932


def test_playwright_ports_are_disjoint_from_t3_ports():
    ds = eng.derive_desired_state(_roster(THREE), LIVE_PORTS, LIVE_PLAYWRIGHT_PORTS)
    assert set(ds.ports.values()).isdisjoint(ds.playwright_ports.values())


def test_desired_state_dict_includes_playwright_ports():
    # The JSON adapter is the contract the bash provisioner consumes via jq.
    d = eng._desired_state_to_dict(
        eng.derive_desired_state(_roster(THREE), {}, LIVE_PLAYWRIGHT_PORTS)
    )
    assert d["playwright_ports"] == LIVE_PLAYWRIGHT_PORTS


# --------------------------------------------------------------------------
# groups_to_add: the additive-only invariant (module #1)
# --------------------------------------------------------------------------


def test_groups_to_add_returns_only_missing():
    assert eng.groups_to_add(("sudo", "docker", "code-shared"), ("docker",)) == [
        "code-shared",
        "sudo",
    ]


def test_groups_to_add_never_proposes_removal_of_extra_groups():
    # emo currently has code-shared+docker (legacy). A power-user reconcile wants
    # no groups -> must NOT strip anything (additive-only invariant).
    assert eng.groups_to_add((), ("code-shared", "docker")) == []


def test_groups_to_add_idempotent_when_all_present():
    assert eng.groups_to_add(("sudo",), ("sudo", "docker")) == []


# --------------------------------------------------------------------------
# offboarding diff: staged plan, destructive never auto (module #5)
# --------------------------------------------------------------------------


def test_to_deprovision_is_old_minus_new():
    old = _roster(THREE)
    new = _roster(
        """
        users:
          wizard: {authentik_user: vbarzin, k8s_user: wizard, tier: admin}
          emo:    {authentik_user: emil.barzin, k8s_user: emo, tier: power-user}
        """
    )
    assert eng.to_deprovision(old, new) == ["ancamilea"]


def test_to_deprovision_empty_when_nothing_removed():
    r = _roster(THREE)
    assert eng.to_deprovision(r, r) == []


def test_offboard_plan_reversible_cut_targets_exactly_the_removed_user():
    old = _roster(THREE)
    new = _roster(
        "users: {wizard: {authentik_user: vbarzin, k8s_user: wizard, tier: admin}}"
    )
    plan = eng.offboard_plan(old, new, include_destructive=False)
    cut_users = {a.os_user for a in plan}
    assert cut_users == {"emo", "ancamilea"}
    assert all(a.reversible for a in plan)


def test_offboard_plan_excludes_destructive_by_default():
    old = _roster(THREE)
    new = _roster(
        "users: {wizard: {authentik_user: vbarzin, k8s_user: wizard, tier: admin}}"
    )
    auto = eng.offboard_plan(old, new, include_destructive=False)
    assert all(a.kind != "userdel_archive" for a in auto)


def test_offboard_plan_includes_destructive_only_when_explicitly_requested():
    old = _roster(THREE)
    new = _roster(
        "users: {wizard: {authentik_user: vbarzin, k8s_user: wizard, tier: admin}}"
    )
    full = eng.offboard_plan(old, new, include_destructive=True)
    destructive = [a for a in full if a.kind == "userdel_archive"]
    assert {a.os_user for a in destructive} == {"emo", "ancamilea"}
    assert all(not a.reversible for a in destructive)


def test_claude_auth_defaults_to_enabled():
    r = _roster("users: {emo: {authentik_user: e, k8s_user: emo, tier: power-user}}")
    assert r.users["emo"].claude_auth is True


def test_claude_auth_can_be_disabled_per_user():
    # For a roster member who has an account but does not use Claude here.
    # The per-user timer would otherwise fail every ~6h forever and alert,
    # because there is no credential to validate or restore.
    r = _roster(
        """
        users:
          ancamilea: {authentik_user: ancaelena98, k8s_user: anca,
                      tier: namespace-owner, namespaces: [plotting-book],
                      claude_auth: false}
        """
    )
    assert r.users["ancamilea"].claude_auth is False


def test_claude_auth_must_be_a_bool():
    with pytest.raises(eng.RosterError):
        _roster(
            "users: {emo: {authentik_user: e, k8s_user: emo, "
            "tier: power-user, claude_auth: nope}}"
        )


def test_claude_auth_flows_through_to_the_account():
    # The provisioner reads the ACCOUNT, not the roster user, so the flag is
    # only load-bearing if it survives derive_desired_state.
    r = _roster(
        """
        users:
          ancamilea: {authentik_user: ancaelena98, k8s_user: anca,
                      tier: namespace-owner, namespaces: [plotting-book],
                      claude_auth: false}
          emo: {authentik_user: e, k8s_user: emo, tier: power-user}
        """
    )
    ds = eng.derive_desired_state(r, {})
    assert ds.accounts["ancamilea"].claude_auth is False
    assert ds.accounts["emo"].claude_auth is True


def test_parked_defaults_to_false():
    r = _roster("users: {emo: {authentik_user: e, k8s_user: emo, tier: power-user}}")
    assert r.users["emo"].parked is False


def test_parked_must_be_a_bool():
    with pytest.raises(eng.RosterError):
        _roster(
            "users: {emo: {authentik_user: e, k8s_user: emo, "
            "tier: power-user, parked: yes-please}}"
        )


def test_parked_implies_claude_auth_off_in_the_derived_account():
    # The provisioner acts on the ACCOUNT. A parked account must not report
    # claude_auth: true, or the desired state would claim a daemon should run
    # that we have just decided to stop.
    r = _roster(
        """
        users:
          ancamilea: {authentik_user: ancaelena98, k8s_user: anca,
                      tier: namespace-owner, namespaces: [plotting-book],
                      parked: true}
        """
    )
    ds = eng.derive_desired_state(r, {})
    assert ds.accounts["ancamilea"].parked is True
    assert ds.accounts["ancamilea"].claude_auth is False


def test_parking_does_not_touch_the_rest_of_the_account():
    # Parking is reversible: the account, layout and repos must survive so
    # flipping the flag back restores the user exactly.
    r = _roster(
        """
        users:
          ancamilea: {authentik_user: ancaelena98, k8s_user: anca,
                      tier: namespace-owner, namespaces: [plotting-book],
                      code_layout: workspace, repos: [tripit], parked: true}
        """
    )
    a = eng.derive_desired_state(r, {}).accounts["ancamilea"]
    assert a.tier == "namespace-owner"
    assert a.code_layout == "workspace"
    assert a.repos == ("tripit",)


def test_an_unparked_user_keeps_its_declared_claude_auth():
    r = _roster(
        "users: {emo: {authentik_user: e, k8s_user: emo, "
        "tier: power-user, claude_auth: false}}"
    )
    ds = eng.derive_desired_state(r, {})
    assert ds.accounts["emo"].parked is False
    assert ds.accounts["emo"].claude_auth is False


# --------------------------------------------------------------------------
# Membership sync — Authentik's T3 Users group is the one user list
# --------------------------------------------------------------------------
#
# The group carries one bit (member or not); the roster carries policy. So the
# diff has exactly three outcomes per person, and the two that act are keyed on
# `authentik_user`, never on the OS name — the two differ for real users
# (emil.barzin -> emo).


def test_a_member_with_a_row_is_left_alone():
    r = _roster("users: {emo: {authentik_user: emil.barzin, k8s_user: emo, tier: power-user}}")
    plan = eng.membership_plan({"emil.barzin"}, r)
    assert plan.provision == []
    assert plan.deprovision == []
    assert plan.conflicts == []


def test_a_member_with_no_row_is_provisioned_at_the_floor_tier():
    plan = eng.membership_plan({"newperson"}, _roster("users: {}"))
    assert plan.deprovision == []
    (u,) = plan.provision
    assert u.authentik_user == "newperson"
    assert u.os_user == "newperson"
    assert u.k8s_user == "newperson"
    # The floor is the least-privileged tier that still makes the box useful,
    # and matches what provision-user.yml already writes into k8s_users.
    assert u.tier == "namespace-owner"
    assert u.namespaces == ("newperson",)
    assert u.code_layout == "workspace"
    assert u.repos == ()


def test_a_row_whose_user_left_the_group_is_deprovisioned():
    r = _roster(
        "users: {emo: {authentik_user: emil.barzin, k8s_user: emo, tier: power-user},"
        " wizard: {authentik_user: vbarzin, k8s_user: wizard, tier: admin}}"
    )
    plan = eng.membership_plan({"vbarzin"}, r)
    assert plan.provision == []
    assert plan.deprovision == ["emo"]


def test_an_email_shaped_group_member_matches_on_its_local_part():
    r = _roster("users: {emo: {authentik_user: emil.barzin, k8s_user: emo, tier: power-user}}")
    # Authentik usernames in this instance ARE emails; the roster stores the
    # local part, and /etc/ttyd-user-map keys on it too.
    assert eng.membership_plan({"emil.barzin@gmail.com"}, r).deprovision == []


def test_an_os_name_is_sanitised_for_unix_but_the_identity_is_kept_verbatim():
    (u,) = eng.membership_plan({"Anca.Elena98"}, _roster("users: {}")).provision
    assert u.os_user == "anca_elena98"  # unix-safe
    assert u.authentik_user == "Anca.Elena98"  # the identity is not rewritten


def test_a_colliding_os_name_is_reported_rather_than_guessed():
    # a.b and a_b both sanitise to a_b; the second must not silently land on the
    # first one's account.
    r = _roster("users: {a_b: {authentik_user: a.b, k8s_user: a_b, tier: power-user}}")
    plan = eng.membership_plan({"a.b", "a_b"}, r)
    assert plan.provision == []
    assert len(plan.conflicts) == 1
    assert "a_b" in plan.conflicts[0]


def test_an_admin_is_never_deprovisioned_by_a_membership_diff():
    # A locked-out admin cannot fix the automation that locked them out, and
    # group membership is exactly what this would revoke.
    r = _roster("users: {wizard: {authentik_user: vbarzin, k8s_user: wizard, tier: admin}}")
    plan = eng.membership_plan(set(), r)
    assert plan.deprovision == []
    assert plan.protected == ["wizard"]


# --------------------------------------------------------------------------
# Roster text edits — the file is heavily commented, so edits are textual
# --------------------------------------------------------------------------

_LIVE_SHAPE = """\
# a header comment that must survive
users:
  wizard:    {authentik_user: vbarzin, k8s_user: wizard, tier: admin}  # trailing note
  emo:       {authentik_user: emil.barzin, k8s_user: emo, tier: power-user}
  #  a pre-existing indented comment
# gheorghe:  {authentik_user: vabbit81, k8s_user: vabbit81, tier: namespace-owner}
"""


def test_commenting_a_user_out_removes_them_from_the_parsed_roster():
    out = eng.comment_out_user(_LIVE_SHAPE, "emo", note="left T3 Users 2026-08-17")
    assert "emo" not in eng.load_roster(out).users
    assert "wizard" in eng.load_roster(out).users


def test_commenting_a_user_out_keeps_every_other_line_byte_identical():
    out = eng.comment_out_user(_LIVE_SHAPE, "emo", note="n")
    before = [l for l in _LIVE_SHAPE.splitlines() if "emo:" not in l]
    after = [l for l in out.splitlines() if "emo:" not in l and "n" != l.strip("# ")]
    assert before == [l for l in after if l in before]
    assert "# a header comment that must survive" in out
    assert "# trailing note" in out


def test_commenting_a_user_out_records_the_note_and_the_original_line():
    out = eng.comment_out_user(_LIVE_SHAPE, "emo", note="left T3 Users 2026-08-17")
    assert "left T3 Users 2026-08-17" in out
    assert "authentik_user: emil.barzin" in out  # the row is preserved, commented


def test_commenting_out_an_absent_user_is_an_error_not_a_silent_noop():
    with pytest.raises(eng.RosterError):
        eng.comment_out_user(_LIVE_SHAPE, "nobody", note="n")


def test_a_commented_user_is_not_matched_by_the_membership_diff():
    out = eng.comment_out_user(_LIVE_SHAPE, "emo", note="n")
    plan = eng.membership_plan({"vbarzin"}, eng.load_roster(out))
    assert plan.deprovision == []


def test_appending_a_user_makes_them_parse_with_the_floor_policy():
    (u,) = eng.membership_plan({"newperson"}, _roster("users: {}")).provision
    out = eng.append_user(_LIVE_SHAPE, u, note="joined T3 Users 2026-08-17")
    parsed = eng.load_roster(out).users["newperson"]
    assert parsed.authentik_user == "newperson"
    assert parsed.tier == "namespace-owner"
    assert parsed.namespaces == ("newperson",)
    assert "joined T3 Users 2026-08-17" in out
    assert "# a header comment that must survive" in out


def test_appending_a_user_twice_is_refused():
    (u,) = eng.membership_plan({"newperson"}, _roster("users: {}")).provision
    once = eng.append_user(_LIVE_SHAPE, u, note="n")
    with pytest.raises(eng.RosterError):
        eng.append_user(once, u, note="n")


def test_a_round_trip_through_both_edits_leaves_the_roster_as_it_started():
    (u,) = eng.membership_plan({"newperson"}, _roster("users: {}")).provision
    added = eng.append_user(_LIVE_SHAPE, u, note="n")
    removed = eng.comment_out_user(added, "newperson", note="n")
    assert "newperson" not in eng.load_roster(removed).users
    assert set(eng.load_roster(removed).users) == set(eng.load_roster(_LIVE_SHAPE).users)


# --------------------------------------------------------------------------
# CLI adapter — the shell's only entrypoint into this engine
# --------------------------------------------------------------------------
#
# These exist because a first cut of the reversible-cut wiring hand-loaded this
# module with importlib and got `AttributeError: 'NoneType' object has no
# attribute '__dict__'` from @dataclass (a module executed without being
# registered in sys.modules cannot resolve its own annotations). The shell had
# `|| true` on it, so the cut computed nothing, silently. A subcommand plus a
# test is the fix for both halves.


def _write(tmp_path, name, text):
    p = tmp_path / name
    p.write_text(textwrap.dedent(text))
    return str(p)


def test_the_deprovision_subcommand_names_users_dropped_from_the_roster(tmp_path, capsys):
    old = _write(tmp_path, "old.yaml", """\
        users:
          wizard: {authentik_user: vbarzin, k8s_user: wizard, tier: admin}
          gone:   {authentik_user: g, k8s_user: g, tier: power-user}
        """)
    new = _write(tmp_path, "new.yaml", """\
        users:
          wizard: {authentik_user: vbarzin, k8s_user: wizard, tier: admin}
        """)
    rc = eng._main(["deprovision", "--old", old, "--new", new])
    assert rc == 0
    assert capsys.readouterr().out.split() == ["gone"]


def test_the_deprovision_subcommand_says_nothing_when_nobody_left(tmp_path, capsys):
    same = _write(tmp_path, "r.yaml", """\
        users:
          wizard: {authentik_user: vbarzin, k8s_user: wizard, tier: admin}
        """)
    assert eng._main(["deprovision", "--old", same, "--new", same]) == 0
    assert capsys.readouterr().out.strip() == ""


def test_the_membership_subcommand_reports_without_touching_the_file(tmp_path, capsys):
    roster = _write(tmp_path, "r.yaml", """\
        users:
          emo: {authentik_user: emil.barzin, k8s_user: emo, tier: power-user}
        """)
    members = _write(tmp_path, "m.json", '["vbarzin@gmail.com"]')
    before = open(roster, encoding="utf-8").read()
    assert eng._main(["membership", "--roster", roster, "--group-members-json", members]) == 0
    assert json.loads(capsys.readouterr().out)["deprovision"] == ["emo"]
    assert open(roster, encoding="utf-8").read() == before  # report only


def test_the_membership_subcommand_rewrites_the_roster_with_apply(tmp_path, capsys):
    roster = _write(tmp_path, "r.yaml", """\
        users:
          emo: {authentik_user: emil.barzin, k8s_user: emo, tier: power-user}
        """)
    members = _write(tmp_path, "m.json", '["newperson"]')
    rc = eng._main(["membership", "--roster", roster, "--group-members-json", members,
                    "--apply", "--note", "2026-08-17"])
    assert rc == 0
    out = json.loads(capsys.readouterr().out)
    assert out["applied"] is True
    users = eng.load_roster_file(roster).users
    assert "newperson" in users and "emo" not in users


def test_a_conflict_exits_non_zero_so_the_pipeline_surfaces_it(tmp_path, capsys):
    roster = _write(tmp_path, "r.yaml", """\
        users:
          a_b: {authentik_user: a.b, k8s_user: a_b, tier: power-user}
        """)
    members = _write(tmp_path, "m.json", '["a.b", "a_b"]')
    assert eng._main(["membership", "--roster", roster, "--group-members-json", members]) == 1
