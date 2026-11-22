# ADR-0044: The public Showcase is retired; the private app Infra replaces it

- Status: accepted
- Date: 2026-11-21
- Supersedes: ADR-0037 (the homelab showcase is generated from live state)
- Related: the design `docs/2026-11-21-infra-map-design.md` in the private Forgejo repo `viktor/infra-map`, `stacks/learn/`, `stacks/turnstile-gate/`, `stacks/pages-publish/`

## Context

Since 2026-10-20 the **Showcase** at `pages.viktorbarzin.me/homelab/` showed the homelab to anyone with the link (ADR-0037). Viktor now wants one homelab page, not two. That page is the app **Infra** (slug `infra-map`, `infra.viktorbarzin.me`). It draws each site as a 3D model with real floor plans, rooms and photos. A family floor plan cannot be public, so the one page is private: Viktor and emo sign in through Authentik.

## Decision

The public Showcase is retired on 2026-11-21, before Infra ships. Viktor chose to remove it now instead of keeping it until the app is live. These parts are removed:

- the Woodpecker cron `showcase` (id 70 on repo 1) and `.woodpecker/showcase.yml`;
- the `/homelab` Caddy carve-out and the `ingress_homelab_showcase` ingress in `stacks/learn`;
- the `showcase-link-previews` rule in `stacks/turnstile-gate`;
- the `showcase` bundle token in Vault `secret/pages-publish` (`bundle_keys`) and the published files under `showcase/homelab/` in `viktor/pages`;
- the `homelab showcase` verbs, the `showcase/` source directory and the `<!-- showcase: ... -->` markers in `docs/architecture/`.

The `/publish-bundle` endpoint of pages-publish stays, because user API tokens use it since 2026-11-12 (ADR-0042). `showcase/hardware.yaml` moves to the `viktor/infra-map` repo.

## Consequences

- There is no public homelab page. A signed-out request for `/homelab/` gets the Authentik sign-in redirect that every other private path on `pages.viktorbarzin.me` gets.
- Until Infra ships, no page shows the homelab as a whole. `home.viktorbarzin.me` (Homepage) still lists the services.
- The long-lived Home Assistant token named `showcase` on ha-sofia is no longer used. It must be revoked in Home Assistant. Vault `secret/showcase` is soft-deleted, so its versions stay recoverable.
- Rollback: revert the removal commit, apply `learn` and `turnstile-gate`, restore the bundle key and the cron, and run the pipeline once.

## Amendment, 2026-11-22: Infra has a Guest view

Viktor asked that a signed-out visitor can use the diagrams. Infra now shows them a Guest view from the open route `/api/guest-snapshot`. It has every drawing and no personal text: no notes, photos, camera feeds, IP or MAC addresses, apartment numbers or alert text. The full Snapshot, photos and camera snapshots stay signed-in only. The `/homelab/` path and the Showcase stay retired. Details are in the design doc in `viktor/infra-map`.
