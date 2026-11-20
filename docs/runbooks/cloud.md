# Runbook: Cloud

Operations for Cloud's console and reconciler in namespace `cloud`. What runs
where, the credentials and the data flow are in
[docs/architecture/cloud.md](../architecture/cloud.md). Project namespaces
(`p-*`), Project roles and databases, and `secret/cloud/<namespace>/*` belong
to Cloud's database (AGENTS.md, "Cloud-owned objects"): this runbook changes
them only through Cloud or for the recovery steps below.

The SQL below runs in the `cloud` database as the superuser:

```sh
PRIMARY=$(kubectl get cluster -n dbaas pg-cluster-v18 -o jsonpath='{.status.currentPrimary}')
kubectl exec -it -n dbaas "$PRIMARY" -c postgres -- psql -U postgres -d cloud
```

## First deploy

1. Seed the console's secrets (next section).
2. Apply `cloud` (`homelab tf apply cloud` from the main checkout, or let CI
   apply it from master). `dbaas` and `vault` already carry the `cloud`
   database and the three static roles (M2).
3. Register the repo with CI (below). The first build pushes both images and
   the Woodpecker deploy sets them. Until then both pods sit in
   `ImagePullBackOff`, and `CloudReconcilerDown` pages after 15 minutes, so
   run step 3 right after step 2.
4. Sign in at `https://cloud.viktorbarzin.me` as Viktor (Cloud Users and Cloud
   Operators).
5. Apply `authentik` after `cloud`. `stacks/cloud` creates the group Cloud
   Users (module.console); `stacks/authentik/cloud-inviter.tf` looks it up
   (`data.authentik_group.cloud_users`) to give `cloud-inviter` its
   onboarding grants, so on a fresh bootstrap its plan fails there until
   `cloud` has run. `cloud` does not wait for `authentik`: the console
   starts without `CLOUD_INVITER_TOKEN` (invites and onboarding answer 503
   until the token exists), and its email claim names Cloud Email Vouched
   by name only. On an existing install either order works.

## Seed the console's secrets

`secret/cloud-console` holds `better_auth_secret`, `oidc_client_id` and
`oidc_client_secret`. Not `secret/cloud`: that is the Project subtree. CI's
Vault role cannot write `secret/*`, so an admin seeds it once, before the first
apply (the plan reads `oidc_client_secret` for the Authentik provider). The
values are generated in the command and go only to Vault. They reach `vault`
on stdin, not as arguments: the devvm is shared, and any user can read a
running process's arguments. `printf` is a shell builtin, so it starts no
process that would show them:

```sh
vault login -method=oidc
vault kv get secret/cloud-console >/dev/null 2>&1 && echo "already seeded" || \
  printf '{"better_auth_secret":"%s","oidc_client_id":"cloud","oidc_client_secret":"%s"}' \
    "$(openssl rand -base64 48)" "$(openssl rand -hex 32)" \
  | vault kv put secret/cloud-console -
```

Cloud B07 adds `webhook_key`, the key each App's Forgejo push webhook
secret derives from (`WEBHOOK_KEY` on the console, through the
`cloud-secrets` ExternalSecret). Seed it before the `cloud` apply that adds
it, since External Secrets fails the sync on a missing property:

```sh
vault kv get -field=webhook_key secret/cloud-console >/dev/null 2>&1 && echo "already seeded" || \
  printf '{"webhook_key":"%s"}' "$(openssl rand -base64 48)" \
  | vault kv patch secret/cloud-console -
```

Rotating `webhook_key` changes every App's webhook secret: deliveries
answer 404 until each owner runs `cloud webhook <project> <app>` again, and
polling deploys meanwhile. One App's secret is rotated with `cloud webhook
<project> <app> --rotate`.

To rotate the client secret,
`printf '{"oidc_client_secret":"%s"}' "$(openssl rand -hex 32)" | vault kv patch secret/cloud-console -`,
then apply `cloud` (the Authentik provider takes the new secret) and wait for
ESO's hourly refresh of `cloud-auth`, or force it with
`kubectl -n cloud annotate externalsecret cloud-auth force-sync=$(date +%s) --overwrite`.
Reloader restarts the console. Rotating `better_auth_secret` signs everyone
out.

## Register the repo with CI

The two workflow files Cloud needs are in this repo, reviewed with the stack:
[docs/architecture/cloud-ci/build.yml](../architecture/cloud-ci/build.yml)
(check, typecheck, both images, on pushes to master only, a newer push cancels
a running build) and
[docs/architecture/cloud-ci/deploy.yml](../architecture/cloud-ci/deploy.yml)
(sets `cloud` and then `cloud-reconciler`). The cloud repo's own files on
2026-11-13 run the full test suite and build and deploy only the console, so
the reconciler would stay in `ImagePullBackOff`.

The onboarding script refuses a clone with uncommitted or staged files, and
with `--keep-workflows` it commits nothing. So register first, then commit the
two files yourself. The mirror is made with Actions off, so the script's first
mirror sync of the old files runs no build.

1. Make the mirror and turn its Actions off. `gh` acts as the PAT's owner, as
   the script does:

```sh
vault login -method=oidc
export GH_TOKEN="$(vault kv get -field=github_pat secret/viktor)"
gh repo create ViktorBarzin/cloud --private \
  --description "One-way mirror of forgejo viktor/cloud. Do NOT commit here (ADR-0002)"
gh api -X PUT repos/ViktorBarzin/cloud/actions/permissions -F enabled=false
```

2. Give the clone an https Forgejo remote. The script finds the remote whose
   URL has `forgejo.viktorbarzin.me` and takes the token from it or from
   `~/.git-credentials`; an `origin` of `git@git.viktorbarzin.me:...` does not
   match. Then bring the clone to a clean, current master:

```sh
cd ~/code/cloud
git remote get-url forgejo >/dev/null 2>&1 || \
  git remote add forgejo https://forgejo.viktorbarzin.me/viktor/cloud.git
git switch master && git status --porcelain   # must print nothing
```

3. Register the repo. It finds the mirror and keeps it private, sets
   `WOODPECKER_TOKEN`, `FORGEJO_GIT_TOKEN` and `SLACK_WEBHOOK`, adds the
   Forgejo push mirror and syncs it, registers the mirror in Woodpecker, and
   sets `WOODPECKER_REPO_ID` and `FORGEJO_REPO`. It ends with "no changes to
   commit — SKIP", which is expected here:

```sh
cd ~/code/infra
scripts/offinfra-onboard cloud --clone ~/code/cloud --visibility private \
  --namespace cloud --deploy "cloud=migrate,cloud" \
  --deploy "cloud-reconciler=reconciler" --keep-workflows
```

4. Turn Actions back on, then commit the two files and push master. The push
   starts the first build of both images, and Woodpecker already knows the
   repo, so the build triggers the deploy:

```sh
gh api -X PUT repos/ViktorBarzin/cloud/actions/permissions -F enabled=true
cd ~/code/cloud
cp ~/code/infra/docs/architecture/cloud-ci/build.yml .github/workflows/build.yml
cp ~/code/infra/docs/architecture/cloud-ci/deploy.yml .woodpecker/deploy.yml
git add .github/workflows/build.yml .woodpecker/deploy.yml
git commit -m "Build both images on master pushes and deploy both"
git push forgejo master
unset GH_TOKEN
```

The push changes no file under `cli/`, so `cli-release.yml` does not run.
Both ghcr packages are private; Kyverno copies `ghcr-credentials` into
`cloud`. Watch the first run end to end: `gh run list -R ViktorBarzin/cloud
--limit 3`, the Woodpecker deploy, then
`kubectl -n cloud get deploy cloud cloud-reconciler -o wide`. The deploy
reports the reconciler's rollout without waiting for it, because the old pod
may first finish a job of up to 3780 s.

## Apply M5

Apply in this order, from the main checkout: `homelab tf apply vault` (the
reconciler's `patch` on `secret/data/cloud/p-*`), `homelab tf apply authentik`
(`secret/cloud/system` keeps the hand-written keys), then
`homelab tf apply cloud` (the email mapping, the two ExternalSecrets and the
new env). Builds stay off.

After the `authentik` apply, check that the key pair is still there:
`vault kv get -format=json secret/cloud/system | jq '.data.data | keys'`
lists `secrets_private_key` and `secrets_public_key`. After the `cloud`
apply, `kubectl -n cloud get externalsecret cloud-reconciler-system
cloud-console-system` shows both `SecretSynced`, and the console has
`SECRETS_PUBLIC_KEY`:
`kubectl -n cloud exec deploy/cloud -c cloud -- bun -e 'console.log(!!process.env.SECRETS_PUBLIC_KEY)'`
prints `true`.

## App-kit K1 rollout (done 2026-11-15)

App-kit milestone A (the cloud repo's `docs/build/kit-a-infra.md`) gave
every App an oauth2-proxy, routed the App's host to its edge only, and
added the `migrate` init container. Every Project runs that shape, and
`stacks/cloud/access_rules.tf` admits no other: an Ingress on
`auth-<app>`, an edge without `CLOUD_EDGE_SECRET`, an oauth2-proxy
proxying to its edge and the Caddyfile without the sign-in check are
refused, and the ingress floor passes nothing from Traefik to oauth2-proxy
pods or from oauth2-proxy pods to edge pods.

Health check. Each command prints nothing when all is well:

- `kubectl get ingress -A -l cloud.viktorbarzin.me/managed=true -o json | jq -r '.items[] | select(.spec.rules[0].http.paths[0].backend.service.name | startswith("auth-")) | .metadata.namespace'`
  lists Projects with an Ingress on the oauth2-proxy.
- `kubectl get deploy -A -l cloud.viktorbarzin.me/component=edge -o json | jq -r '.items[] | select([.spec.template.spec.containers[0].env[].name] | index("CLOUD_EDGE_SECRET") | not) | .metadata.namespace'`
  lists edges without the edge secret.
- `kubectl get deploy -A -l 'cloud.viktorbarzin.me/component in (edge,oauth2-proxy)' -o json | jq -r '.items[] | select((.status.availableReplicas // 0) < 1) | .metadata.namespace + "/" + .metadata.name'`
  lists edge and oauth2-proxy Deployments with no available pod.

A Cloud reconciler from before K1 renders shapes the policies now refuse,
so rolling Cloud back past K1 fails every Project apply. Roll forward
instead. Every re-apply waits for each App's edge and oauth2-proxy, so a
Project whose new pods never become available fails as `edge_not_ready`
and names the App. A failed Project shows in the console; applying its
Project File again retries it.

## Turn on builds

1. Make the tokens in docs/build/m5-infra.md in the cloud repo (table
   "Vault `secret/cloud/system`") and store each one. The value goes in on
   stdin (`key=-`), never as an argument, because the devvm is shared:

   ```sh
   vault login -method=oidc
   for k in github_dispatch_token github_owner_read_token forgejo_read_token forgejo_admin_token; do
     printf '%s: ' "$k"; read -rs v; echo
     printf '%s' "$v" | vault kv patch secret/cloud/system "$k=-"
   done
   unset v
   ```

   `vault kv patch` keeps the other keys. Optional, for the console's
   private-repo check: `github_api_token`, a GitHub token with no
   permissions, the same way. A key not in
   `local.cloud_system_carried_keys` (`stacks/authentik/cloud-apps.tf`) is
   deleted by the next `authentik` apply that changes the secret; add a new
   key there first.
2. Run `scripts/publish-builder.sh` in the cloud repo (m5-infra.md, "Builder
   repo").
3. Force the copies:
   `kubectl -n cloud annotate externalsecret cloud-reconciler-system cloud-console-system force-sync=$(date +%s) --overwrite`.
   Reloader restarts both pods; the reconciler finishes its running job
   first.
4. Set `default = true` on `variable "builds_enabled"` in
   `stacks/cloud/deploy_rules.tf`, commit and apply `cloud`.

To stop builds (the M5 rollback), set it back to `false` and apply. Branch
polling and dispatch stop; Projects, Deploys already made and App secrets
keep working.

An owner whose Forgejo account is local (not made by an Authentik sign-in)
matches only by a verified email on both sides. If Authentik has no social
source or verified path for that person, an admin sets
`cloud_apps_email_vouched: true` in the user's attributes in Authentik, only
for an email they know is that person's.

## Push webhooks and Deploy Hooks

`cloud new` registers a Forgejo push webhook on each new App's repo with
the User's own Forgejo token; `cloud webhook <project> <app>` adds it to an
App made before (cloud B07). A delivery makes Cloud check that App's branch
within one build tick (`BUILD_TICK_SECONDS`, 5 s); without it the poller
still finds the push within 30 s to 5 min.

- A push did not deploy at once: in Forgejo, the repo's Settings, Webhooks,
  the hook to `cloud.viktorbarzin.me/hooks/forgejo` lists its recent
  deliveries. 204 is a delivery Cloud verified; 404 means the signature
  did not match (run `cloud webhook <project> <app>` again, which resets
  the secret on the hook) or the App is gone.
- The secrets derive from `webhook_key` in `secret/cloud-console` (above,
  "Seed the console's secrets"); without it the console falls back to
  `better_auth_secret`. Changing either key in use changes every App's
  webhook secret. Deliveries then answer 404 until each owner runs `cloud
  webhook` again; polling deploys meanwhile. One App whose secret may have
  leaked: `cloud webhook <project> <app> --rotate`.
- Rollback of the feature: delete the webhook on the repo. Polling still
  deploys.
- A Deploy Hook URL holds its token, and Traefik's access log keeps request
  paths. If a hook URL leaks, the owner runs `cloud deploy-hook <project>
  <app> --regenerate`; the old URL answers 404 at once.

## Add a Cloud User

The person needs an Authentik account first: their own sign-up, a guest
invite, or one an admin made by hand. Then one Operator action does the
rest, in the console (Operate, Users and Budgets, "Add a User") or the CLI
with an Operator's all-Projects write Access Token:

```sh
CLOUD_TOKEN=cloud_... cloud users add <authentik-username-or-email>
```

Run without `--vouch` first: it shows the account and its email and
changes nothing. Then `--vouch <that email>`, or `--no-vouch`. The console
looks the account up and shows the email before its Add button. It reports
each step: the account joins **Cloud Users** (sign-in); it joins **Cloud
Email Vouched** when you vouch for its email. Cloud refuses a vouch for an
email the account does not have, or that another account also has, and
then changes nothing; Cloud makes the User and its
default Budget; and it asks for the Forgejo link check and prints the
answer. Vouch only for an email you know belongs to that person: the
shared private-App client `cloud-apps` (policy `cloud-apps-active-users`,
`stacks/authentik/cloud-apps.tf`) and Cloud's sign-in claim
(`stacks/cloud/email_claim.tf`) trust a vouched email, and the Forgejo
owner check reads that claim. Without a vouch Authentik refuses the person
at every private App, their own included, with "Request has been denied".
An email that a social sign-in or the passkey sign-up verified is vouched
for already, and the step says so. Running it again is safe: it finishes
what a failed run left and changes nothing that is done. Every run records
a `user.onboard` change (Activity).

After a vouch the person signs in to Cloud again (`cloud login` or the
console), because Cloud reads the vouch from the newest sign-in. Then run
`cloud users add` again to see the Forgejo answer; `forgejo_link` reads
`linked` with the account, `unlinked`, or `checking` (the reconciler has
not answered in 15 seconds). A local Forgejo account (login source 0)
links only by an email verified on both sides: the vouch, and the same
address activated on the Forgejo account (Site Administration, User
Emails, only for an address you know is theirs). An account Forgejo made
at an Authentik sign-in (login source 1) links by its subject.

Operators are not added this way. **Cloud Operators** members are declared
in `stacks/cloud/console.tf` (`admin_user_pks`); add the person's pk there
and apply.

What the console may do in Authentik for this, as `cloud-inviter`
(`stacks/authentik/cloud-inviter.tf`): read accounts (global `view_user`)
and add an account to Cloud Users or Cloud Email Vouched (object
permissions on those two groups). It cannot edit a user or touch another
group. `tests/cloud-deploy.test.sh` fails when `cloud-inviter`'s role gains
or loses a permission, when another file grants that role anything, when
the account or its group `cloud inviters` gains another group or role, or
when that group becomes a superuser group or gets a parent.

### By hand, when Cloud cannot

When `cloud users add` answers `onboarding_unavailable` or
`onboarding_failed` and you cannot wait for the fix:

1. Put the account in **Cloud Users** (Authentik admin, the group's
   Users tab).
2. For an email you know is theirs, put it in **Cloud Email Vouched** too.
   An older vouch, `cloud_apps_email_vouched: true` in the account's
   attributes, still counts; users cannot set either themselves.
3. The person signs in to Cloud, which makes their User and Budget.
4. Check every Cloud User's Forgejo link at once in Cloud's database:
   `INSERT INTO forgejo_links (user_id) SELECT id FROM users WHERE role <>
   'operator' ON CONFLICT (user_id) DO UPDATE SET requested_at = now();`,
   then 10 seconds later `SELECT u.email, l.account, l.error FROM
   forgejo_links l JOIN users u ON u.id = l.user_id;` (`homelab k8s db
   cloud`). `account` names the linked login.

The link lets Cloud check that the owner may read the repo; Cloud then
reads the branch and builds it as `cloud-bot` (below), which sees a private
repo only as a collaborator. `cloud new` (CLI 0.6.0 and later) adds
`cloud-bot` with Read before the first push. A private repo made by hand,
or by `cloud new` before 0.6.0, needs `cloud-bot` added as a Read
collaborator (the repo's Settings, Collaborators); until then `cloud
deploys` says "Cloud's reader account cloud-bot cannot read this private
repo".

Cloud's round-4 end-to-end test hit the vouch: a test account made by hand
had no vouch, so Authentik refused its own private App.

## E2e persona

`persona` is a test account, not a person. Viktor's agents run Cloud's blind
end-to-end tests as it (cloud repo `docs/build/render-parity`, item B00). Its
tests may use only the `cloud` CLI, the console and Cloud's User docs.

| Part | Where | Made by |
|---|---|---|
| Authentik user `persona`, email `persona@viktorbarzin.me`, no password | `stacks/authentik/e2e-persona.tf` | Terraform |
| Group "Agent impersonatable", so `homelab browser ... --as persona` works | `stacks/authentik/agent-service-account.tf` | Terraform |
| Groups Cloud Users and Cloud Email Vouched | Authentik, runtime | `cloud users add persona --vouch persona@viktorbarzin.me --yes` |
| OS user `persona` on the devvm, no supplementary group, home 0700 | `playbooks/devvm.yml`, tag `persona` | Ansible |
| Local Forgejo account `persona` (source 0), email verified; token `cloud-e2e` with `write:repository` and `write:user` | Forgejo, runtime | admin API |
| Credentials: `forgejo_user`, `forgejo_password`, `forgejo_token`, `authentik_user`, `email` | Vault `secret/cloud/persona` | by hand |
| Budget | Cloud's database | Operator `PATCH /api/v1/users/<id>/budget` |

The OS user comes from the playbook, not from `roster.yaml`:

- a roster row gives every non-admin a locked infra clone, a Forgejo fork of
  `viktor/infra` and a kubeconfig, which the tests forbid;
- the roster requires a `tier` and a `k8s_user`, and the persona has neither;
- `t3-membership-sync` comments out every non-admin row whose user is not in
  "T3 Users", and that group admits its members to `t3.viktorbarzin.me`.

The provisioner acts only on roster rows, so it leaves the account alone.
The Forgejo account links to the persona's Cloud sign-in by email: the vouch
from `cloud users add` and the verified address on Forgejo (step 4 of "Add
a Cloud User"). Mail to `persona@` goes to the domain catch-all until the
mailserver has a `persona@` mailbox; "Notifications", step 1, adds it, and
step 5 stores its IMAP password as `imap_password` in `secret/cloud/persona`.

To sign the persona in to the CLI with no person, an admin starts
`sudo -u persona -H cloud login` and approves the device code in the cluster
browser as `persona` (`homelab browser run <script> --as persona`). Its git
login is `~persona/.git-credentials`, mode 0600, written from Vault:

```sh
vault kv get -field=forgejo_token secret/cloud/persona | sudo -u persona -H sh -c \
  'umask 077; read -r t; printf "https://persona:%s@forgejo.viktorbarzin.me\n" "$t" > ~/.git-credentials;
   git config --global credential.helper store'
```

To disable the persona, set `is_active = false` on `authentik_user.persona`
and apply `authentik`. That stops impersonation and every sign-in. Then
revoke its Forgejo token: `DELETE /api/v1/users/persona/tokens/cloud-e2e` as
an admin. Its Projects stay until an Operator deletes them.

## Guest invites

A private App's owner, or an Operator, invites an email from the console
(Invite next to the email) or with `cloud invite <project> <app> <email>`.
Cloud adds the email to the App's allow list and creates a single-use
Invitation, valid 7 days, as the Authentik service account `cloud-inviter`
(`stacks/authentik/cloud-inviter.tf`). The guest opens
`https://authentik.viktorbarzin.me/if/flow/signup-start/`, signs up and types
the code; the account lands in **Cloud App Guests**, which grants nothing
else. Someone who already has an account needs no code: Cloud looks the
email up with the console's membership-reader token
(`AUTHENTIK_READER_TOKEN`, global `view_user`), only adds it to the list and
makes no code.

What holds it:

- `cloud-inviter`'s role has `add_invitation` for codes, plus global
  `view_user` and `add_user_to_group` and `view_group` on Cloud Users and
  Cloud Email Vouched for onboarding ("Add a Cloud User"). Its token is in
  Vault `secret/cloud/inviter` (key `token`), written by the authentik stack.
  The console reads it through ExternalSecret `cloud-console-inviter`
  (`CLOUD_INVITER_TOKEN`); the reconciler's own Vault policy cannot read that
  path. ESO reads it through the shared ClusterSecretStore `vault-kv`, whose
  `eso-reader` policy covers `secret/data/*`, the same as
  `secret/cloud/system`: anyone who may create an ExternalSecret in some
  namespace can read it. Without it the console answers
  `invites_unavailable`.
- `validate-invite-code` accepts a cloud-inviter invitation only with
  `fixed_data` keys exactly `code` and `target_group`, the group Cloud App
  Guests, `single_use` true and an expiry at most 7 days ahead
  (`docs/architecture/authentication.md`, "Cloud guest invite codes"). It
  stamps the accepted invitation's pk on the new account, and
  `assign-invite-group` consumes exactly that one; its fallback lookup by
  code never takes a cloud-inviter invitation. No pipeline runs the guard
  tests: run `python3 -m unittest discover -s stacks/authentik -p 'test_*.py'`
  before any edit to either policy.
- The deny stage `deny-cloud-guest-invite` sits right after the
  InvitationStage of `invitation-enrollment` (order 11) and refuses any
  invitation cloud-inviter made. The list of flows comes from this repo's
  docs, and flows here are partly managed in the UI, so the rollout checks
  the live instance before the console gets the token: every flow that the
  command below lists must be in `local.cloud_invitation_stage_flows` (add
  its slug and the order after its InvitationStage, apply the authentik
  stack again). Do the same if another flow gets an InvitationStage later.
  The check reads only:

  ```sh
  curl -s -H "Authorization: Bearer $(vault kv get -field=tf_api_token secret/authentik)" \
    https://authentik.viktorbarzin.me/api/v3/stages/invitation/stages/ | jq '.results[] | {name, flow_set: [.flow_set[].slug]}'
  ```

- Each owner's Apps get at most 20 codes a day (Cloud's own limit).

Rotate the token: taint `authentik_token.cloud_inviter` and apply the
authentik stack (`homelab tf apply authentik`, from the main checkout). The
apply writes the new key to `secret/cloud/inviter`; ESO refreshes
`cloud-console-inviter` within its 1 h interval (annotate it with
`force-sync=$(date +%s)` to do it now) and Reloader restarts the console. The
old token stops working at the apply, so invites fail until the console has
the new one. A rotation always ends with the purge below. A code works only
in its last 7 days, but an Invitation records no creation time, so a leaked
token can make codes that expire months ahead and wait; rotating the token
leaves them working until they are deleted.

List or revoke outstanding codes: `homelab invite list` shows every code with
its group; `homelab invite revoke <code>` deletes one. To revoke every
cloud-inviter code at once (after every rotation), rotate the token first,
then delete the invitations it made:

```sh
T=$(vault kv get -field=tf_api_token secret/authentik)
A=https://authentik.viktorbarzin.me/api/v3/stages/invitation/invitations
curl -s -H "Authorization: Bearer $T" "$A/?created_by__username=cloud-inviter&page_size=500" \
  | jq -r '.results[].pk' | while read -r pk; do
      curl -s -X DELETE -H "Authorization: Bearer $T" "$A/$pk/"; done
```

Accounts a code already made stay; remove them from Cloud App Guests, or
delete them, in Authentik.

## The Cloud CLI on the devvm

`playbooks/devvm.yml` installs `@viktorbarzin/cloud` for every user at
`devvm_cloud_cli_version` (tag `cloud-cli`), from the Forgejo npm registry the
cloud repo's `cli-release` workflow publishes to. To roll a new CLI out, wait
for that workflow to publish the version, bump the variable, then
`ansible-playbook -i playbooks/inventory.ini playbooks/devvm.yml --check --diff --tags cloud-cli`
and the same without `--check`. Users then run `cloud new <app>` with the
Forgejo token git already holds for them; it needs `write:repository` and
`write:user` (Forgejo checks `write:user` before it creates a repo a user owns).

## Suspended Apps and maintenance pages

A User suspends an App (`cloud suspend`) or turns maintenance on
(`cloud maintenance <p> <app> on`); the cloud repo's B06 renders it. A
suspended App's `app-<app>` runs 0 replicas, and its edge answers every
request 503 with the suspended page; in maintenance the App runs and the
edge answers with the maintenance page. The pages are pinned in
`stacks/cloud/access_rules.tf` (`cloud_edge_pages`) and in the cloud
repo's `modules/app/edge.tf` (`edge_pages`); a change to either text needs
both, applied infra first. An edge ConfigMap refused with "is one Cloud
renders" after a Cloud release means the two differ. To see an App's state
read-only:
`kubectl -n p-<project> get deploy app-<app> -o jsonpath='{.spec.replicas}'`
(0 while suspended) and
`kubectl -n p-<project> get cm edge-<app> -o jsonpath='{.data.Caddyfile}' | grep respond`.
The User resumes it; an Operator does not scale it by hand, since the next
apply would put Cloud's replicas back.

## Deleted Projects: restore and early purge

Since the cloud repo's B28d, a delete is soft. `cloud projects delete <p>`
stops the Project: the reconciler applies it with every App suspended and
no `edge-*` or `auth-*` Deployment and no Ingress, deletes its running
one-off and cron Jobs, and keeps its Postgres, Vault entries, OpenTofu
state, Deploys and images. Its address answers 404. For 7 days
(`PROJECT_RESTORE_SECONDS` on the console, default 604800) its owner can
run `cloud projects restore <p>`, or press Restore under Deleted Projects
on the Projects page. Then the reconciler purges it with the old destroy
(change `project.purge`).

The Budget rule for a held Project (the parity lead's decision,
2026-11-17, so the test suites' create and delete churn fits a Budget):
it counts 0 Projects, 0 CPU and 0 memory, and only its Postgres storage.
Its Postgres leaves the shared 80-connection ceiling too. Its restore
plans again and is refused when the Budget or the ceiling no longer fits.
Its App names stay held and count in the owner's 20 held names
(`HELD_APP_NAMES_MAX`, with the names released in the last 30 days). A
delete that would pass 20 frees the owner's oldest released names, as a
release does, and its Plan names them in a `released_names_freed`
warning. It is refused as `held_names_full` only when the deleted
Projects' App names and this Project's pass 20 alone, and only `--purge`
deletes then. A Project with no Services, and a delete with
`--purge` (`DELETE /api/v1/projects/<p>?purge=true`), are destroyed at
once. Nothing in infra changed for this: the reconciler already deletes
edge Deployments and Ingresses when an App is removed, and may delete
Jobs in Project namespaces.

The held Projects, read-only, in the `cloud` database:

```sql
SELECT slug, deleted_at, purge_after FROM projects
 WHERE deleted_at IS NOT NULL AND purge_after IS NOT NULL AND purged_at IS NULL
 ORDER BY purge_after;
```

A stopped Project, read-only:
`kubectl --context kubernetes-admin@kubernetes -n p-<project> get deploy,ingress,jobs`
shows each `app-<app>` at 0 replicas, no `edge-*` or `auth-*` and no
Ingress.

**Purge early** when a User asks, or to free a held Project's storage: the
owner runs `cloud projects delete <p> --purge`. An Operator can end the
hold instead; the reconciler purges it within `RECONCILE_POLL_SECONDS`
(5 s) and records `project.purge` in the name of whoever deleted it:

```sql
UPDATE projects SET purge_after = now()
 WHERE slug = '<p>' AND deleted_at IS NOT NULL AND purge_after IS NOT NULL AND purged_at IS NULL;
```

**Restore** is the owner's: Cloud has no Operator restore, because a
restore plans against the owner's Budget. To give an owner more time,
move the purge later before it passes:

```sql
UPDATE projects SET purge_after = purge_after + interval '7 days'
 WHERE slug = '<p>' AND deleted_at IS NOT NULL AND purged_at IS NULL;
```

After the purge only the nightly dumps are left; see "Restore a Project
database" below.

**Rolling back** the console and reconciler to a release before B28d:
the old code knows no hold. It never purges a held Project, a re-apply
of one (a Size change, a stop that is retried) renders it running again,
so its address serves again, and its failed stop is retried as a
destroy. Roll forward instead when you can. If you must roll back, purge
the held Projects first: set `purge_after = now()` on all of them (the
`UPDATE` above without the slug), wait until every one has `purged_at`
and its destroy is done (`SELECT slug FROM projects WHERE purge_after IS
NOT NULL AND purged_at IS NULL` returns nothing, and no destroy job is
queued or running), then roll back. Tell their owners first: a purge
cannot be undone. Migration 0031 is additive, so the old release runs on
the new columns. A restore refused with `plan_invalid` and "no longer fits
your Budget" means the owner's other Projects took the room; the owner
frees some, or an Operator raises the Budget.

## Worker and cron Services

A worker Service (the cloud repo's B18) is Deployment `worker-<name>` in
`p-<project>`, component `worker`; a cron Service (B19) is CronJob
`cron-<name>`, component `cron`. Its runs are Jobs: `cron-<name>-<digits>`
from the CronJob controller, and `cron-<name>-m<run id>` for a manual run,
which the reconciler creates. Both kinds run the App's image with a command.

Apply `stacks/cloud` before the first Cloud release that renders them.
Before that apply, the admission policies refuse components `worker` and
`cron`, and the project role has no `cronjobs` right, so every
apply of a Project with a worker or a cron fails. Order: `homelab tf apply
cloud` from the main checkout; check that
`kubectl get validatingadmissionpolicy cloud-managed-cronjob cloud-managed-cron-job`
lists both and that
`kubectl auth can-i create cronjobs.batch -n p-<project> --as=system:serviceaccount:cloud:cloud-reconciler`
answers yes; then deploy Cloud.

Read-only checks:
`kubectl -n p-<project> get deploy,cronjob,job -l 'cloud.viktorbarzin.me/component in (worker,cron)'`
lists them, and `kubectl -n p-<project> get events --field-selector reason=FailedCreate`
shows a run's pod that admission refused. A CronJob or a cron Job refused
by `cloud-managed-cronjob` or `cloud-managed-cron-job` means Cloud rendered
a shape infra does not admit; fix it in the cloud repo, not here. A
scheduled run refused by `cloud-managed-cron-job` shows as a
`FailedCreate` event on the CronJob. A run past 12 hours is stopped
by its deadline (Job condition `DeadlineExceeded`). An Operator does not
create, suspend or delete these by hand: the next reconcile puts them back
as the Project File says.

## Instances and the App's PodDisruptionBudget (B21)

An App runs `instances` pods (Project File, 1 to 3). With 2 or more,
`app-<app>` has a PodDisruptionBudget of the same name with `minAvailable:
1` and `unhealthyPodEvictionPolicy: AlwaysAllow`, so a node drain evicts its
pods one at a time and never waits to evict a pod that is not ready. A
drain does wait to evict an App's last ready pod while its other instance
is not ready (Pending, starting or crashing). The drain script's rollout
restart of the App (cloud repo B10) starts a new pod on another node
first, and the wait ends once a second pod is ready; if it stays unready,
read why with `kubectl -n p-<project> describe pod` and `cloud events`. Read-only:
`kubectl -n p-<project> get pdb app-<app>` (ALLOWED DISRUPTIONS 1 when both
run) and `kubectl -n p-<project> get deploy app-<app> -o jsonpath='{.spec.replicas}'`.
An Operator does not delete the PDB or scale the App by hand; the next
apply puts both back.

Apply `stacks/cloud` from the main checkout before the Cloud release that
carries B21: the reconciler's project role gains `poddisruptionbudgets`,
`cloud-managed-pdb` and the 3-replica cap arrive, and
`cloud-managed-edge-config` admits the edge's new retry lines. In the
other order, the first apply of an App with 2 instances fails on its PDB,
and every running App's new edge ConfigMap is refused with "is one Cloud
renders". The release rolls every App's pods once (`CLOUD_INSTANCE_ID` is
new in the pod template) and every edge once (the Caddyfile changed), each
App in turn as the render digest re-applies its Project.

## Apply B37 and B38 (mail ports, outbound address)

Apply `stacks/cloud` from the main checkout before the Cloud release that
carries B38 (cloud `docs/build/b37-b38-infra.md`). The floor's mail-port
Deny takes effect for every Project at once. Check it from a fixture App:
`/tcp?host=smtp.gmail.com&port=587` times out within 10 s, and
`/tcp?host=1.1.1.1&port=443` connects (smtp.gmail.com does not answer on
443 from anywhere). `cloud help apps` then prints the home address once.

Rollback of the mail-port block: revert the commit that added the Deny to
`cloud_project_egress_floor` and apply `stacks/cloud`. Cloud's Project
policy keeps its own Deny until a Cloud release removes it.

When the home WAN address changes, update `public_ip` in `config.tfvars`
and apply `stacks/cloud` too, so the console shows the new address.

## Apply B15 (Postgres limits)

B15 raises `pg-cluster-v18` to `max_connections` 300, memory 3328Mi
request and 5Gi limit, `cloud_provisioner` to CONNECTION LIMIT 10, and the
alerts to 20 and 80 ([docs/agents/databases.md](../agents/databases.md),
"Connection ceiling"). `max_connections` is a postmaster setting: CNPG
restarts the replica, then the primary, and every homelab app reconnects
within a few seconds.

`stacks/dbaas` cannot be applied from a workstation (it resolves
`vault-active.vault.svc`, in-cluster only). Woodpecker applies it, and
`stacks/monitoring`, in full on the push that changes them
(`PLATFORM_STACKS` in `.woodpecker/default.yml`). So the landing is the
apply:

1. Re-measure the 7-day backend peak:
   `homelab metrics query 'max_over_time(max(sum by (pod)(cnpg_backends_total{pod=~"pg-cluster-v18-.*"}))[7d:1m])'`.
   Above 180, lower the ceiling in the Cloud release to keep 20 spare.
2. Record the before values: `homelab k8s db cloud -- "SHOW max_connections"`
   (200) and `homelab k8s db cloud -- "SELECT rolconnlimit FROM pg_roles WHERE rolname = 'cloud_provisioner'"` (5).
3. In a quiet window: `presence claim db:pg-cluster-v18 --purpose "B15: max_connections 300, rolling restart"`.
4. Land the infra commit on master without `[ci skip]` and watch the
   pipeline that contains it (`homelab ci watch`). Its dbaas step applies
   the whole stack, not only this change; check that its plan holds only
   `null_resource.pg_cluster_v18`, `null_resource.pg_cloud_roles` and
   `kubernetes_config_map.pg_custom_queries`.
5. Wait for both instances: `kubectl -n dbaas get cluster pg-cluster-v18`
   reads `Cluster in healthy state`. Record the after values of step 2
   (300 and 10).
6. Deploy the Cloud release. Its new render applies every Project again,
   which sets each Project role to its Size's limit (nano 4, small 10,
   medium 20; Cloud's later migration 0030 makes nano 5 at each
   Project's next apply).
7. `presence release db:pg-cluster-v18`.

Rollback: migration 0025 has no down path, and the old Cloud code
refuses a Size above 8 (`size_invalid`). So roll forward first: a Cloud
release with a migration that sets the Sizes back to 2, 4 and 8 and the
ceiling to 20, then wait while it applies every Project again (each role
back to 2, 4 or 8). Only then revert the Cloud code, and last revert the
infra commit, which CI applies with the same rolling restart.

## Notifications

Cloud (backlog B04) emails Notifications as `cloud@viktorbarzin.me` and
POSTs signed webhooks; the reconciler sends both. The full steps and live
checks are in cloud `docs/build/b04-infra.md`. In order:

1. Add `cloud@viktorbarzin.me` and `persona@viktorbarzin.me` to Vault
   `secret/platform` `mailserver_accounts`, then
   `scripts/tg apply mailserver -- -replace=module.mailserver.kubernetes_config_map.mailserver_config`.
   A plain apply ignores new accounts (`ignore_changes` on the ConfigMap).
   Each address also needs a self-alias in
   `stacks/mailserver/modules/mailserver/extra/aliases.txt`, or the
   `@viktorbarzin.me` catch-all delivers its mail to `spam@`. Reloader does
   not watch that ConfigMap, and the files are `subPath` mounts, so
   `kubectl -n mailserver rollout restart deploy/mailserver` afterwards
   (about a minute without mail; senders retry).
2. `vault kv patch secret/cloud/system smtp_password=<cloud@'s password>`.
3. Apply `stacks/authentik`, which carries `smtp_password`
   (`cloud_system_carried_keys`); an apply from a branch without that key
   deletes it.
4. Apply `stacks/cloud`: `SMTP_PASSWORD_FILE` and the `SMTP_*` settings on
   the reconciler.
5. For P67: `vault kv patch secret/cloud/persona imap_password=<persona@'s password>`.

Without the password the reconciler logs "email is not set up" at start,
and email deliveries stay pending and fail after 24 hours; webhooks still
go out. To rotate: change the account's password in `mailserver_accounts`
(step 1 with `-replace`), then steps 2 to 4; Reloader restarts the
reconciler.

Debug a delivery: `kubectl -n cloud logs deploy/cloud-reconciler | grep
cloud.notify` shows each failed attempt with the Channel id and the
error, and `cloud notifications channels` shows the User the last result.
A webhook to a host that resolves to a private address is refused by
design, at creation and before every delivery.

### Notifications are stuck

`CloudNotificationsStuck` fires when Cloud's oldest pending notification
email is older than 15 minutes, or no notification pass succeeded for 15
minutes, for 10 minutes. Webhooks alone never fire it: they retry for 24
hours against a User's own endpoint. Check, in order:

1. `vault kv get -field=smtp_password secret/cloud/system` answers. An
   authentik apply from a branch without `smtp_password` in
   `cloud_system_carried_keys` deletes it; patch it back (step 2 above),
   then Reloader restarts the reconciler.
2. The reconciler's log: `homelab logs query '{namespace="cloud",
   container="reconciler"} |= "cloud.notify"'`. "the mail server refused
   it: 535" is a wrong password; "no answer in 60 s" or a connection error
   is the mail server or the path to `mail.viktorbarzin.me:587`; "the
   notification pass failed" is Cloud's database.
3. The mail server: `kubectl -n mailserver get pods`, and the account:
   `kubectl -n mailserver exec deploy/mailserver -c docker-mailserver --
   doveadm user cloud@viktorbarzin.me`.

The metrics are `cloud_notification_oldest_pending_seconds{kind}`,
`cloud_notification_deliveries_failed_total{kind}` (deliveries that gave
up after 24 hours) and
`cloud_notification_pass_last_success_timestamp_seconds`. Pending emails
go out by themselves once sending works again, if they are under 24
hours old.

## Apply B17 (internal Apps)

Apply `stacks/cloud` from the main checkout before the Cloud release that
carries B17: the ingress floor gains the Pass of App pods to internal App
pods (label `cloud.viktorbarzin.me/access=internal`) on TCP 3000. Until it is applied, an internal App's callers time out. Check
it with two fixture Apps in one Project, `a` with `access: internal` and
`b` with `connects: [a]`: `https://a.viktorbarzin.me` answers 404, b's
`/fetch?url=http://app-a.p-<project>.svc.cluster.local/info` answers 200,
and the same `/fetch` from a fixture App in another Project fails to
connect (it needs `FIXTURE_FETCH_ALLOW` set to that URL).

Rollback: revert the commit that added the App-to-App Pass to
`cloud_project_ingress_floor` and apply `stacks/cloud`. Internal Apps then
stop answering their callers; public and private Apps are unaffected.

If Cloud's `APP_PORT` changes, change `cloud_app_port` in the same release.

## CrowdSec and the home address

Project pods leave through the home WAN, so a request from a Project App to
a homelab host through Cloudflare reaches Traefik with the household's
address. Since 2026-11-19 (Viktor's decision, V8 follow-up) probing and
attack scenarios may ban that address. These four log only for it:

- `crowdsecurity/http-crawl-non_statics` and `viktor/distributed-crawl-range`
  (crawl, named in the decision);
- `crowdsecurity/http-429-abuse` and `crowdsecurity/http-403-abuse` (rate
  limits). They are neither probing nor attack, so the lead read the
  decision as log-only for them, the conservative reading for the household.

Evidence: a log-only shadow CrowdSec counted 0 overflows for the address in
3 days (2026-11-16 to 11-19); it was removed with this change.

How it works (`stacks/crowdsec/modules/crowdsec/main.tf`,
`crowdsec_home_log_only_*`, and `lapi-reconcile.sh`):

- The address is in neither the parser whitelist nor the LAPI allowlist
  `trusted-infra`. The value comes from `config.tfvars` `public_ip` and is
  never in git.
- Two postoverflow whitelists on the cluster agents (stages `s00-enrich` and
  `s01-whitelist`) drop the overflows of those four scenarios whose source is
  the address or a registered prefix that holds it. The agent logs each one
  and sends no alert: no decision, no Central API signal.
- Blocklists may not ban the address. Every 5 minutes the
  `crowdsec-lapi-reconcile` CronJob deletes decisions that hold it with
  origin `CAPI`, `lists` or `cscli-import`. It keeps origin `crowdsec` (our
  scenarios) and `cscli` (manual bans). A blocklist ban can last up to 5
  minutes before the CronJob deletes it.
- `docs/agents/security.md`, "Open risk", lists the other effects of leaving
  the allowlist (AppSec 403s, signals).

A ban on the address locks the household and every Project App out of every
homelab host behind Cloudflare for its duration, 4h by default.

```sh
HOME_IP=$(sed -n 's/^public_ip *= *"\([^"]*\)".*/\1/p' ~/code/infra/config.tfvars)

# Overflows that logged only:
homelab logs query '{namespace="crowdsec", container="crowdsec-agent"} |= "home address, log-only scenario"' --since 7d

# Is the address banned? Prints each decision that holds it, an Ip or a
# Range, Central API ones included (--all). Do not use --ip here: it also
# prints every decision of the blocklist imports (16,000+ rows on 2026-11-20).
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions list --all -o raw |
  HOME_IP="$HOME_IP" python3 -c 'import csv,ipaddress,os,sys; h=ipaddress.ip_address(os.environ["HOME_IP"]); [print(r["id"],r["source"],r["ip"],r["reason"],r["expiration"]) for r in csv.DictReader(sys.stdin) if h in ipaddress.ip_network(r["ip"].split(":",1)[1],strict=False)]'

# Which scenario, and from which hosts and paths (household or a Project App).
# --ip also lists every blocklist import, so drop those:
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli alerts list --ip "$HOME_IP" | grep -v import
kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli alerts inspect <id> --details

# Lift a ban: give the value the list shows, the address or the Range.
homelab crowdsec unban "$HOME_IP"
```

A hand-added allowlist entry does not last: the CronJob makes
`trusted-infra` equal to `lapi_allowlist` every 5 minutes.

Verified live on 2026-11-20 after the apply of `stacks/crowdsec` (from the
workstation: Woodpecker pipeline #4183 was killed by the next push, and
#4184 did not apply this stack):

- All 5 agents list `viktor/home-log-only` and `viktor/home-log-only-s00`
  as enabled, and their logs have no error lines.
- `cscli explain` of one access line from the address: the parser
  whitelist leaves it unchanged, and it reaches the
  `http-crawl-non_statics` and `distributed-crawl-range` buckets. Before,
  the whitelist dropped it.
- The CronJob run at 00:50 UTC succeeded: 0 CAPI, lists and cscli-import
  decisions deleted, `trusted-infra` 48 entries with 1 removed, and the
  address is no longer in it.
- The check above found no decision that holds the address among 16,783.

Rollback: revert the commit that removed the address from the whitelist and
the allowlist, then apply `stacks/crowdsec`. The agents restart with the
address whitelisted again, and the CronJob adds it back to `trusted-infra`
within 5 minutes. The revert also recreates the `crowdsec-shadow` instance.
Decisions made before the revert stay until they expire: lift each with
`homelab crowdsec unban <ip|cidr>`.

Follow-up: the crawl alert in
`stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl` still has
a comment about `crowdsec-shadow`. Its `job="crowdsec-agent"` filter is
still correct. Fix the comment with the next change to that stack, because
any change to it applies the whole monitoring stack.

## Restart

The console: `kubectl -n cloud rollout restart deployment/cloud`. It runs 2
pods, preferably on different nodes, with RollingUpdate (maxSurge 1,
maxUnavailable 0), a 10 s preStop sleep and a PodDisruptionBudget of
minAvailable 1, so a restart, a CI rollout or a node drain answers every
request. `tanstack_app` ignores the `restartedAt` annotation the restart
adds, so it leaves no Terraform drift. The reconciler: `kubectl -n cloud delete
pod -l app=cloud-reconciler`. It stays 1 pod with Recreate, so the new pod
starts after the old one is gone; deleting the pod, not `rollout restart`,
keeps its pod template equal to Terraform's.

A node drain (kured or the upgrade chain) first rollout-restarts every
one-pod Cloud Deployment on the node, Apps, edges and oauth2-proxies, so
their new pods start on another node before the drain evicts the old ones:
`docs/runbooks/k8s-node-auto-upgrades.md`, "Cloud drain handoff". Cloud's App
module ignores the `restartedAt` annotation this adds.

On a pod delete, a Reloader restart or a CI rollout, the reconciler finishes
its running jobs, at most one per worker, before it exits (grace period
3780 s). A node drain or
eviction with a shorter grace period cuts the job: the automated node upgrade
drains with `--grace-period=300`. A terminating pod is not scraped, so if the
running job takes longer than 15 more minutes, `CloudReconcilerDown` pages;
silence it before a restart while a long job runs. To see whether one runs:
`SELECT id, project_id, kind, started_at FROM reconcile_jobs WHERE state = 'running';`
A job killed mid-apply is `running` until `RECONCILE_STALE_SECONDS` (600 s)
pass; the next reconciler requeues it, and OpenTofu continues from the state.

## Drain the queue

Let the reconciler work the queue down; it runs `RECONCILER_WORKERS` jobs
at a time (2 once B15's `cloud_provisioner` limit of 10 is applied), never
two of one Project. Rollback to one at a time: set `RECONCILER_WORKERS` to
`1` in `stacks/cloud/deploy_rules.tf` and apply `cloud`. To see it:

```sql
SELECT state, kind, count(*) FROM reconcile_jobs GROUP BY 1, 2;
SELECT id, project_id, kind, attempts, run_after, last_error FROM reconcile_jobs
 WHERE state = 'queued' ORDER BY id;
```

A job for a version that is no longer the Project's desired version is
skipped when its turn comes. To stop jobs from running, for example while
Postgres or Vault is down, stop the reconciler for the duration. First
silence `CloudReconcilerDown` and `CloudReconcileQueueStuck` in Alertmanager
for that long: a stopped reconciler has no `up` series, which the first alert
counts as down, so both page after 15 and 30 minutes. Then
`kubectl -n cloud scale deploy cloud-reconciler --replicas=0`, and bring it back
with `--replicas=1` (Terraform's value). Jobs keep queuing in the meantime and
run when it is back. To drop one job without running it:

```sql
UPDATE reconcile_jobs SET state = 'skipped', finished_at = now(), updated_at = now()
 WHERE id = <id> AND state = 'queued';
```

The Project stays at its applied version and shows as converging until the
User saves a new change.

## Restore a Project database

Every Project Postgres is a database on `pg-cluster-v18` named
`p_<project>_<service>_<hash>`, owned by the role of the same name. The nightly
`postgresql-backup` dumps it in the same pass as every other database, but
into its own directory: `/backup/cloud-per-db/<db>/dump_<ts>.dump`
(`/srv/nfs/postgresql-backup/cloud-per-db/` on the Proxmox host), apart from
the homelab's `/backup/per-db/`. Dumps a User takes on demand are in
`/backup/cloud-manual/<db>/manual_<ts>.dump`, a directory owned by uid 999
that only Cloud's backup Jobs write. Both keep 14 days; the nightly job
deletes older files. Before 2026-11-19 the nightly dumps of `p_*` databases
were in `/backup/per-db/` and age out of it by 2026-12-03.
[restore-postgresql.md](restore-postgresql.md), "Restore Single Database",
has the general steps.

Users restore themselves (cloud B28c): `cloud pg backups <p> <db>` lists
both kinds, and `cloud pg restore <p> <db> --backup <id> --into <new>` adds
a new Postgres through an apply and runs `pg_restore` into it as its own
role. It never writes into the existing database, so first point the User
there. Each backup list, backup, export and restore is a Job the reconciler
runs in namespace `cloud`:

```sh
kubectl -n cloud get jobs -l cloud.viktorbarzin.me/component=pg-restore   # or pg-backups, pg-backup, pg-export
kubectl -n cloud logs job/pg-restore-<9 hex>
```

A Job and its credentials Secret `pg-task-<9 hex>` go 10 minutes after it
ends. A task the reconciler lost track of fails as `task_stale` after 2
hours. The manual dumps directory belongs to uid 999 (the postgres user of
the task image); `postgresql-backup` makes it with that owner on every
run, so a Job that cannot write there means the directory was changed by
hand. Rollback of the task Jobs: delete the `cloud-pg-task` and
`cloud-pg-task-secret` policies with their bindings and the Role `cloud-reconciler-tasks` (in `stacks/cloud`
`pg_backups.tf` and `access_rules.tf`); every task then fails as
`job_refused`, and the nightly dumps keep running. Restores below are the
Operator's way into the existing database.

1. Find the database:
   `SELECT datname FROM pg_database WHERE datname LIKE 'p\_<project>\_%';`
2. Stop the App's writes for the restore: `ALTER ROLE <db> CONNECTION LIMIT 0;`
   then `SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '<db>';`
3. Restore as in `restore-postgresql.md`:
   `pg_restore -d <db> --clean --if-exists <dump>`. The role exists, so
   ownership comes back as it was.
4. Set the limit back to the Size's (nano 5, small 10, medium 20):
   `ALTER ROLE <db> CONNECTION LIMIT <n>;`. The next apply of the Project sets
   it again anyway. A limit above 20 or none pages `CloudProjectRoleUnlimited`.

The size loop measures the database again within 5 minutes.

## State encryption key

Cloud backlog B09. Every Project's OpenTofu state and saved plan is
encrypted with AES-GCM. The key comes from one passphrase in Vault
`secret/cloud/state-key`, field `passphrase`. Of the workload policies only
`cloud-reconciler` reads it: the four broad `secret/data/*` readers in
`stacks/vault/main.tf` (`ci`, `eso-reader`, `openclaw-k8s`,
`terraform-state`) deny it and its metadata, and no workload writes it.
`tests/cloud-state-key.test.sh` checks this against a dev Vault in
seconds, and fails when a new `secret/data/*` reader appears without the
deny. The reconciler reads the key on every job. A missing key, a 403 (the
`vault` stack not applied yet) or one under 32 characters fails the job at
once with `state_key_missing` or `state_key_invalid`, before tofu runs.
Once the key reads back, the reconciler applies every Project that failed
that way again, within a minute; nothing needs requeueing. Vault not
answering is `state_key_unreadable`, which the job retries.

**A lost or changed passphrase is lost state.** Every Project's next apply
then fails with `decryption failed`. Its namespace, database and Vault
entries stay, but Cloud no longer manages them until each is imported by
hand. The backup is Vault itself: the weekly `vault-raft-backup` snapshot,
kept 30 days ([docs/architecture/secrets.md](../architecture/secrets.md),
"Vault Backup"; restore with [restore-vault.md](restore-vault.md)). KV
keeps old versions, so a wrong `kv put` is undone with `vault kv rollback
-version=1 secret/cloud/state-key`. Never run `vault kv metadata delete` on
it. Never rotate it: the reconciler has no second key to read old states
with.

Create it once, before the first release with B09 rolls out. The value goes
from `openssl` to Vault through a pipe, never to the terminal or a file.
`-cas=0` refuses to write when the key exists already:

```sh
vault login -method=oidc
openssl rand -base64 48 | tr -d '\n' | vault kv put -cas=0 secret/cloud/state-key passphrase=-
vault kv get -format=json secret/cloud/state-key | jq '.data.data | keys, (.passphrase | length)'
kubectl -n vault create job --from=cronjob/vault-raft-backup vault-raft-backup-state-key
```

The third line prints `["passphrase"]` and `64`. The job writes a snapshot
with the key at once, so the backup does not wait for Sunday.

**Rolling the reconciler back past B09 is one way.** A reconciler image
from before B09 has no `TF_ENCRYPTION`, so it cannot read an encrypted
state: each of its jobs fails with "This state file is encrypted". Once any
state is encrypted, roll forward with a fix instead of back. To slow the
reconciler without a new image, set `RECONCILER_WORKERS` to `1`.

The release that encrypts applies every Project again (the render digest
holds the encryption scheme). While `RECONCILE_STATE_READ_UNENCRYPTED` is
`true`, the default in `stacks/cloud` `deploy_rules.tf`, a state written
before is read, and every job applies its saved plan even when nothing
changes, because a plan writes no state: the apply writes it encrypted. Jobs log OpenTofu's
warning "Method unencrypted is present in configuration" until then. When
every state is encrypted, set it to `false` and apply `cloud`: tofu then
refuses unencrypted data and never writes it, and a job with nothing to
change skips the apply again. Count the plain states first;
the answer must be empty:

```sh
PRIMARY=$(kubectl get cluster -n dbaas pg-cluster-v18 -o jsonpath='{.status.currentPrimary}')
for s in $(kubectl exec -n dbaas "$PRIMARY" -c postgres -- psql -U postgres -d cloud_state -Atc "select nspname from pg_namespace where nspname like 'p\_%'"); do
  kubectl exec -n dbaas "$PRIMARY" -c postgres -- psql -U postgres -d cloud_state -Atc "select '$s' from $s.states where data::jsonb ? 'resources'"
done
```

## Disaster recovery drill

Cloud backlog B11. The drill shows that the nightly dumps alone can bring
Cloud back: the `cloud` database holds each Project's desired state, and
`cloud_state` holds the OpenTofu state its last apply wrote. The drill
restores both into a scratch Postgres on the devvm and plans every live
Project against them with the cloud repo's `offline-plan` entrypoint
(`src/reconciler/offline-plan.ts`). It never touches the cluster, the
shared Postgres or Vault after it reads the state key.

Run it after a change to the backup job, the state encryption or the
reconciler's render, and once a quarter. Run it before you trust the dumps
in a real restore, too: it takes about a minute.

### Safety rails

- The entrypoint refuses to start unless `DATABASE_URL` and
  `CLOUD_STATE_URL` point at `127.0.0.1` or `localhost` with no query key
  but `sslmode` (libpq would take `host=` from the query), and while
  `KUBERNETES_SERVICE_HOST`, a service account token, a `KUBECONFIG`
  other than `/dev/null` or `VAULT_TOKEN` is present.
- It runs `tofu init`, `tofu state pull`, `tofu plan -refresh=false
  -lock=false` and `tofu show` only. It never applies, and it starts none
  of the reconciler's loops. Do not start the stock reconciler
  (`reconciler.js`) on restored data: its notification loop would send the
  restored outbox's emails and webhooks again.
- OpenTofu gets only `PATH` and the job's own variables, with `HOME` set to
  the job directory, so it finds no kubeconfig. The Vault and Postgres
  provider credentials are empty.
- The state key lives only in a mode-600 file in a mode-700 scratch
  directory. A trap on EXIT deletes the directory, the worktree and the
  container.

### What the Plan covers

Two kinds of resources need a live API even with `-refresh=false`: every
`kubernetes_manifest` (the provider reads the object's OpenAPI schema from
the cluster at plan time) and every data source (OpenTofu reads them on
each plan; Cloud's read Vault). The drill leaves them out with `-exclude`,
and OpenTofu leaves out everything that depends on them. The report lists
each instance it did not compare in `notCompared`. Today that is 11 of 31
per Project: the 7 `kubernetes_manifest` objects (SecretStore,
ExternalSecrets, the Calico policy), the App and oauth2-proxy Deployments,
the oauth2-proxy Service and Vault entry, and `terraform_data.isolation`.
The other 20 are compared: the namespace, quota, limit range,
RoleBinding, service accounts, the edge, the App's Service and Ingress,
the Postgres role, database and password, and the Vault entries.

The report also checks two things across the dumps. `renderDigestMatches`
is true when the build renders what the live reconciler last recorded
(`reconciler_state.render`), so the drill used the same instance settings.
`registryTokenMismatches` lists Projects whose state holds a pull token
whose sha256 is not the one in `reconciler_state.registry_token`.

What the drill does not prove: that the excluded objects match, that the
live cluster still matches the state (that needs a refresh), and that ESO
had synced every App's secrets (the drill assumes it had).

### Commands

The drill builds from a throwaway worktree of the cloud clone at the
release that was live when the dumps were written, so the shared clone
stays on its branch. That is usually the reconciler image now (its tag is
the commit's short SHA:
`kubectl -n cloud get deploy cloud-reconciler -o jsonpath='{..image}'`).
When a release deployed after the dump time, take the one before it from
`gh run list --repo ViktorBarzin/cloud --workflow "Build and Push"`: a
later release renders what the dump does not hold yet, so the drill
exits 3 with changes.
The pinned tofu and provider mirror come from the clone's `.tools/`
(cloud README, "Reconciler"). Run the block in one shell: the trap
removes the container, the worktree, the dumps and the key file however
the block ends.

```sh
SHA=<short sha of the reconciler image>
CLOUD=~/code/cloud BUN=/usr/local/bin/bun
umask 077; D=$(mktemp -d /var/tmp/cloud-dr.XXXXXX)   # mode 700
trap 'docker rm -f cloud-dr-pg >/dev/null 2>&1; git -C "$CLOUD" worktree remove --force "$D/src" 2>/dev/null; rm -rf "$D"' EXIT

git -C "$CLOUD" worktree add --detach "$D/src" "$SHA"
(cd "$D/src" && $BUN install --frozen-lockfile && $BUN run build:entrypoints)

# 1. The newest dumps, read-only from the NFS host
#    (mirrors: /mnt/backup/nfs-mirror/postgresql-backup/ there, and Synology).
for db in cloud cloud_state; do
  f=$(ssh root@192.168.1.127 "ls -t /srv/nfs/postgresql-backup/per-db/$db/dump_*.dump | head -1")
  scp -q "root@192.168.1.127:$f" "$D/$db.dump"
done
ls -l "$D"/*.dump

# 2. A scratch Postgres on 127.0.0.1 only; the server major must be at
#    least the dump's (pg_restore -l prints it).
head -c 24 /dev/urandom | base64 | tr -d '/+=' > "$D/pgpass"
docker run -d --name cloud-dr-pg -p 127.0.0.1:55611:5432 --user root \
  -e POSTGRES_PASSWORD_FILE=/run/pgpass -v "$D/pgpass:/run/pgpass:ro" postgres:18
until docker exec cloud-dr-pg pg_isready -U postgres -q; do sleep 1; done
for db in cloud cloud_state; do
  docker cp "$D/$db.dump" cloud-dr-pg:/tmp/ && docker exec cloud-dr-pg createdb -U postgres $db
  docker exec cloud-dr-pg pg_restore -U postgres -d $db --no-owner --no-acl --exit-on-error /tmp/$db.dump
done

# 3. The state key, straight into a mode-600 file; never printed. The
#    state URL holds the password, so it goes in a file too.
vault kv get -field=passphrase secret/cloud/state-key > "$D/state-key"
printf 'postgres://postgres:%s@127.0.0.1:55611/cloud_state?sslmode=disable' "$(cat "$D/pgpass")" > "$D/state-url"

# 4. The offline Plan. The instance settings are the live reconciler's
#    (stacks/cloud deploy_rules.tf, cloud_reconciler_env).
mkdir "$D/work"
env -i PATH=/usr/bin:/bin HOME="$D/work" KUBECONFIG=/dev/null \
  DATABASE_URL=postgres://postgres@127.0.0.1:55611/cloud DATABASE_PASSWORD_FILE="$D/pgpass" \
  CLOUD_STATE_URL_FILE="$D/state-url" TOFU_STATE_PASSPHRASE_FILE="$D/state-key" \
  TOFU_BIN="$CLOUD/.tools/tofu" TOFU_PLUGIN_DIR="$CLOUD/.tools/providers" \
  RECONCILER_MODULES_DIR="$D/src/modules" RECONCILER_WORK_DIR="$D/work" \
  RECONCILE_STATE_READ_UNENCRYPTED=false \
  VAULT_ADDR=http://vault-active.vault.svc.cluster.local:8200 \
  POSTGRES_HOST=pg-cluster-rw.dbaas.svc.cluster.local \
  EDGE_IMAGE=<local.cloud_edge.image> OAUTH2_PROXY_IMAGE=<local.cloud_oauth2_proxy.image> \
  $BUN "$D/src/.output/entrypoints/offline-plan.js" > "$D/report.json"; echo "exit $?"
jq '{renderDigestMatches, registryTokenMismatches, projects: [.projects[] | {project, result, desiredVersion, appliedVersion, compared, stateResources, changes}]}' "$D/report.json"
# Leaving the shell (or `trap - EXIT; ...` by hand) runs the cleanup.
```

`VAULT_ADDR` and `POSTGRES_HOST` are only rendered into the plan; nothing
connects to them. No password reaches a command line: the scratch
password, the state URL and the key are read from files.

### What success looks like

Exit 0 alone is success: every Project's `result` is `no_changes`,
`renderDigestMatches` is true and `registryTokenMismatches` is empty. The
other codes:

| Exit | Meaning |
|---|---|
| 1 | A Plan failed (`error`, credentials redacted), a Project has no state schema in `cloud_state` (`no_state`), or the drill refused to start (`refused`) |
| 2 | A Plan has changes: read `changes`. A Project whose `desiredVersion` is above its `appliedVersion` was converging when the dump was taken, so changes are expected for it |
| 3 | Every Plan is empty, but a cross-check does not agree: `renderDigestMatches` false (or null: nothing recorded) means the worktree renders other than the release the dumps were taken under, so check out that release; a name in `registryTokenMismatches` holds a pull token the reconciler did not record |

### Result on 2026-11-17

Dumps from 2026-11-17 19:21 UTC, 2 h 12 min old at the copy: `cloud`
1,084,391 bytes, `cloud_state` 304,633 bytes. The restore took 2.1 s with
no errors. `cloud` held 128 Projects, 2 of them live and applied
(`p03-rzhop0`, `p67-5fh7rt`), and `cloud_state` held exactly their 2 state
schemas (serials 13 and 5). The offline Plan took 32 s:
`renderDigestMatches` true, no token mismatch, 20 of 31 instances
compared per Project, exit 2. The first run found one change in each Project:
the edge Deployment's `tier = "4-aux"` label was in the state but not in
the configuration. Kyverno's `sync-tier-label-from-namespace` adds it to
every Deployment without one, so every plan proposed removing it. Cloud
now ignores that label key on every Deployment it renders
(`src/reconciler/kyverno-drift.test.ts`). With that build, the commands above
(106 s, a fresh worktree and build included) gave `no_changes` for both
Projects and exit 3, because `renderDigestMatches` is false: the module
change moves the render digest. The live reconciler applies every Project
once when that release deploys and records the new digest, and the next
drill reads true and exits 0.

### Result on 2026-11-18

After the tier fix deployed (cloud b0afd73, 2026-11-17 22:54 UTC), the
reconciler applied both live Projects once, and both live plans read "No
changes"; no pod restarted. The nightly dumps of 2026-11-18 00:02 UTC
(`cloud` 1,232,403 bytes, `cloud_state` 304,678 bytes) were copied 31 min
later. At 255141a, the release live at the dump time, the commands above
gave exit 0 in 42 s: `renderDigestMatches` true, no token mismatch, and
`no_changes` for `p03-45gh2x` and `p67-5fh7rt` (20 of 31 instances
compared each). At ffe7818, the release deployed 3 min after the dump,
they gave exit 3 with 2 changes per Project (the resource quota, and the
`console_exec` RoleBinding that release adds), which is why the drill
takes the release of the dump time.

## Revoke a token

- **Access Token** (`cloud_...`): its owner revokes it on the console's Access
  Tokens screen or with `cloud tokens revoke <id or name>` after `cloud
  login`. An Operator can revoke any:
  `UPDATE access_tokens SET revoked_at = now() WHERE id = '<id>' AND revoked_at IS NULL;`
  (`SELECT id, user_id, name, created_at, expires_at FROM access_tokens WHERE revoked_at IS NULL;`).
  The API refuses it on the next request. Every token also expires, at most
  90 days after it was made (`expires_at`; the tokens made before cloud
  migration 0021 got 90 days from it), and then answers 401
  `token_expired`. An Access Token cannot make or extend another, and one
  made with `cloud login` (`user_scope`) reaches only its User's own
  Projects, even an Operator's.
- **Device sign-in** (an Authentik JWT): an access token cannot be revoked
  before it expires (15 minutes from `cloud`, 1 hour from `cloud-cli`). Delete
  the person's `cloud-cli` refresh tokens in the Authentik admin (Directory,
  Tokens and App passwords, or `DELETE /api/v3/oauth2/refresh_tokens/<id>/`),
  so the CLI cannot renew. To lock someone out completely, remove them from
  Cloud Users; the API re-checks membership at least every 15 minutes.
- **The console's Authentik reader or approver token** (infra-owned): replace
  it from the main checkout, then commit nothing (the code is unchanged):

  ```sh
  cd ~/code/infra/stacks/cloud
  ../../scripts/tg apply -replace='module.console.authentik_token.membership_reader'
  # approver: -replace='module.console.module.signup.authentik_token.approver[0]'
  ```

  Reloader restarts the console with the new value.

## Recover from a failed apply

`CloudReconcileFailing` fires when a job fails after all 3 attempts, and
stays up for 15 minutes after the last such failure. A failed job keeps `last_error` and `log_excerpt`:

```sql
SELECT j.id, p.slug, j.kind, j.attempts, j.last_error, j.log_excerpt
  FROM reconcile_jobs j JOIN projects p ON p.id = j.project_id
 WHERE j.state = 'failed' ORDER BY j.updated_at DESC LIMIT 10;
```

| Error | Cause | Fix |
|---|---|---|
| `Vault login as role cloud-reconciler answered 403` | the Kubernetes auth role or policy changed | `vault read auth/kubernetes/role/cloud-reconciler`; apply `vault` |
| `password authentication failed for user "cloud_state"` or `"cloud_provisioner"` | a rotation the files have not caught up with | `kubectl -n cloud get externalsecret cloud-reconciler-postgres`; force a sync (annotate `force-sync`) |
| `admission webhook ... denied` / `ValidatingAdmissionPolicy 'cloud-...' denied` | the Project asks for something the policies refuse | the message names the rule; the User changes the Project. A homelab host taken since the last `cloud` apply is refused by `cloud-ingress-live-hosts` |
| `Error acquiring the state lock` | another session holds the pg backend's advisory lock on schema `p_<project>` | see below |
| `already exists` | an object exists in `p-<project>` that the state does not know, after an apply died between create and state write | delete only the object the error names, in that namespace, then requeue |
| `too many connections for role "cloud_provisioner"` | more than 10 connections as the provisioner (two workers hold at most 9) | one reconciler only; check for a second pod or a stray session in `pg_stat_activity`. Before B15's limit of 10 is applied, set `RECONCILER_WORKERS` to `1` |

**State lock.** The pg backend's lock is a Postgres advisory lock held by a
session, so it goes when that session ends. With no job running (see
"Restart"), find the session and end it:

```sql
SELECT pid, application_name, state, backend_start FROM pg_stat_activity WHERE usename = 'cloud_state';
SELECT pg_terminate_backend(<pid>);
```

**Requeue** a failed job once the cause is fixed, or ask the User to save the
Project again:

```sql
UPDATE reconcile_jobs SET state = 'queued', attempts = 0, run_after = NULL, updated_at = now()
 WHERE id = <id> AND state = 'failed';
```

A failed destroy is queued again by the reconciler itself every hour
(`RECONCILE_DESTROY_RETRY_SECONDS`).

## Debug a stuck Project

`CloudProjectStuckConverging`, or a User reports a change that never went
live: [docs/architecture/cloud.md](../architecture/cloud.md), "How to debug a
stuck Project".

## An App reads crashing or unhealthy

The reconciler's health watch reads every live App's pods every 30 s
(every 10 s while one is not healthy) and records an Event when an App
starts crashing, turns unhealthy or recovers. Events are kept 30 days.
`cloud events <project> <app>` lists them with the reason (`exited` and
the exit code, `OOMKilled`, `migrate_failed`, `health_check`,
`not_listening`), and `cloud projects` names the Apps that are not healthy
now. The App's own logs (`cloud logs`) usually say why. To look closer,
read the pod read-only: `kubectl -n p-<project> describe pod -l
cloud.viktorbarzin.me/service=<app>,cloud.viktorbarzin.me/component=app`.
An Event is missing when the reconciler cannot read the namespace (its log
says "cannot read the Project's pods" at debug level) or the Project is
converging: the rollout check judges new pods then.

## A Deploy failed its migrations

Since cloud backlog B16 an App's `migrate` runs once per Deploy, before the
rollout, as Job `app-<app>-m<first 9 hex of the Deploy id>` in
`p-<project>` (component `migrate`). A failure fails the Deploy before the
apply, so the version before keeps serving; `cloud deploys log <project>
<app> <id>` ends with the migrations' output after a `==> migrate` line,
and `cloud logs <project> <app> --deploy <version>` shows their lines. Read
the Job read-only while it lasts (an hour after it ends):
`kubectl -n p-<project> get jobs -l cloud.viktorbarzin.me/component=migrate`
and `kubectl -n p-<project> describe job <name>`. A Job the reconciler gave
up on (its pod never started within 10 min, or ran past
`RECONCILE_ROLLOUT_SECONDS`) is deleted with its pod. A Deploy whose Job
needs a Secret its own apply creates (a Postgres connected in the same
apply) stays `deploying`, and a follow-up apply runs it.

Rollback for one release: set `RECONCILE_MIGRATE_AS=init` on the
`cloud-reconciler` Deployment (`stacks/cloud`, a Terraform change). Each
App's next apply renders the init container `migrate` again, and no Job
starts.

## A one-off job

Since cloud backlog B20 `cloud run <project> <app> -- <command>` runs a
command once as Job `job-<app>-<first 9 hex of the job id>` in
`p-<project>` (component `job`), with the App's live image, env and
secrets. A Project runs one job at a time (`job_running`), and its quota
keeps room for that one job's pod. `cloud jobs <project> <app> [<id>]`
lists the App's last 20 jobs with their exit codes, or prints one with
its output. A job that never ran to an end has no exit code and a
`failure`: `refused` (admission or RBAC refused the Job: check
`cloud-managed-one-off-job` is applied), `quota_full` (a Deploy or
restart in progress held the room; the job may wait up to the 10 min
start cap), `image_pull_failed`, `still_starting`, `timed_out` (it ran
past 1 h, or Cloud did not see it end within 76 min of its start) or
`gone` (its Job was deleted while it ran, or the reconciler never
started it in time). A job pod cannot call an internal App, as a worker
or cron pod cannot. Read the Job read-only while it
lasts (an hour after it ends): `kubectl -n p-<project> get jobs -l
cloud.viktorbarzin.me/component=job` and `kubectl -n p-<project> describe
job <name>`. Cloud has no cancel for a job yet; its deadline ends it
within 71 minutes.

## Shell and psql sessions

Since cloud backlog B22 `cloud shell <project> <app>` runs `sh` in the
`app` container of a ready App pod, and `cloud psql <project> <postgres>`
runs `psql` in a toolbox pod the reconciler starts for that one session
(Job `toolbox-<first 9 hex of the session id>`, component `toolbox`,
image `postgres:18-alpine` pinned in `cloud_toolbox`). Both go through
`pods/exec` as the console's service account `cloud/cloud-console`, which
holds ClusterRole `cloud-console-exec` (pods get and list, pods/exec
get and create) only through RoleBinding `cloud-console-exec` in each `p-*`
namespace, made by Cloud's `modules/project`. Admission policy
`cloud-console-exec` lets it run only `sh` in container `app` and `psql`
in container `toolbox`, in managed `p-*` namespaces. The toolbox holds the
Postgres's own role from Secret `pg-<postgres>`, no Kubernetes token, and
the egress floor lets it reach DNS and the CNPG primary only. A session
lasts at most 1 h and ends after 15 min with no bytes either way; a
Project runs one psql session at a time.

See sessions:

- `cloud changes <project>` lists each session as a `shell` or `psql`
  change, started at `createdAt`, ended at `finishedAt`, with the bytes
  and how it ended in its log excerpt.
- On the `cloud` database, the open ones: `select id, kind,
  service_name, pod, user_id, created_at, connected_at, last_seen_at,
  bytes_in, bytes_out from exec_sessions where ended_at is null;`
- Kubernetes records every exec at Metadata level (the live audit policy,
  `scripts/k8s-apiserver-audit-policy.yaml`, rule 4; a WebSocket exec is
  verb `create`). In Loki: `{job="kubernetes-audit"} |= "/exec?" |=
  "system:serviceaccount:cloud:cloud-console"`. The `requestURI` holds the
  command (`sh`, or `psql`); SQL a User pipes in is stdin and is not in
  the audit log.

Cut one off: on the `cloud` database, `update exec_sessions set cut_off_at
= now() where id = '<session id>';`. The console that runs it ends it at
its next beat, within 15 s, and records `cut_off`. If no console answers
(it stopped without a word), the reconciler ends the session as `lost`
90 s after the last beat and deletes its toolbox Job.

Sessions fail with `exec_unavailable` when the console has no service
account token, `exec_refused` when Kubernetes refuses the exec (check that
ClusterRole and policy `cloud-console-exec` are applied, and that the
Project's RoleBinding exists: apply the Project again), and
`toolbox_not_ready` when the toolbox pod did not run within 2 min (quota
full during a Deploy, or an image pull; `kubectl -n p-<project> get jobs
-l cloud.viktorbarzin.me/component=toolbox`, read-only).

Rollback: remove `kubernetes_cluster_role.cloud_console_exec` from
`stacks/cloud/main.tf` and apply. No new shell or psql session can start
(the RoleBindings then name a role that does not exist and grant
nothing); nothing else changes. Sessions already open keep their exec
stream, so end them too on the `cloud` database: `update exec_sessions
set cut_off_at = now() where ended_at is null`. The console ends each
within 15 s, at its next beat.

## Alerts

| Alert | Pages | First step |
|---|---|---|
| `CloudReconcilerDown` | yes | "Restart"; look at the pod events and logs |
| `CloudReconcileQueueStuck` | yes | "Drain the queue", then the reconciler logs for the running job |
| `CloudReconcileFailing` | no | "Recover from a failed apply" |
| `CloudProjectStuckConverging` | no | "Debug a stuck Project" |
| `CloudPostgresDatabaseNearSize` | no | the owner picks a larger Size or deletes data |
| `CloudPostgresDatabaseUnmeasured` | no | `log_excerpt` and the reconciler log line "measuring Cloud databases failed" |
| `CloudPostgresDiskEnforcementFailed` | no | on the primary, find the Project session that holds a lock on its role (`SELECT pid, usename, state, query FROM pg_stat_activity WHERE usename LIKE 'p\_%' AND (state = 'idle in transaction' OR wait_event_type = 'Lock');`) and end it with `pg_terminate_backend(pid)`; the next pass, within 10 minutes, enforces the limit. The reconciler log lines are in the alert's description |
| `CloudPostgresReadOnly` | no | none: the owner sees why in the console, and write access returns when usage drops or the Size grows |
| `CloudBuildMinutesHigh` | no | GitHub billing page; Cloud builds stop at the Budget |
| `CloudPostgresTasksFailing` | no | "Postgres tasks fail", below |
| `CloudBuildsFailingForCloud` | no | "Builds fail for Cloud's reason", below |
| `CloudReconcilerLoopStalled` | no | "A reconciler loop stalled", below |
| `CloudProvisionerForeignRole`, `CloudProjectRoleUnlimited`, `CloudProjectConnectionsOverCeiling` | yes | their summaries hold the query; [docs/agents/databases.md](../agents/databases.md), "Cloud" |

### Postgres tasks fail

`CloudPostgresTasksFailing{kind,result}` fires when a Postgres task
(`cloud pg backups`, `backup`, `export`, `restore`) ends with a code that
is Cloud's fault, or when `task_failed` repeats. The User's message for
`job_refused` says the Operator has been alerted, so act on it.

1. Read the recent failures in the `cloud` database:
   `SELECT kind, error, finished_at FROM postgres_tasks WHERE state = 'failed' ORDER BY finished_at DESC LIMIT 20;`
2. `job_refused`: an admission policy refused the task's Job or pod. The
   usual cause is an image pin out of step: the reconciler's
   `PG_TASK_IMAGE` must equal the image `cloud-pg-task` admits
   (`stacks/cloud`, cloud repo `docs/build/render-parity/b28-infra.md`).
   `kubectl -n cloud get events --field-selector reason=FailedCreate`
   names the policy. Fix the pin in Terraform; the next task runs.
3. `reconciler_error` or `task_stale`: read the reconciler's
   `cloud.reconciler.postgres-tasks` lines
   (`homelab logs query '{namespace="cloud", container="reconciler"} |= "postgres-tasks"'`).
4. `task_failed`: the task's stored log ends with the reason
   (`SELECT log FROM postgres_tasks WHERE id = '<id>';`). A pull failure
   or a timeout on every kind is Cloud's; one database failing is that
   database's.

### Builds fail for Cloud's reason

`CloudBuildsFailingForCloud{failure}` fires on one `dispatch_failed`,
`invalid_input` or `image_missing` in an hour, or on two
`runner_unavailable` in two hours. These are not the User's code.

- `dispatch_failed`: Cloud could not start the builder after its retries.
  Check `github_dispatch_token` in `secret/cloud/github-narrow` and that
  the builder repo exists (`BUILDER_REPO`).
- `runner_unavailable`: GitHub had no runner for 30 minutes. Check
  githubstatus.com and the builder repo's Actions settings.
- `image_missing`, `invalid_input`: read the reconciler's `cloud.builds`
  lines and the Deploy's `log_excerpt`.

### A reconciler loop stalled

`CloudReconcilerLoopStalled{loop}` fires when a loop has not finished a
pass for many of its ticks: 5 minutes for `health_watch`, `cron_watch`,
`job_runs`, `toolbox` and `postgres_tasks`, 15 minutes for `builds`, 30
minutes for `postgres_size`, then 5 minutes more. The other loops keep
running, so only that loop's work stops: crash notifications, cron runs,
`cloud run` jobs, `cloud psql` sessions, Postgres tasks, builds, or the
size pass.

1. Read the loop's failure lines:
   `homelab logs query '{namespace="cloud", container="reconciler"} |= "failed"' --since 30m`.
   A lost connection to the `cloud` database or the Kubernetes API is the
   usual cause.
2. If the lines stop (a hung loop) or the cause is gone, restart the
   reconciler ("Restart" above). Its series starts again at the restart.

### The pull token, the ghcr cache and a rotation

- Cloud App images reach nodes through the ghcr cache at 10.0.20.10:5010
  (cloud backlog B36). nginx there sends
  `/v2/viktorbarzin/cloud-<project>_<app>/manifests/...` and `/blobs/...`
  from the six k8s nodes to `registry-ghcr-cloud`, which signs in to ghcr
  with Cloud's `ghcr_pull` token (Vault `secret/cloud/github-narrow`,
  rendered into `/opt/registry/config-ghcr-cloud.yml` by
  `playbooks/registry-cache.yml`). Every other ghcr path stays on
  `registry-ghcr`, which holds no credentials
  (`playbooks/files/registry-cache/config-ghcr.yml`). The token reads every
  private package of the account, so the route is narrow: only App image
  names, only GET and HEAD, only manifests and blobs by `sha256` digest,
  and only from the six node addresses; anyone else gets 403. The node
  addresses do not tell tenants apart, since the kubelet pulls for every
  pod on its node, so any namespace on the cluster could ask for a Cloud
  App image through a node. The digest is what keeps them out: Cloud runs
  every App by digest and nobody else knows it, while a tag is a commit
  sha, public for a public repo, so tags are refused. Project pods cannot
  reach the VM at all: the egress floor denies them 10.0.0.0/8
  (`cloud_project_egress_floor`). After a rotation of `ghcr_pull`, run the
  playbook again and restart `registry-ghcr-cloud`.
- An `UNAUTHORIZED`, a 403 or a 500 from 10.0.20.10:5010 in a Project
  pod's events does not stop the pull: containerd then pulls from ghcr.io
  directly with the Project's `cloud-registry` Secret (`hosts.toml` from
  `playbooks/k8s-node-tuning.yml`), and the kubelet reports only the first
  host's error. Look at the second pull attempt, or at whether the pod
  started. Before B36's registry apply, every App image pull went that
  way.
- The reconciler refuses every apply while `ghcr_pull_token` is empty
  (`registry_token_missing` on the change and in Notifications). Set the
  key, then apply the Project File again.
- After a change to `ghcr_pull_token`, `cloud-reconciler-registry` picks it
  up within its refresh interval (2 min after section 4 of the cloud
  repo's `docs/build/e2e-r1-infra.md`), Reloader restarts the reconciler,
  and the reconciler applies every Project again, which updates each
  `cloud-registry`. To hurry it:
  `kubectl -n cloud annotate externalsecret cloud-reconciler-registry force-sync=$(date +%s) --overwrite`.
  Before that cloud build is deployed, force-sync every Project's copy too:
  `for ns in $(kubectl get ns -l cloud.viktorbarzin.me/managed=true -o name | cut -d/ -f2); do kubectl -n $ns annotate externalsecret cloud-registry force-sync=$(date +%s) --overwrite; done`.
- `ghcr_delete_token` (optional, in `secret/cloud/system`): a token with
  `read:packages` and `delete:packages`. With it, the reconciler deletes
  the ghcr packages of Apps that were removed or whose Project was
  destroyed, 10 minutes after the apply (`package_deletions` in Cloud's
  database). Without it nothing is deleted. Since 2026-11-17 (cloud
  B08b) it is the narrow classic token `ghcr_delete` from
  `secret/cloud/github-narrow`, `read:packages` and `delete:packages`
  only; the stacks/authentik apply copies it ("Turning builds on" below).
  The reconciler deletes only repositories named
  `ghcr.io/<owner>/cloud-<project>_<app>`, so Cloud's own image and infra
  images are never touched.

### Old App images

Since cloud B36 the reconciler also prunes the images of Apps that still
run, every hour, with the same `ghcr_delete_token` (cloud
`src/reconciler/packages.ts`, `pruneImagesOnce`). Only tagged versions go:
an untagged one may be a child manifest of an index. Each App keeps its newest
10 package versions, the image of every Deploy that is building, deploying
or live (its workers and crons run that one), the images of its newest 10
live or replaced Deploys (the rollback targets) and the image of a queued
or running one-off job. A deleted Project, or one soft deleted and waiting
for its purge, keeps every image. A pass makes at most 60 GitHub calls and
20 deletes, goes on where the last one stopped, and stops at the first 401,
403 or 429 without retrying. Each pruned version is a log line ("pruned an
image version", with the repository, digest and tags), and a rollback to
it answers `image_pruned` with the `cloud deploy --commit` command that
builds it again.

- The switch: `image_prune` in `stacks/cloud` (`deploy_rules.tf`), the
  reconciler's `RECONCILE_IMAGE_PRUNE`. It starts at `dry-run` (2026-11-17)
  and moves to `on` after the dry-run lines are read; `dry-run` logs
  "would prune an image version" for each version and deletes none; `off`
  is the rollback. Change the variable and let CI apply `cloud`.
- Metrics: `cloud_image_versions_pruned_total{mode}`,
  `cloud_image_prune_errors_total{reason}` (unauthorized, forbidden,
  rate_limited, list_failed, delete_failed), `cloud_image_prune_api_calls`
  and `cloud_image_prune_stopped`.
- `CloudImagePruneStopped` (warning): GitHub answered 401 or 403, and
  pruning is off until the reconciler restarts. Check `ghcr_delete` in
  `secret/cloud/github-narrow` (`read:packages` and `delete:packages`),
  then restart the reconciler. A 429 only skips to the next pass.
- The cache on 10.0.20.10 keeps what it fetched for up to 168 h
  (`proxy.ttl`), and nginx keeps blobs for 24 h, so a pruned version, or
  the images of a purged Project, can still be pulled by digest through the
  cache for up to a week after GitHub deleted them. Only the nodes can ask,
  by digest. To drop them at once, delete their directories under
  `/opt/registry/data/ghcr-cloud/docker/registry/v2/repositories/viktorbarzin/`
  and restart `registry-ghcr-cloud`.
- A version deleted by mistake can be restored for 30 days:
  `POST /users/viktorbarzin/packages/container/<package>/versions/<id>/restore`
  with a token that has `write:packages` (the id is in GitHub's deleted
  versions list, `?state=deleted`). Then clear `image_pruned_at` on its
  Deploys in Cloud's database so a rollback to it is allowed again.

## Forgejo bot accounts (created 2026-11-14)

Two Forgejo accounts serve Cloud's builds, each with one scoped token in Vault
`secret/cloud/system` (carried over by the authentik stack's write of that
secret, `stacks/authentik/cloud-apps.tf`):

| Account | Admin | Token key | Scopes | Used by |
|---|---|---|---|---|
| `cloud-bot` | no | `forgejo_read_token` | read:repository | reconciler (branch polling) and the GitHub builder repo's `FORGEJO_READ_TOKEN` secret; reads a private App repo only as a Read collaborator, which `cloud new` adds (Cloud's `FORGEJO_READER`, default `cloud-bot`) |
| `cloud-admin-reader` | yes | `forgejo_admin_token` | read:admin, read:repository, read:user | reconciler only (the Project owner's repo-access check); never copied anywhere |
| `cloud-bot` | no | `forgejo_status_token` (a second token) | write:repository | reconciler only: posts the commit status `cloud/build` of check builds (B13). Write comes only from repos with Renovate on, where `cloud new` or `cloud renovate enable` makes `cloud-bot` a Write collaborator; elsewhere it stays Read or absent. Write lets this token push any branch of those repos, the deploy branch included; it is Forgejo's minimum for posting a status (`reqRepoWriter`), and no narrower role exists. Never copied to the builder |
| `cloud-renovate` | no, restricted | in Vault `secret/renovate-cloud` `forgejo_token` | write:repository, read:user, write:issue, read:organization | the `renovate-cloud-apps` CronJob only (`docs/runbooks/renovate.md`); a Write collaborator of enrolled App repos, and of nothing else |

Both were made with the in-pod CLI (the admin REST endpoint cannot mint
tokens for another user):

```sh
kubectl -n forgejo exec deploy/forgejo -c forgejo -- su -s /bin/sh git -c \
  "forgejo admin user generate-access-token --username <account> --token-name <name> --scopes '<scopes>' --raw"
```

To rotate, mint a new token the same way, `vault kv patch secret/cloud/system <key>=-`
from stdin, then revoke the old one with `DELETE /api/v1/users/<account>/tokens/<name>`
as an admin. Their passwords are random and not stored; nobody signs in as them.

## Renovate on App repos

Cloud backlog B13. Renovate (`renovate-cloud-apps`, `docs/runbooks/renovate.md`) opens one pull request a week on each App repo with the topic `cloud-app`, as the Forgejo account `cloud-renovate`. Cloud builds each commit of a `renovate/*` branch as a check build that never deploys and posts the Forgejo commit status `cloud/build`. Renovate merges once every status of the commit is success, `cloud/build` among them. The merge is a push, so it deploys like any other and goes live only past its health check.

Operator steps, before the job is unsuspended. Each token is held in a shell variable, checked to be non-empty, then piped to Vault, so it is never printed and an empty answer writes nothing:

```sh
fj() { kubectl -n forgejo exec deploy/forgejo -c forgejo -- su -s /bin/sh git -c "$1"; }

# 1. The account: restricted, so it sees only repos it is a collaborator of.
fj "forgejo admin user create --username cloud-renovate --email cloud-renovate@viktorbarzin.me --fullname 'Cloud Renovate' --random-password --must-change-password=false --restricted"

# 2. Its token, into its own Vault path (Secret renovate-cloud-env).
tok=$(fj "forgejo admin user generate-access-token --username cloud-renovate --token-name renovate-cloud-2 --scopes 'write:repository,read:user,write:issue,read:organization' --raw")
[ -n "$tok" ] || { echo "no token; nothing written" >&2; false; } && printf %s "$tok" | vault kv put secret/renovate-cloud forgejo_token=-
unset tok

# 3. cloud-bot's status token, next to its read token.
tok=$(fj "forgejo admin user generate-access-token --username cloud-bot --token-name cloud-status --scopes 'write:repository' --raw")
[ -n "$tok" ] || { echo "no token; nothing written" >&2; false; } && printf %s "$tok" | vault kv patch secret/cloud/system forgejo_status_token=-
unset tok
```

Renovate reads each repo's owner with `GET /api/v1/orgs/<owner>`, which needs `read:organization`; without it every repo answers 403. The first token, `renovate-cloud`, lacked that scope and was replaced by `renovate-cloud-2` on 2026-11-20.

Until step 2 is done, the ExternalSecret `renovate/renovate-cloud-env` reports a sync error (no `secret/renovate-cloud` in Vault). That is expected while the job is suspended, and no alert reads it. ESO retries a failed sync on its own backoff, and the 1 h refresh at the latest reads the key after step 2; check with `kubectl -n renovate get externalsecret renovate-cloud-env` (Ready) before you unsuspend the job.

The random password is not stored; nobody signs in as either account. `stacks/authentik` carries `forgejo_status_token` over on every apply (`cloud_system_carried_keys`), so land the infra change before an authentik apply can run after step 3. The reconciler reads the key within 5 minutes; from then on it check-builds.

Then:

1. Set `cloud_apps_suspended = false` in `stacks/renovate` and `renovate_account = "cloud-renovate"` in `stacks/cloud` (`deploy_rules.tf`), and push; CI applies both. Done 2026-11-17; both are now the defaults. The console then names Renovate on `GET /api/v1/instance`, and `cloud new` and `cloud renovate enable` set up repos.

Setting `renovate_account` before step 3 leaves Renovate's pull requests waiting forever: with no status token Cloud runs no check builds, and a commit with no status never merges.

What Cloud checks before it check-builds a commit: the repo is on Cloud's Forgejo and has the topic `cloud-app`, and this App is the oldest App of the repo that runs, deploys pushes and whose owner is an Operator or is linked to the Forgejo account that owns the repo (`forgejo_links`). So one App checks each commit, and another User's App of the same public repo cannot post the status. The owner check runs again before every post, and a status goes only to the repo the check build was made for. A failure that says nothing about the commit (no runner, the dispatch, the Budget, a refused status) is built again an hour after it ended, at most 3 builds per commit.

Off for one repo: `cloud renovate disable <project> <app>`. Off for all: `cloud_apps_suspended = true` in `stacks/renovate`, then `renovate_account = ""` in `stacks/cloud` so new Apps are not set up. To stop check builds, remove `forgejo_status_token` from `secret/cloud/system` and from `cloud_system_carried_keys`.

## Turning builds on

Builds are on since 2026-11-14. From then until 2026-11-17 all of Cloud's
GitHub tokens held Viktor's classic `github_pat`. Since cloud B08b
(2026-11-17) each is a narrow token Viktor minted, in Vault
`secret/cloud/github-narrow`; the authentik apply copies them into
`secret/cloud/system` (`stacks/authentik/cloud-apps.tf`):

| `github-narrow` key | `secret/cloud/system` key | Kind and scope |
|---|---|---|
| `ghcr_pull` | `ghcr_pull_token` | classic, `read:packages`; copied into every Project's image pull secret |
| `ghcr_delete` | `ghcr_delete_token` | classic, `read:packages` and `delete:packages` |
| `dispatch` | `github_dispatch_token` | fine-grained, `ViktorBarzin/cloud-builder` only: Actions read and write, Metadata read, and the account permission Plan read (Contents and Workflows dropped 2026-11-17) |
| `owner_read` | `github_owner_read_token` | fine-grained, Contents and Metadata read on the repos Operators build privately; also the builder repo's `GH_OWNER_READ_TOKEN` secret |

The dispatch token's Plan read lets Cloud read the Actions billing usage.
Cloud reads it only while the builder repo is private (the 90% minutes
stop); the repo is public since 2026-11-16. A fine-grained token's
permissions can be edited in GitHub without changing its value.

To rotate one: mint the new token, `vault kv patch secret/cloud/github-narrow
<key>=-` from stdin, let CI apply `authentik` (or apply it), check the keys
in `secret/cloud/system`, and for `owner_read` run `publish-builder.sh` again
so the builder repo's secret follows. Setting repo secrets needs a token
with the repo's Secrets permission, which none of the four holds; use
Viktor's `github_pat` for that run (`GH_TOKEN`).

To set builds up from scratch: apply `authentik`, run the cloud repo's `scripts/publish-builder.sh
--forgejo-token secret/cloud/system#forgejo_read_token --owner-token
secret/cloud/system#github_owner_read_token`, set `builds_enabled = true`,
apply `cloud`, and run a live build of a public repo.

Since cloud B05 the builder also needs `--job-key secret/cloud/builder#job_key`
and Cloud needs `build_log_key`; "Builder v2 keys and the public builder"
below has the order.

## Builder v2 keys and the public builder

Cloud backlog B05, decision V12: `ViktorBarzin/cloud-builder` goes public so
its Actions minutes are free. Its inputs, run logs and artifacts are public,
so Cloud seals every build with [age](https://age-encryption.org):

| Key | Identity (secret) | Recipient (public) |
|---|---|---|
| The builder's job key: seals the job (repo, commit, image, plain env) and the source tree | GitHub secret `CLOUD_JOB_KEY`; a copy in Vault `secret/cloud/builder` `job_key`, which no workload can read | `builder_job_recipient` in `stacks/cloud/deploy_rules.tf`, env `BUILD_JOB_RECIPIENT` on the reconciler |
| Cloud's log key: the builder seals each job's output to it | Vault `secret/cloud/system` `build_log_key`, file `BUILD_LOG_KEY_FILE` on the reconciler | derived by Cloud and sent in each job |

Plain env reaches the build; secrets never do. Cloud leaves out of the
build, though not out of the App, the names that would steer the runner or
its tools: `PATH`, `LD_*`, `DOCKER_*`, `BUILDX_*`, `BUILDKIT_*`,
`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`, `ALL_PROXY`, `NODE_OPTIONS`,
`BUN_*` and `RAILPACK_CONFIG_FILE`, in any case.

The values go from `age-keygen` to Vault and GitHub through pipes, never to
the terminal or a file. Only the recipient is printed. Do the steps in this
order; each needs the one before.

1. Turn builds off: set `default = false` on `builds_enabled` in
   `stacks/cloud/deploy_rules.tf`, land it, and check the apply of `cloud`.
   A push made while builds are off is built when they come back on.
2. Make the job key and print its recipient:

   ```sh
   vault login -method=oidc
   age-keygen 2>/dev/null | grep '^AGE-SECRET-KEY-1' | tr -d '\n' \
     | vault kv put secret/cloud/builder job_key=-
   vault kv get -field=job_key secret/cloud/builder | age-keygen -y
   ```

   Put the printed `age1...` into `builder_job_recipient`.
3. Land the cloud release with B05 and wait for its rollout.
4. Land this stack's B05 change with the recipient, still with builds off.
   Apply `authentik`, then `cloud`. `build_log_key` is in
   `cloud_system_carried_keys` from then on; a key written before that
   apply is dropped by it.
5. Make Cloud's log key, then copy it to the reconciler:

   ```sh
   age-keygen 2>/dev/null | grep '^AGE-SECRET-KEY-1' | tr -d '\n' \
     | vault kv patch secret/cloud/system build_log_key=-
   vault kv get -format=json secret/cloud/system | jq '.data.data | keys'
   kubectl -n cloud annotate externalsecret cloud-reconciler-system force-sync=$(date +%s) --overwrite
   ```

   The key list shows `build_log_key` beside the others. Reloader restarts
   the reconciler after its running job.
6. Publish the builder with the job key, and set its Actions settings, from
   the cloud repo:

   ```sh
   scripts/publish-builder.sh \
     --forgejo-token secret/cloud/system#forgejo_read_token \
     --owner-token secret/cloud/system#github_owner_read_token \
     --job-key secret/cloud/builder#job_key
   scripts/publish-builder.sh --settings
   ```

   `--settings` also tries the approval rule for outside contributors;
   GitHub takes it only once the repo is public, so the script says to run
   it again after step 11.
7. Turn builds on: `default = true` on `builds_enabled`, land, check the
   apply.
8. Test while the repo is still private. In a test App, set
   `env: {VITE_GREETING: <a unique word>}` and push a commit whose
   Dockerfile has `RUN exit 3`. Within 10 minutes `cloud deploys <p> <app>`
   shows it `failed`, reason `build_failed`, with the last 20 lines of the
   build. `cloud deploys log <p> <app> <id>` prints the whole build. Push
   a good commit; its log prints too, and its page's JS holds the word.
9. Check both runs read-only. The run id is the end of the Deploy's run
   URL (Actions tab of the builder repo):

   ```sh
   scripts/publish-builder.sh --check-run <run id> \
     --absent <repo URL> --absent <commit sha> --absent <the unique word> \
     --absent cloud-<p>_<app> --package cloud-<p>_<app>
   ```

   It prints one line per check and `no findings`, or exits 1 with what it
   found, never the value. At this point it still finds the plain
   workflow's runs; step 10 removes them.
10. Delete the runs of the first, plain workflow. Their logs and artifacts
    show repo URLs, images, commits and build output, so they must be gone
    before anyone else can read the repo:

    ```sh
    scripts/publish-builder.sh --delete-old-runs        # lists them, deletes nothing
    scripts/publish-builder.sh --delete-old-runs --yes  # deletes them
    ```

    It lists every run first and stops at the first 401, 403 or 429. A plain
    run still in progress is named; cancel it and run the step again. Then
    run step 9 again. Do not go on to step 11 until it prints both
    `no run of the plain workflow is left` and `no check run of the plain
    workflow carries annotations or output`, and `no findings`.

    What stays after the deletion: the check runs of the deleted runs can
    outlive them on the builder commit. On 2026-11-16 the first builder
    commit (`0d8353f`) had 48, two per plain run, named `fetch` and `build`,
    each with its conclusion and times, no annotations and no output text;
    their links lead to the deleted runs. They name no repo, commit, image
    or env. If step 9 finds annotations or output on them, do not make this
    repo public: publish the builder to a new repo instead
    (`scripts/publish-builder.sh --repo <owner>/<new repo>`, `BUILDER_REPO`
    on the reconciler) and make that one public.
11. Make the repo public, then set the public-repo setting at once:

    ```sh
    gh repo edit ViktorBarzin/cloud-builder --visibility public --accept-visibility-change-consequences
    scripts/publish-builder.sh --settings
    ```

12. Push another commit to the test App and run step 9 on its run. Then
    check that no Cloud package went public:

    ```sh
    gh api --paginate 'user/packages?package_type=container' \
      --jq '.[] | select(.name | startswith("cloud-")) | "\(.name) \(.visibility)"'
    ```

    Every line ends in `private`, and `--settings` says outside contributors
    need approval. If any package says `public`, or step 9 finds
    anything, make the repo private again:
    `gh repo edit ViktorBarzin/cloud-builder --visibility private --accept-visibility-change-consequences`.
    The sealed format works in a private repo too, so that is the whole
    rollback.

To rotate a key, repeat its step: for the job key, steps 2, 4 (the new
recipient) and 6; for the log key, step 5. A build in flight during a log
key rotation keeps no log; its Deploy result is not affected.
