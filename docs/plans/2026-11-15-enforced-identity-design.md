---
status: executing
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
  - {id: vault, label: Vault, note: "group policies, ci role for infra only, agent role", group: idp, state: changed, risk: high}
  - {id: k8s, label: kube-apiserver, note: "group bindings, agent issuer", group: cluster, state: changed, risk: high}
  - {id: wp, label: Woodpecker, note: "no rights on default, secrets per repo", group: cluster, state: changed, risk: high}
  - {id: eso, label: ExternalSecrets, note: one store per tenant, group: cluster, state: changed, risk: high}
  - {id: bots, label: in-cluster agents, note: "split by rights, openclaw unbound", group: cluster, state: changed, risk: high}
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
  - {from: bots, to: vault, state: changed, label: main pod only}
  - {from: wp, to: vault, state: changed, label: ci-infra only}
  - {from: eso, to: vault, state: changed, label: tenant path only}
checks:
  - {node: guard, text: "as emo, ttyd with a forged X-Authentik-Username, the iOS rig and wizard's T3 get a TCP reset", status: passed}
  - {node: guard, text: "as emo, docker run works rootless and -v /:/h cannot read /home/wizard or /etc/shadow", status: passed}
  - {node: wp, text: "a pipeline in an unmapped repo runs as default, which Vault refuses and RBAC gives nothing", status: passed}
  - {node: wp, text: "a fire-planner pipeline pod runs as ci-deploy-fire-planner and cannot touch another namespace", status: passed}
  - {node: eso, text: "in plotting-book, an ExternalSecret for another path is refused by both stores", status: passed}
  - {node: vault, text: "a token from the Vault agent role carries role=agent and the person's policies", status: open}
  - {node: k8s, text: "kubectl auth whoami in an agent session shows agent:vbarzin@gmail.com", status: open}
  - {node: bots, text: "a broken label by a read-only collaborator starts no run; the shared token gets 401 from the main pod", status: passed}
  - {node: forgejo, text: "forgejo-acl plans with no diff after apply; ebarzin reads viktor/infra and pushes to his fork", status: passed}
  - {node: guard, text: "as emo, a connection to 10.0.20.204:8554 is logged and Traefik 443 is not", status: passed}
  - {node: tf, text: svc-agent impersonates a group member and is refused on a non-member, status: passed}
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
    - {name: "a Kyverno policy sets each step pod's account from Woodpecker's repo label", chosen: true}
    - {name: an AppRole and secrets per repo, note: "a credential to hand out, and edits in 21 app repos"}
    - {name: trusted and untrusted agents, note: v3.19 global agents still take viktor workflows}
  why: Woodpecker drops pipeline labels under its own prefix, so the repo label is trustworthy and no repo changes.
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
    - {name: "one pod per rights tier, and runs start only for labels by writers", chosen: true}
    - {name: a dispatcher mints a Vault token for the author's tier, note: "the minting token sits in the run's own container"}
    - {name: one shared agent identity, note: "what we had, and it read everything"}
  why: Only a separate pod keeps the higher rights out of a run's reach.
```

## How it works

**One list.** Authentik groups carry each right: `vault-admins`,
`kubernetes-admins`, `kubernetes-power-users`, `kubernetes-namespace-owners`
and one `kubernetes-namespace-owner-<ns>` per namespace. None is superuser.
Terraform fills them from `k8s_users`. Kubernetes and Vault bind the groups.
The per-person bindings are gone. Forgejo has no organisation, so it has no
teams: the viktor/infra push list and collaborators are a Terraform list.

**Agent identities.** In an agent session, the start hook points kubectl at
the `agent:` issuer and logs Vault in through an OIDC role named `agent`.
Each `agent:` group binding equals its human binding. Forgejo and web apps
see the person.

**Pipelines.** Woodpecker labels each step pod with its repo. A Kyverno policy
reads that label and sets the pod's account. The infra repo gets `ci-infra`,
the only account the Vault `ci` role trusts. An app repo gets a deployer for its
own namespace. Every other repo gets `default`, which has no rights. Each repo
gets only its own secrets.

**Tenants.** The `vault-kv` store serves platform namespaces only. Each tenant
namespace gets a SecretStore limited to `secret/<tenant>`. External Secrets
applies the store conditions itself.

**The issue hop.** The agent service runs as two pods. The main pod holds the
Viktor tier and takes a token that only his callers hold. The restricted pod
holds no Vault token, no keys and no cluster rights. Callers that read email or
web pages use it. A fixer run starts only for a label by a collaborator with
write access.

**The devvm.** ttyd and the other loopback services check the proxy secret or
listen on a socket. nftables matches `meta skuid`: non-admin users reach
Traefik, Forgejo SSH, the API server, the registry caches, adb, beads and
Postgres.

## Order of work

```timeline
caption: every step reverts with one commit; none deletes data
steps:
  - {when: 1, what: "done: nftables checks the caller's uid for ttyd, the iOS rig and T3; ~/.claude 700", rollback: revert the playbook commit}
  - {when: 2, what: "done: emo leaves docker; the provisioner removes privileged groups the tier does not give; rootless Docker", rollback: re-add the group}
  - {when: 3, what: "done: emo moves to fork PRs on viktor/infra; Forgejo map and push lists in Terraform", rollback: restore the push list}
  - {when: 4, what: "done: repo accounts by Kyverno; default and the agent stripped; repo secrets; OPEN false; one admin", rollback: restore the bindings}
  - {when: 5, what: "done: vault-kv refuses tenant namespaces; tenant SecretStores", rollback: drop the store conditions}
  - {when: 6, what: "done: openclaw loses cluster-admin; git-crypt key out of ConfigMaps; agent service split by rights", rollback: restore the bindings}
  - {when: 7, what: "done: rights groups; Vault group alias; k8s group bindings; scoped impersonation", rollback: "revert vault, rbac and authentik stacks"}
  - {when: 8, what: "agent bindings and Vault agent role done; issuer on and session hook need Viktor's login", rollback: set agent_oidc_enabled false}
  - {when: 9, what: "Viktor applies through OIDC; the provisioner gets its own token; the cert becomes break-glass", rollback: point KUBECONFIG back at the cert}
  - {when: 10, what: "log-only egress since 2026-11-15; enforce after 7 days of logs", rollback: flush the table}
```

## Configuration

```config
- {key: "output chain, meta skuid", where: playbooks/devvm.yml, old: "any local account reaches ttyd", new: "admins only"}
- {key: extra_groups for emo, where: scripts/workstation/roster.yaml, old: "[docker]", new: "[]"}
- {key: master push whitelist, where: viktor/infra branch protection, old: "ebarzin, infra-agent, renovate-bot, viktor", new: "infra-agent, renovate-bot, viktor"}
- {key: woodpecker-default binding, where: stacks/woodpecker/main.tf, old: "cluster-admin", new: "removed"}
- {key: WOODPECKER_OPEN, where: stacks/woodpecker/values.yaml, old: "true", new: "false"}
- {key: woodpecker_admins, where: stacks/woodpecker/main.tf, old: "Viktor + namespace-owners", new: "ViktorBarzin"}
- {key: vault-kv conditions, where: stacks/external-secrets, old: "none", new: "platform namespaces"}
- {key: openclaw-cluster-admin, where: stacks/openclaw, old: "cluster-admin", new: "removed"}
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
