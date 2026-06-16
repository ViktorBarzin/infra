"""Unit tests for the pure roster derivation + offboarding-diff engine.

These exercise external behaviour only (parse -> validate -> derive -> diff);
no host I/O is touched. Mirrors the pure-core pytest style used elsewhere in
the monorepo. See PRD ViktorBarzin/infra#9 (modules #1 roster engine, #5
offboarding diff).
"""

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
