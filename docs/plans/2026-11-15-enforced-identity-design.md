---
status: draft
plan: true
---

# Every request checked against the person it acts for

Today six paths let a user, their agent or a stranger reach all Vault secrets
or cluster admin with no check on the person. After this change, every path
ends at a server that checks the person, and a person's agent gets the same
rights under its own name.

## In numbers

```numbers
caption: measured on the devvm, Vault, Authentik, Forgejo and the cluster on 2026-11-15
rows:
  - {label: paths to all Vault secrets or cluster admin with no person check, before: "6", after: "0"}
  - {label: ClusterRoleBindings to cluster-admin held by CI or agents, before: "3", after: "0"}
  - {label: accounts that can push to viktor/infra master, before: "4", after: "3"}
  - {label: users that svc-agent can impersonate, before: "25, admins included", after: "members of one group"}
  - {label: "audit identities for Viktor, his agents and his jobs", before: "1 shared cert", after: "1 per person, agent and job"}
  - {label: devvm users who reach every LAN service port, before: "4", after: "2 admins"}
  - {label: Woodpecker admins, before: "Viktor and every namespace-owner", after: "Viktor"}
```

The six paths: the ttyd header, emo's docker group, Woodpecker's `default`
service account, the shared ExternalSecrets store, the claude-agent pod, and
openclaw's cluster-admin binding.

## The system, with the change on it

```topology
caption: who acts, where the rights come from, and where each request is checked
direction: LR
groups:
  - {id: devvm, label: devvm}
  - {id: idp, label: identity}
  - {id: cluster, label: cluster}
nodes:
  - {id: person, label: person in a shell, group: devvm, state: same}
  - {id: agent, label: "the person's agent", note: "own name, same rights", group: devvm, state: changed, risk: medium}
  - {id: guard, label: devvm guards, note: "ttyd proxy secret, rootless Docker, per-user firewall", group: devvm, state: new, risk: high}
  - {id: cert, label: shared admin cert, note: break-glass only, group: devvm, state: changed, risk: medium}
  - {id: groups, label: Authentik rights groups, note: not superuser, group: idp, state: new, risk: medium}
  - {id: tf, label: Terraform projection, note: "groups to RBAC, Vault, Forgejo, impersonation", group: idp, state: new, risk: medium}
  - {id: vault, label: Vault, note: "group policies, AppRole for CI, token roles per tier", group: idp, state: changed, risk: high}
  - {id: k8s, label: kube-apiserver, note: "group bindings, agent issuer", group: cluster, state: changed, risk: high}
  - {id: wp, label: Woodpecker, note: "no rights on default, secrets per repo", group: cluster, state: changed, risk: high}
  - {id: eso, label: ExternalSecrets, note: one store per tenant, group: cluster, state: changed, risk: high}
  - {id: bots, label: in-cluster agents, note: "dispatcher per author, openclaw scoped", group: cluster, state: changed, risk: high}
  - {id: forgejo, label: Forgejo, note: teams and push lists from groups, group: cluster, state: changed, risk: medium}
edges:
  - {from: groups, to: tf, state: new, label: membership}
  - {from: tf, to: vault, state: new}
  - {from: tf, to: k8s, state: new}
  - {from: tf, to: forgejo, state: new}
  - {from: person, to: k8s, state: changed, label: OIDC}
  - {from: agent, to: k8s, state: new, label: "agent: issuer"}
  - {from: agent, to: vault, state: new, label: OIDC role agent}
  - {from: agent, to: guard, state: new}
  - {from: bots, to: vault, state: new, label: token for the author}
  - {from: wp, to: vault, state: changed, label: infra repo only}
  - {from: eso, to: vault, state: changed, label: tenant path only}
checks:
  - {node: guard, text: "as emo, a request with a forged X-Authentik-Username gets 407", status: open}
  - {node: guard, text: "as emo, docker run of LibreOffice works and -v /:/h cannot read /home/wizard", status: open}
  - {node: wp, text: a pipeline pushed to viktor/tv cannot log in to Vault or list secrets, status: open}
  - {node: eso, text: an ExternalSecret in plotting-book for secret/viktor is refused, status: open}
  - {node: vault, text: "emo's agent token reads secret/emo and is refused on secret/viktor", status: open}
  - {node: k8s, text: "kubectl auth whoami in an agent session shows agent:vbarzin@gmail.com", status: open}
  - {node: bots, text: an issue filed by ebarzin runs with emo's agent rights and no infra-agent token, status: open}
  - {node: forgejo, text: the Gitea provider plans team members on Forgejo with no diff, status: open}
  - {node: guard, text: "as emo, 10.0.20.204:8554 is refused and Traefik 443 works", status: open}
  - {node: tf, text: svc-agent impersonates a group member and is refused on a non-member, status: open}
left_out:
  - Authentik Enterprise Actors and Vault Enterprise agent registry, both paid
  - OpenFGA as a live ACL service
  - Teleport and Pomerium, whose agent and impersonation features are paid
  - Agents as separate OS users
  - Trusted and untrusted Woodpecker agents; per-repo secrets do the same job
```

## Decisions

```decision
- question: What is the bar?
  options:
    - {name: attribution only, note: records who acted and stops nothing}
    - {name: server-side enforcement, chosen: true}
  why: Viktor wants users unable to step past their rights by accident.
- question: Where does the list of who can do what live?
  options:
    - {name: Authentik groups projected by Terraform, chosen: true}
    - {name: self-hosted OpenFGA, note: "a new service, and each system still needs its own rules"}
  why: Every system already reads Authentik, and Terraform owns the rest.
- question: What may a person's agent do?
  options:
    - {name: "the same as the person, under its own name", chosen: true}
    - {name: a strict subset, note: more rules to keep}
  why: It matches how agents work today.
- question: Do the rules bind Viktor?
  options:
    - {name: "yes, the shared cert is break-glass only", chosen: true}
    - {name: no, note: his actions stay mixed with his agents and jobs}
  why: The audit log must name who acted.
- question: What replaces emo's docker group?
  options:
    - {name: rootless Docker per user, chosen: true}
    - {name: native LibreOffice only, note: breaks his Postgres tests and image builds}
  why: His other Docker work keeps running, without root.
- question: How does emo change viktor/infra?
  options:
    - {name: "pull requests from a fork, merged by Viktor", chosen: true}
    - {name: direct pushes to master, note: CI applies every push as admin}
  why: A write to viktor/infra is cluster admin through CI.
- question: How does a pipeline get credentials?
  options:
    - {name: "secrets set per repo; the namespace default account has no rights", chosen: true}
    - {name: trusted and untrusted agents, note: v3.19 global agents still take viktor workflows}
  why: Woodpecker already refuses a step-chosen service account, so default is the only one.
- question: How do the rights groups relate to Authentik admin?
  options:
    - {name: new non-superuser groups for Vault and cluster rights, chosen: true}
    - {name: reuse authentik Admins, note: "it is superuser, so an agent in it is an Authentik admin"}
  why: An agent must never be an Authentik superuser.
- question: How does an agent appear on Forgejo and web apps?
  options:
    - {name: "as the person: a scoped token, and the person's browser logins", chosen: true}
    - {name: a second account per person, note: needs custom team sync and a second login}
  why: Both systems already check the person, so the rights hold.
- question: How is a Forgejo user tied to a person?
  options:
    - {name: a Terraform map from Forgejo username to Authentik user, chosen: true}
    - {name: Authentik login on Forgejo, note: "off, because its email username breaks sign-up"}
  why: The map is explicit, and unmapped users get no rights.
- question: How does an agent act for an issue author?
  options:
    - {name: a dispatcher mints a Vault token for the author's tier, chosen: true}
    - {name: one shared agent identity, note: "what we have, and it reads everything"}
  why: Vault token roles bind a token to one entity alias, for free.
```

## How it works

**One list.** New Authentik groups carry each right: `vault-admins`,
`kubernetes-admins`, `kubernetes-power-users` and one `namespace-owner-<ns>`
per namespace. None is superuser. Terraform reads them and writes Kubernetes
group bindings, Vault external-group policies, Forgejo teams and push lists,
and impersonation object permissions. The per-person bindings go.

**Agent identities.** In an agent session, the start hook points kubectl at
the `agent:` issuer and logs Vault in through an OIDC role named `agent`.
Each `agent:` group binding equals its human binding. Forgejo and web apps
see the person.

**Pipelines.** The `default` account in `woodpecker` loses its rights and its
token mount. Each repo gets only its own secrets. The infra repo gets a Vault
AppRole for the `ci` role. An app repo gets its namespace deployer from the
Vault Kubernetes engine.

**Tenants.** The `vault-kv` store serves platform namespaces only. Each tenant
namespace gets a SecretStore limited to `secret/<tenant>/*`. Kyverno refuses
any other store in a tenant namespace.

**The issue hop.** The dispatcher maps the issue author through the Forgejo map.
It mints a Vault token for that person's agent tier, and the pod holds nothing
else. The agent reads comments from mapped users only. The keys baked into the
pod move to Vault paths that only the Viktor tier reads. Each `/execute` caller
gets its own named token role.

**The devvm.** ttyd and the other loopback services check the proxy secret or
listen on a socket. nftables matches `meta skuid`: non-admin users reach
Traefik, Forgejo SSH, the API server, the registry caches, adb, beads and
Postgres.

## Order of work

```timeline
caption: every step reverts with one commit; none deletes data
steps:
  - {when: 1, what: "ttyd checks the proxy secret; iOS rig and T3 ports gated; ~/.claude 700", rollback: previous terminal-lobby release}
  - {when: 2, what: "emo drops docker in roster.yaml; provisioner removes unlisted groups; rootless Docker with the registry in daemon.json", rollback: re-add the group}
  - {when: 3, what: "emo moves to fork PRs on viktor/infra; Forgejo map and push lists in Terraform", rollback: restore the push list}
  - {when: 4, what: "Woodpecker default account stripped; secrets per repo; AppRole for infra CI; OPEN false; one admin", rollback: restore the binding}
  - {when: 5, what: "vault-kv limited to platform namespaces; tenant SecretStores; Kyverno guard", rollback: drop the store conditions}
  - {when: 6, what: "openclaw and claude-agent RBAC cut to the writes in 30 days of audit log; dispatcher; keys out of the pod", rollback: restore the bindings}
  - {when: 7, what: "rights groups; Vault group policies; k8s group bindings; Forgejo teams; scoped impersonation", rollback: "revert vault, rbac, forgejo and authentik stacks"}
  - {when: 8, what: "agent: issuer on, Vault agent role, session hook", rollback: set agent_oidc_enabled false}
  - {when: 9, what: "Viktor applies through OIDC; the provisioner gets its own token; the cert becomes break-glass", rollback: point KUBECONFIG back at the cert}
  - {when: 10, what: "nftables per-user egress, 7 days log-only, then enforced", rollback: flush the table}
```

## Configuration

```config
- {key: TL_BIND and proxy secret for ttyd, where: terminal-lobby package, old: "0.0.0.0, header trusted", new: "proxy secret checked"}
- {key: extra_groups for emo, where: scripts/workstation/roster.yaml, old: "[docker]", new: "[]"}
- {key: master push whitelist, where: viktor/infra branch protection, old: "ebarzin, infra-agent, renovate-bot, viktor", new: "infra-agent, renovate-bot, viktor"}
- {key: woodpecker-default binding, where: stacks/woodpecker/main.tf, old: "cluster-admin", new: "removed"}
- {key: WOODPECKER_OPEN, where: stacks/woodpecker/values.yaml, old: "true", new: "false"}
- {key: woodpecker_admins, where: stacks/woodpecker/main.tf, old: "Viktor + namespace-owners", new: "ViktorBarzin"}
- {key: vault-kv conditions, where: stacks/external-secrets, old: "none", new: "platform namespaces"}
- {key: openclaw-cluster-admin, where: stacks/openclaw, old: "cluster-admin", new: "scoped role"}
- {key: agent_oidc_enabled, where: stacks/rbac, old: "false", new: "true"}
- {key: authentik_core.impersonate, where: stacks/authentik/agent-service-account.tf, old: "global", new: "per member of Agent impersonatable"}
```

## Commands

```sh
ansible-playbook -i playbooks/inventory.ini playbooks/devvm.yml --check --diff
ansible-playbook -i playbooks/inventory.ini playbooks/devvm.yml
homelab tf apply forgejo
homelab tf apply woodpecker
homelab tf apply vault
homelab tf apply external-secrets
homelab tf apply kyverno
homelab tf apply openclaw
homelab tf apply claude-agent-service
homelab tf apply authentik
homelab tf apply rbac
```
