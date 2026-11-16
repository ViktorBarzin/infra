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
mailserver has a `persona@` mailbox.

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

## Restart

The console: `kubectl -n cloud delete pod -l app=cloud`. The reconciler:
`kubectl -n cloud delete pod -l app=cloud-reconciler`. Both Deployments use
Recreate, so the new pod starts after the old one is gone. Deleting the pod,
not `rollout restart`, keeps the pod template equal to Terraform's.

On a pod delete, a Reloader restart or a CI rollout, the reconciler finishes
its running job before it exits (grace period 3780 s). A node drain or
eviction with a shorter grace period cuts the job: the automated node upgrade
drains with `--grace-period=300`. A terminating pod is not scraped, so if the
running job takes longer than 15 more minutes, `CloudReconcilerDown` pages;
silence it before a restart while a long job runs. To see whether one runs:
`SELECT id, project_id, kind, started_at FROM reconcile_jobs WHERE state = 'running';`
A job killed mid-apply is `running` until `RECONCILE_STALE_SECONDS` (600 s)
pass; the next reconciler requeues it, and OpenTofu continues from the state.

## Drain the queue

Let the reconciler work the queue down; it runs one job at a time. To see it:

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
`postgresql-backup` dumps it with every other database
(`/backup/per-db/<db>/dump_<ts>.dump`; [restore-postgresql.md](restore-postgresql.md),
"Restore Single Database").

1. Find the database:
   `SELECT datname FROM pg_database WHERE datname LIKE 'p\_<project>\_%';`
2. Stop the App's writes for the restore: `ALTER ROLE <db> CONNECTION LIMIT 0;`
   then `SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '<db>';`
3. Restore as in `restore-postgresql.md`:
   `pg_restore -d <db> --clean --if-exists <dump>`. The role exists, so
   ownership comes back as it was.
4. Set the limit back to the Size's (nano 2, small 4, medium 8):
   `ALTER ROLE <db> CONNECTION LIMIT <n>;`. The next apply of the Project sets
   it again anyway. A limit above 8 or none pages `CloudProjectRoleUnlimited`.

The size loop measures the database again within 5 minutes.

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
| `too many connections for role "cloud_provisioner"` | more than 5 connections as the provisioner | one reconciler only; check for a second pod or a stray session in `pg_stat_activity` |

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
| `CloudProvisionerForeignRole`, `CloudProjectRoleUnlimited`, `CloudProjectConnectionsOverCeiling` | yes | their summaries hold the query; [docs/agents/databases.md](../agents/databases.md), "Cloud" |

### The pull token, the ghcr cache and a rotation

- An `UNAUTHORIZED` or a 500 from the ghcr cache at 10.0.20.10:5010 in a
  Project pod's events is normal for a private image. The cache holds no
  credentials by design (`playbooks/files/registry-cache/config-ghcr.yml`);
  containerd then pulls from ghcr.io directly with the Project's
  `cloud-registry` Secret (`hosts.toml` from
  `playbooks/k8s-node-tuning.yml`), and the kubelet reports only the first
  host's error. Look at the second pull attempt, or at whether the pod
  started.
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
  database). Without it nothing is deleted. It holds Viktor's existing
  `github_pat` (Vault `secret/viktor`), the same token as
  `ghcr_pull_token`: on 2026-11-14 Viktor chose to reuse it over a
  dedicated `read:packages` + `delete:packages` PAT. The stacks/authentik
  apply carries the key (`cloud_system_carried_keys`); after a rotation of
  `github_pat`, patch it here too. The reconciler deletes only repositories named
  `ghcr.io/<owner>/cloud-<project>_<app>`, so Cloud's own image and infra
  images are never touched.

## Forgejo bot accounts (created 2026-11-14)

Two Forgejo accounts serve Cloud's builds, each with one scoped token in Vault
`secret/cloud/system` (carried over by the authentik stack's write of that
secret, `stacks/authentik/cloud-apps.tf`):

| Account | Admin | Token key | Scopes | Used by |
|---|---|---|---|---|
| `cloud-bot` | no | `forgejo_read_token` | read:repository | reconciler (branch polling) and the GitHub builder repo's `FORGEJO_READ_TOKEN` secret; reads a private App repo only as a Read collaborator, which `cloud new` adds (Cloud's `FORGEJO_READER`, default `cloud-bot`) |
| `cloud-admin-reader` | yes | `forgejo_admin_token` | read:admin, read:repository, read:user | reconciler only (the Project owner's repo-access check); never copied anywhere |

Both were made with the in-pod CLI (the admin REST endpoint cannot mint
tokens for another user):

```sh
kubectl -n forgejo exec deploy/forgejo -c forgejo -- su -s /bin/sh git -c \
  "forgejo admin user generate-access-token --username <account> --token-name <name> --scopes '<scopes>' --raw"
```

To rotate, mint a new token the same way, `vault kv patch secret/cloud/system <key>=-`
from stdin, then revoke the old one with `DELETE /api/v1/users/<account>/tokens/<name>`
as an admin. Their passwords are random and not stored; nobody signs in as them.

## Turning builds on

Builds are on since 2026-11-14. Viktor chose to use his existing classic PAT
(`secret/viktor` `github_pat`) for all three GitHub tokens below, so each copy
carries that token's full scope; replace them with narrow tokens to reduce it.
Rotating the PAT means re-copying it into the three keys. The keys:

1. `secret/viktor` `cloud_ghcr_pull_token`: a classic GitHub token, `read:packages`
   only, on Viktor's account (Viktor accepted that it reads all his private
   packages). The authentik apply copies it to `secret/cloud/system`.
2. `secret/cloud/system` `github_dispatch_token`: fine-grained, repository
   `ViktorBarzin/cloud-builder` only (the repo exists, empty), Actions read and
   write, Metadata read, plus the account permission "Plan" read.
3. `secret/cloud/system` `github_owner_read_token`: fine-grained, Contents and
   Metadata read on the repos Operators build privately (required by
   `scripts/publish-builder.sh`).

Then: apply `authentik`, run the cloud repo's `scripts/publish-builder.sh
--forgejo-token secret/cloud/system#forgejo_read_token --owner-token
secret/cloud/system#github_owner_read_token`, set `builds_enabled = true`,
apply `cloud`, and run a live build of a public repo.
