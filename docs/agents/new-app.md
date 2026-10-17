# New first-party app

New apps use the default stack from ADR-0001 (`~/code/docs/adr/0001-default-app-stack.md`):
TanStack Start on Bun, Drizzle on the shared CNPG Postgres, sign-in through
an Authentik OAuth2 application. On the infra side one module call deploys
it: `modules/kubernetes/tanstack_app` (README there). `stacks/tasks` is the
reference caller.

The app's own code starts from the app template (app-kit `template/`, later
exported to `viktor/app-template`), whose `docs/new-app.md` covers the app
side. This page is the infra half.

## Steps

Use the app slug as `<slug>` (a DNS label, e.g. `myapp`) and `<db>` for the
same name with underscores.

1. Seed Vault KV `secret/<slug>` by hand: `better_auth_secret` (random, 32+
   bytes), `oidc_client_id` = `<slug>`, `oidc_client_secret` (random), plus
   any app secrets the stack will map through `app_secret_env`.
2. Database: add `<db> = {}` to `local.app_databases` in
   `stacks/dbaas/modules/dbaas/app_databases.tf`. The next dbaas apply creates
   the role and database once.
3. Password rotation: add an entry to `var.pg_app_roles` in
   `stacks/vault/app_db_roles.tf`, keyed by `<slug>`:
   `<slug> = { username = "<db>", rotation_schedule = "0 10 * * WED", rotation_window = 3600 }`.
   The role is appended to the postgresql connection's `allowed_roles`
   automatically.
4. Stack: create `stacks/<slug>/` with
   - `terragrunt.hcl` including root and depending on `platform`, `vault` and
     `external-secrets` (copy `stacks/tasks/terragrunt.hcl`),
   - `authentik.tf` with the `authentik` provider block and any
     `data "authentik_user"` lookups for admins (copy `stacks/tasks/authentik.tf`),
   - `main.tf` with `image_tag`, `postgresql_host` and `tls_secret_name`
     variables and one `module "app"` call.
5. Apply in order: dbaas, vault, then the new stack (CI does this on push to
   master; check each one landed, see `docs/agents/terraform.md`).
6. CI: register the repo with `scripts/offinfra-onboard`. The template ships
   its own `build.yml` and `.woodpecker/deploy.yml`, which onboarding should
   keep rather than replace; check the script's options before running it.

## Connection budget

Each pod holds a pool of 4 plus 1 LISTEN connection on the shared primary
(`max_connections` 200), and the `migrate` init container holds 1 while it
runs. More replicas, CronJobs or workers multiply this.

## Rotation

tasks stays on `rotation_period = 604800`. New apps use a schedule with a
window: with `rotation_window` set, Vault rotates a missed slot only while
that slot's window is still open, so creating or switching a role outside the
window does not rotate at apply time.
