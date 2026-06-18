# homelab: a unified infra-ops CLI grown in place from infra/cli

Agents re-derive the same operational command boilerplate every session — mining
51,116 bash commands across 2,225 past sessions showed dense, repeated patterns
(the infra inner-loop alone is ~29%). We are building `homelab`, one CLI encoding
the deterministic, repeated **actions** (not judgment) agents run — composable in
bash, JSON-capable, and discovered progressively via `homelab manifest`. It is
grown **in place** in `cli/` (the existing `infra-cli`), absorbing new verb-groups
alongside the preserved legacy webhook use-cases. Versioned with a `cli/VERSION`
file (the infra repo deploys continuously and does not cut semver tags).

## Considered options

- **Its own top-level repo** (the original plan) — rejected in favour of keeping
  it where the Terraform/Terragrunt and `scripts/tg` it drives already live; the
  Go source isn't git-crypt-encrypted and a provision-time build is unaffected by
  GitOps continuous-deploy.
- **A fresh CLI ignoring infra-cli** — rejected: strands the VPN/DNS/email
  webhook use-cases.
- **Raw kubectl/tg/ssh + skills + MCP only** — kept for everything outside the
  recurring action surface (methodology skills; third-party/owned MCP such as
  phpIPAM, which homelab does NOT duplicate).

## Consequences

- The binary is dual-purpose: the agent-facing `homelab` verb surface AND the
  in-cluster `infra-cli` webhook image. `main()` front-dispatches homelab verbs
  and falls through to the legacy `-use-case` path verbatim.
- Distribution: built from source to `/usr/local/bin/homelab` during devvm
  provisioning (`t3-dispatch` precedent), refreshed by `t3-autoupdate`.
