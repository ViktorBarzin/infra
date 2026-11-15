# Identity and provenance that follow the actor end to end

Research note, 2026-11-15. Read-only: nothing was changed on any live system.
Question: how can every request, from a devvm shell, an agent tool call,
kubectl, Vault, Forgejo, an Authentik-protected app or an in-cluster agent
working an issue, carry who it is on behalf of, with that person's permissions
enforced at each hop?

Labels: [source] read in a spec, doc, release or source file linked inline.
[measured] read on the devvm today. [inferred] my reasoning from sources.
[unverified] I could not confirm it.

## Summary

Viable architectures for this homelab:

1. **Attribution only.** Keep the 2026-09-01 design, turn on auditd with a
   PAM session for agent processes, and stamp `user.id` into logs and traces. Cheap, but it enforces nothing.
2. **Authentik as the token service.** Authentik 2026.8 already does RFC 8693
   token exchange with an `act` claim. Resource servers map `sub` and
   `act.sub` through structured authn (kube-apiserver), Vault JWT auth and a
   Forgejo auth gateway.
3. **Vault as the credential broker.** Every human and agent logs in to Vault
   as their own entity. Vault mints the downstream credentials (Kubernetes SA
   tokens, SSH certs, DB users, identity JWTs) named after that entity. A
   token role with `allowed_entity_aliases` covers the asynchronous issue hop.
4. **2 + 3 combined (my recommendation).** Authentik carries `sub`/`act` for
   HTTP and kubectl, and Vault brokers everything that is not OIDC-aware.
   Scoped impersonation uses Authentik object permissions generated in
   Terraform from group membership.
5. **Pomerium Core as the single gateway.** Pomerium replaces the outposts and
   fronts HTTP, SSH, kubectl and MCP. The parts this ask needs most (service
   accounts, original user context, impersonation) are Enterprise-only.

Teleport Community is not viable. Its SSO is GitHub only, and its agent identity
rows are Enterprise-only (details below).

| Option | Enforced end to end? | Delegation model | New components | Licence | Effort |
|---|---|---|---|---|---|
| 1 Attribution | No; logs only | None, `user.id` tag | auditd, PAM session in `t3-serve@` units | GPL / Apache-2.0 | S |
| 2 Authentik STS | HTTP, k8s, Vault: yes. Forgejo: via a gateway. SSH/Postgres: no | `sub` = human, `act.sub` = Actor (RFC 8693) | None; config only. Actors need the Enterprise Agents API or an unsupported workaround | MIT core; Agents is Enterprise ($5/user/month) | M |
| 3 Vault broker | Yes wherever Vault mints the credential | Vault entity per human; agent token tied to the human's entity alias | Vault k8s engine, SSH CA, token roles, a small dispatcher | Vault BSL 1.1 (homelab OK) or OpenBao MPL-2.0 | M to L |
| 4 Combined | Yes for k8s, Vault, HTTP, SSH and the async hop; Forgejo via a gateway | Both of the above | 2 + 3 | As above | L |
| 5 Pomerium Core | HTTP/SSH/k8s at the proxy; downstream only through Enterprise features | Proxy-minted JWT; no `act` | Pomerium, replacing ~90 outposts | Apache-2.0 core, key features Enterprise | L |

## What changes from the 2026-09-01 design

That design accepted "each plane keeps its own principal" and "no correlation
id through hops". Enforcement end to end breaks both. Each hop must receive a
credential minted *for that human*, so some component has to mint downstream
credentials from an upstream one. That component is a token service (Authentik
or Vault). For the async hop, that component also needs a constrained
impersonation right [inferred]. The rejection of mesh/SPIFFE still holds: the gap is
human context, not workload identity. The Teleport decision also holds, now on
licence grounds as well (section 2).

## 1. Standards

**RFC 8693 token exchange.** In impersonation, the issued token is
indistinguishable from the subject's. In delegation, a composite token
records both the subject and the actor
([§1.1](https://www.rfc-editor.org/rfc/rfc8693.html#section-1.1)). The `act`
claim names the current actor and can nest. For access control a consumer
"MUST only consider the token's top-level claims and the party identified as
the current actor"; nested prior actors are informational only
([§4.1](https://www.rfc-editor.org/rfc/rfc8693.html#section-4.1)). `may_act`
states in advance who may act for the subject
([§4.4](https://www.rfc-editor.org/rfc/rfc8693.html#section-4.4)). Resource
servers need: verify the JWT, read `sub` and `act.sub`. Stable RFC (2020).

**Transaction Tokens.** [draft-ietf-oauth-transaction-tokens-11](https://www.ietf.org/archive/id/draft-ietf-oauth-transaction-tokens-11.html),
2026-08-21. State: WG Consensus, Waiting for Write-Up
([datatracker](https://datatracker.ietf.org/doc/draft-ietf-oauth-transaction-tokens/)).
These are short-lived JWTs ("minutes") that propagate user and workload context
through a call chain inside one trust domain. Required claims: `txn`, `sub`,
`scope`, `req_wl`, `aud`, `iat`, `exp`. `tctx` and `rctx` are recommended.
They are issued by a Txn-Token Service through token exchange. §8.2 covers
internally initiated transactions, "an impersonation on behalf of a specific
user chosen based on information accessible to the workload". That is the
async-issue case. No implementation is in our stack [inferred].

**WIMSE** (all on datatracker). [arch-08](https://datatracker.ietf.org/doc/draft-ietf-wimse-arch/)
(2026-07-06), WG document. [workload-creds-03](https://datatracker.ietf.org/doc/draft-ietf-wimse-workload-creds/)
(2026-10-30), [wpt-02](https://datatracker.ietf.org/doc/draft-ietf-wimse-wpt/),
[identifier-04](https://datatracker.ietf.org/doc/draft-ietf-wimse-identifier/)
and [mutual-tls-03](https://datatracker.ietf.org/doc/draft-ietf-wimse-mutual-tls/)
are WG documents. [http-signature-08](https://datatracker.ietf.org/doc/draft-ietf-wimse-http-signature/)
(2026-11-12) is in AD Evaluation. [workload-identity-practices-08](https://datatracker.ietf.org/doc/draft-ietf-wimse-workload-identity-practices/)
is submitted to the IESG (Informational). s2s-protocol-07 was replaced.
[draft-ietf-wimse-aims-01](https://datatracker.ietf.org/doc/draft-ietf-wimse-aims/)
(2026-11-02, WG document) gives agent auth practice. It composes WIMSE, OAuth
delegation, token exchange and transaction tokens, and it defines no new
protocol. It was adopted from
[draft-klrc-aiagent-auth-03](https://datatracker.ietf.org/doc/draft-klrc-aiagent-auth/).

**Agent on-behalf-of drafts.** The datatracker lists more than 50 individual
agent-identity drafts from 2026
([API query](https://datatracker.ietf.org/api/v1/doc/document/?type=draft&name__contains=agent)).
The ones that matter here:
- [draft-oauth-ai-agents-on-behalf-of-user-02](https://datatracker.ietf.org/doc/draft-oauth-ai-agents-on-behalf-of-user/):
  `requested_actor` and `actor_token`. Individual, **expired** 2026-02-27.
- [draft-ietf-oauth-identity-chaining-17](https://datatracker.ietf.org/doc/draft-ietf-oauth-identity-chaining/)
  (2026-11-12): in the RFC Editor queue. It covers cross-domain chaining with
  token exchange plus the RFC 7523 JWT grant.
- [draft-ietf-oauth-identity-assertion-authz-grant-06](https://datatracker.ietf.org/doc/draft-ietf-oauth-identity-assertion-authz-grant/)
  ("ID-JAG", Cross-App Access): WG draft.
- [draft-ietf-oauth-delegate-sd-jwt-00](https://datatracker.ietf.org/doc/draft-ietf-oauth-delegate-sd-jwt/)
  (2026-10-30): WG draft, "particular applicability to Agentic systems".
- [draft-araut-oauth-transaction-tokens-for-agents-03](https://datatracker.ietf.org/doc/draft-araut-oauth-transaction-tokens-for-agents/):
  individual; adds `agentic_ctx` and keeps `sub`/`act` immutable.

**MCP authorization.** The current revision is
[2026-07-28](https://modelcontextprotocol.io/specification/versioning).
[Authorization](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)
is OAuth 2.1 with RFC 9728 resource metadata, RFC 8707 resource indicators and
Client ID Metadata Documents, and the server must check the audience. An MCP
server "MUST NOT pass through the token it received"; upstream calls use a
separate token
([security considerations](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/security-considerations)).
Token exchange fits that requirement [inferred].

**OpenTelemetry.** `user.id`, `user.name` and `user.roles` are in the main
registry at `development` stability
([registry](https://github.com/open-telemetry/semantic-conventions/blob/main/model/user/registry.yaml)).
`enduser.*` moved to the client-side repo and is deprecated in the main
registry ([file](https://github.com/open-telemetry/semantic-conventions/blob/main/model/enduser/deprecated/registry-deprecated.yaml)).
The latest semconv release is [v1.45.0](https://github.com/open-telemetry/semantic-conventions/releases),
2026-11-02. Baggage is unauthenticated, and the API warns against leaking it to
untrusted processes
([baggage API](https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/baggage/api.md)).
W3C Baggage is a [Candidate Recommendation Snapshot, 2024-05-30](https://www.w3.org/TR/baggage/).
It suits attribution only.

## 2. Products

**Authentik 2026.8** (we run 2026.8.0)
- **Token exchange is shipped.** RFC 8693 is opt-in per provider, in both
  impersonation and delegation (OBO) mode. OBO is marked `2026.8`. The issued
  JWT carries `sub` (the user) and `act.sub` (the Actor). Subject tokens are
  verified through the JWT-federation trust. `audience` selects another
  provider. `resource` is refused. The subject must pass the target
  application's policy bindings
  ([doc at tag](https://github.com/goauthentik/authentik/blob/version/2026.8.0/website/docs/add-secure-apps/providers/oauth2/token_exchange.md)).
- **Actor parent rule.** An Actor with a parent may act only for that parent.
  The actor must be an `Actor`; ordinary users and plain service accounts are
  rejected (same doc). This is a built-in `may_act`.
- **Actors are effectively Enterprise.** The `Actor` model is in MIT core
  ([models.py](https://github.com/goauthentik/authentik/blob/version/2026.8.0/authentik/core/models.py#L1600-L1614)).
  The supported way to create one is the Enterprise Agents API
  ([agent-accounts.md](https://github.com/goauthentik/authentik/blob/version/2026.8.0/website/docs/users-sources/user/account-types/agent-accounts.md),
  `authentik_enterprise: true`). By default an Agent MIRRORs its parent's
  policy engine "so it can never exceed the access of the user it acts for"
  ([agents/models.py](https://github.com/goauthentik/authentik/blob/version/2026.8.0/authentik/enterprise/agents/models.py)).
  Open issue [#27386](https://github.com/goauthentik/authentik/issues/27386)
  asks for a core API and a Terraform resource. Enterprise costs $5 per
  workforce user per month; agent and service accounts are included
  ([pricing](https://goauthentik.io/pricing/)). That breaks zero spend.
- **After 2026.8.0, on main.** Chained `act` was merged 2026-10-19
  ([#26668](https://github.com/goauthentik/authentik/pull/26668)). SAML token
  exchange was merged 2026-10-26 ([#27135](https://github.com/goauthentik/authentik/pull/27135)).
  The ID-JAG PR [#26973](https://github.com/goauthentik/authentik/pull/26973)
  was closed without merge.
- **M2M JWT federation.** `client_credentials` accepts a JWT signed by a
  Federated OIDC Source. Projected Kubernetes SA tokens are documented to
  work, provided the cluster exposes its issuer discovery or JWKS
  ([machine_to_machine.mdx](https://github.com/goauthentik/authentik/blob/version/2026.8.0/website/docs/add-secure-apps/providers/oauth2/machine_to_machine.mdx)).
- **Scoped impersonation already exists.** The impersonate endpoint accepts
  either the object-level `authentik_core.impersonate` on the target user or
  the global permission
  ([users.py L1041-1072](https://github.com/goauthentik/authentik/blob/version/2026.8.0/authentik/core/api/users.py#L1041-L1072)).
  `test_impersonate_scoped` covers this
  ([tests](https://github.com/goauthentik/authentik/blob/version/2026.8.0/authentik/core/tests/test_impersonation.py#L68)).
  The Terraform resource `authentik_rbac_permission_role` takes `model` and
  `object_id`
  ([provider doc](https://registry.terraform.io/providers/goauthentik/authentik/latest/docs/resources/rbac_permission_role)).
  For the `svc-agent` trigger, drop the global permission. Give each operator,
  in their own session, a role with object permissions on the users in a
  chosen group, generated with `for_each` [inferred]. The endpoint has no
  policy hook, so membership changes need a Terraform apply [source: same
  code].
- **authentik Agent** (a device agent, not Agent accounts). It provides kubectl
  credentials on kubeadm
  ([k8s.mdx](https://github.com/goauthentik/authentik/blob/version/2026.8.0/website/docs/endpoint-devices/authentik-agent/device-authentication/cli-app-authentication/k8s.mdx),
  since 2025.12.0) and SSH authentication with sudo decisions
  ([ssh-authentication.mdx](https://github.com/goauthentik/authentik/blob/version/2026.8.0/website/docs/endpoint-devices/authentik-agent/device-authentication/ssh-authentication.mdx)).
  Local device login is Enterprise
  ([features](https://github.com/goauthentik/authentik/blob/version/2026.8.0/website/docs/enterprise/enterprise-features.md)).
  LDAP and RAC outposts authenticate the user directly and carry no actor
  concept [inferred].

**Vault and OpenBao**
- **Identity tokens.** Vault signs OIDC JWTs for the caller's entity: `sub` is
  the entity ID, and templates add entity name, groups and metadata
  ([doc](https://developer.hashicorp.com/vault/docs/secrets/identity/identity-token)).
- **JWT auth.** `bound_claims`, `user_claim` and `claim_mappings` accept JSON
  Pointer, so `/act/sub` can be bound or copied into token metadata, which is
  audited ([doc](https://developer.hashicorp.com/vault/docs/auth/jwt)).
- **Kubernetes secrets engine.** It mints SA tokens with a TTL, or generates
  the SA, role and binding itself. `name_template` supports `{{.DisplayName}}`
  ([doc](https://developer.hashicorp.com/vault/docs/secrets/kubernetes),
  [API](https://developer.hashicorp.com/vault/api-docs/secret/kubernetes),
  [templating](https://developer.hashicorp.com/vault/docs/concepts/username-templating)).
  So the apiserver audit log would show an SA named after the Vault login, for
  example `oidc-emo-…` [inferred].
- **SSH CA.** `allowed_users_template` accepts identity templates, and
  `key_id_format` accepts `{{token_display_name}}`
  ([API](https://developer.hashicorp.com/vault/api-docs/secret/ssh)).
- **Scoped impersonation.** A token role's `allowed_entity_aliases` (globs
  allowed) lets a caller mint a token bound to a named alias
  ([API](https://developer.hashicorp.com/vault/api-docs/auth/token)). Entity
  policies are then added at request time
  ([identity](https://developer.hashicorp.com/vault/docs/concepts/identity)),
  so the token carries emo's permissions.
- **Audit.** Configured request headers are audited
  ([API](https://developer.hashicorp.com/vault/api-docs/system/config-auditing)),
  so a `txn` id can be recorded.
- **Licences.** Vault 1.15 and later is BSL 1.1. The Additional Use Grant
  allows production use except a competitive offering
  ([LICENSE](https://github.com/hashicorp/vault/blob/main/LICENSE)), so a
  homelab is fine. OpenBao is MPL-2.0
  ([LICENSE](https://github.com/openbao/openbao/blob/main/LICENSE), v2.7.2,
  2026-10-26) and documents the kubernetes, ssh and identity engines
  ([docs tree](https://github.com/openbao/openbao/tree/main/website/content/docs/secrets)).

**Teleport.** The source is AGPL-3.0. Community binaries use a modified Apache
2.0 limited to organisations under 100 employees and under $10M revenue
([README](https://github.com/gravitational/teleport#license),
[LICENSE-community](https://github.com/gravitational/teleport/blob/master/build.assets/LICENSE-community)),
which a homelab meets. The [feature matrix](https://goteleport.com/docs/feature-matrix/)
lists Community SSO as GitHub only, so Authentik OIDC needs Enterprise. It
marks per-agent certificates, agent-to-owner linkage and short-lived agent
credentials ✖ for Community. MCP enrollment, MCP RBAC and per-tool audit are ✔.
Access requests are CLI only. MCP servers can receive Teleport-signed JWTs with
user identity ([MCP docs](https://goteleport.com/docs/enroll-resources/mcp-access/)).
The latest stable release is v18.10.0, 2026-07-09
([releases](https://github.com/gravitational/teleport/releases)).

**Pomerium.** Core is Apache-2.0, v0.34.1, 2026-11-11
([releases](https://github.com/pomerium/pomerium/releases)). It re-mints a JWT
in `X-Pomerium-Jwt-Assertion` and never forwards the IdP token
([identity](https://www.pomerium.com/docs/capabilities/getting-users-identity)).
TCP is tunnelled through `pomerium-cli`
([TCP](https://www.pomerium.com/docs/capabilities/tcp)). Native SSH issues
ephemeral certificates and has a Core config. On SSH, the `groups` criterion
is Enterprise-only
([SSH](https://www.pomerium.com/docs/capabilities/native-ssh-access)).
Kubernetes access goes through an SA with `impersonate`
([k8s](https://www.pomerium.com/docs/capabilities/kubernetes-access)). An MCP
gateway and upstream OAuth bridge exist
([MCP](https://www.pomerium.com/docs/capabilities/mcp)). Service accounts and
Original User Context (`X-Pomerium-Jwt-Assertion-For`) are Enterprise
([1](https://www.pomerium.com/docs/capabilities/service-accounts),
[2](https://www.pomerium.com/docs/capabilities/original-request-context)).
Impersonation runs through the Enterprise Console
([doc](https://www.pomerium.com/docs/capabilities/impersonation)).

**SPIFFE/SPIRE.** Both are CNCF graduated
([landscape](https://github.com/cncf/landscape/blob/master/landscape.yml)).
SPIRE is at v1.16.0, 2026-11-05. They identify workloads only; user context
rides beside them in a token (WIMSE arch, AIMS). [draft-ietf-oauth-spiffe-client-auth-03](https://datatracker.ietf.org/doc/draft-ietf-oauth-spiffe-client-auth/)
lets an SVID authenticate as an OAuth client. Authentik's federation of
Kubernetes SA tokens already covers that role here [inferred].

**Tailscale / Headscale.** Headscale v0.29.7 (2026-10-30) supports ACLs,
grants, Tailscale SSH and node attributes. OIDC groups cannot be used in ACLs
([features](https://github.com/juanfont/headscale/blob/main/docs/about/features.md)).
Its changelog shows `app` grants and `tailscale whois`
([CHANGELOG](https://github.com/juanfont/headscale/blob/main/CHANGELOG.md)).
[tsidp](https://github.com/tailscale/tsidp) v0.0.20 is experimental and
BSD-3. It does RFC 8693 behind `-enable-sts` and is gated by the
`tailscale.com/cap/tsidp` app capability. Limit: WhoIs names the node's owner.
The devvm is one node shared by all users, so it cannot tell emo from Viktor
[inferred].

**Kubernetes 1.35.** Structured authentication config has been GA since 1.34
([gate](https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/)).
CEL `claimMappings.extra` can copy `claims.act.sub` into `user.extra`
([authn](https://kubernetes.io/docs/reference/access-authn-authz/authentication/)).
Audit events record `user` and `impersonatedUser`
([audit v1](https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/)).
`ConstrainedImpersonation` is alpha and off by default in 1.35, beta in 1.36.
It adds verbs such as `impersonate:user-info` and
`impersonate-on:user-info:<verb>`
([KEP-5284](https://github.com/kubernetes/enhancements/tree/master/keps/sig-auth/5284-constrained-impersonation)).
Pinniped is Apache-2.0, v0.48.0. jetstack/kube-oidc-proxy is archived, and the
[Tremolo fork](https://github.com/TremoloSecurity/kube-oidc-proxy) is at
v1.0.12. Our apiserver already runs structured authn with two Authentik issuers, and OIDC login works
(`docs/runbooks/apiserver-oidc-agent-identity.md`). The June 2026 rejection was a stray static-pod
manifest, fixed 2026-06-06. A third issuer that prefixes agents with `agent:` is landed but switched
off (`var.agent_oidc_enabled`). The blocker for options 2 and 4 is adoption, not the apiserver:
Viktor, agents and cron jobs still use the shared `kubernetes-admin` certificate.

**Linux auditd.** `pam_loginuid` sets loginuid at entry points such as login,
sshd and cron ([man](https://man7.org/linux/man-pages/man8/pam_loginuid.8.html)).
`auditctl --loginuid-immutable` makes it tamper-proof; changing it needs
`CAP_AUDIT_CONTROL`
([man](https://man7.org/linux/man-pages/man8/auditctl.8.html)).
[measured] auditd is inactive. Every T3-launched agent runs with loginuid
4294967295 (unset): T3 runs as the system unit `t3-serve@<user>.service`, with
no PAM session. systemd `PAMName=` registers a unit as a PAM session
([systemd.exec](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html)).
With a stack that includes `pam_loginuid`, agent processes would carry the
owner's auid [inferred]. auid tags the OS user, so it cannot tell an agent from
its human; the ADR-0025 session id still has to supply that.

## 3. Policy engines for "may impersonate users they have access to"

| Engine | Model | Licence | Status |
|---|---|---|---|
| [OpenFGA](https://github.com/openfga/openfga) | Zanzibar ReBAC | Apache-2.0 | CNCF incubating, v1.22.1 |
| [SpiceDB](https://github.com/authzed/spicedb) | Zanzibar ReBAC | Apache-2.0 | not CNCF, v1.57.1 |
| [Cedar](https://github.com/cedar-policy/cedar) | policy language, entity hierarchy | Apache-2.0 | CNCF sandbox, 4.14.1 |
| [OPA](https://github.com/open-policy-agent/opa) | Rego | Apache-2.0 | CNCF graduated, v1.22.4 |
| [Cerbos](https://github.com/cerbos/cerbos) | YAML policies, PDP | Apache-2.0 | not CNCF, v0.57.0 |

CNCF status is from [landscape.yml](https://github.com/cncf/landscape/blob/master/landscape.yml).
A ReBAC model in OpenFGA syntax:

```
type user
type group
  relations
    define member: [user]
    define operator: [user]
type account
  relations
    define in_group: [group]
    define can_impersonate: operator from in_group
```

Check: `user:viktor can_impersonate account:emo`. Authentik's impersonate
endpoint cannot call out, so an engine can plug in at only two points:
- a token service or dispatcher that checks before minting [inferred];
- an expression policy bound to the token-exchange target application, which
  Authentik evaluates for the subject user (token-exchange doc). It is
  [unverified] that expression policies can make outbound HTTP.

At our size the same relation fits in Terraform. It reads the Authentik group
members and emits object permissions, so no engine runs [inferred].

## 4. Patterns

- **`sub` = human, `act` = agent.** This is RFC 8693 delegation, Authentik OBO
  and txn-tokens-for-agents. Each resource server applies the human's
  permissions and logs the actor.
- **Agent permissions no greater than the human's.** Authentik Agents with
  MIRROR inherit the parent's policy engine, so the agent's access never
  exceeds the human's. A true intersection, the human's rights AND the agent's
  rights, needs the resource server to check both
  principals. None of our resource servers does that today [inferred].
- **Attenuation.** [Biscuit](https://www.biscuitsec.org/) is Eclipse,
  Apache-2.0, with offline attenuation (spec
  [v3.3](https://github.com/eclipse-biscuit/biscuit), 2024-12-17).
  [Macaroons](https://research.google/pubs/macaroons-cookies-with-contextual-caveats-for-decentralized-authorization-in-the-cloud/)
  are from NDSS 2014. Neither is accepted by kube-apiserver, Vault or Forgejo,
  so either needs our own verifier [inferred].
- **Async hop (emo files an issue and an in-cluster agent works it).** No
  subject token exists at work time, so one of three things must hold:
  - (a) Capture delegation at filing time: emo's session obtains an
    `offline_access` refresh token for the worker Actor. This is heavy, and
    it is the CIBA or deferred-token space
    ([draft-ietf-oauth-deferred-token-response](https://datatracker.ietf.org/doc/draft-ietf-oauth-deferred-token-response/)).
    I found no CIBA support in Authentik.
  - (b) A trusted dispatcher with constrained impersonation. It reads the
    issue author from Forgejo, checks group membership, and mints a Vault
    token for emo's entity alias through `allowed_entity_aliases`. Vault then
    issues emo-named Kubernetes and SSH credentials. This is
    txn-token §8.2 in substance.
  - (c) Forgejo `sudo=` for git actions. It needs an admin token, so it is as
    broad as `svc-agent` today
    ([API usage](https://forgejo.org/docs/latest/user/api-usage/)).
    `ENABLE_REVERSE_PROXY_AUTHENTICATION_API` with `X-WEBAUTH-USER` lets a
    gateway that validates Authentik JWTs present the user to Forgejo
    ([config](https://forgejo.org/docs/latest/admin/config-cheat-sheet/)).

  Option (b) replaces today's single broad Vault reader with per-author
  credentials [inferred].

## Open facts

- Whether an `Actor` created outside the Enterprise Agents API (blueprint or
  shell, with `expiring=False`) works with OSS token exchange. #27386 implies
  it does but calls it unsupported. Not tested.
- Whether #26668 (chained `act`) was backported to a 2026.8.x patch release.
- Whether Authentik expression policies may make outbound HTTP calls.
- Whether tsidp works against Headscale. Not documented.
- Whether Teleport Machine ID (`tbot`) is fully available in Community. The
  feature matrix row did not parse cleanly.
- Whether a Vault k8s-engine SA name built from `{{.DisplayName}}` for OIDC
  logins fits Kubernetes name limits. Not tested.
