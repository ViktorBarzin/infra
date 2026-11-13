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
  Tokens screen. An Operator can revoke any:
  `UPDATE access_tokens SET revoked_at = now() WHERE id = '<id>' AND revoked_at IS NULL;`
  (`SELECT id, user_id, name, created_at FROM access_tokens WHERE revoked_at IS NULL;`).
  The API refuses it on the next request.
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
| `CloudProjectStuckConverging` | no | "Debug a stuck Project". Its metric is not exported yet ([architecture](../architecture/cloud.md), "Metrics"), so it cannot fire until the cloud code adds it |
| `CloudPostgresDatabaseNearSize` | no | the owner picks a larger Size or deletes data |
| `CloudPostgresDatabaseUnmeasured` | no | `log_excerpt` and the reconciler log line "measuring Cloud databases failed" |
| `CloudBuildMinutesHigh` | no | GitHub billing page; Cloud builds stop at the Budget |
| `CloudProvisionerForeignRole`, `CloudProjectRoleUnlimited`, `CloudProjectConnectionsOverCeiling` | yes | their summaries hold the query; [docs/agents/databases.md](../agents/databases.md), "Cloud" |
