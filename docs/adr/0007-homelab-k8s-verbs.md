# homelab k8s verb-group: app→pod resolver, read/write split, config-mutation stays raw

v0.2 adds the Kubernetes verb-group — the biggest remaining surface by far
(mining the post-v0.1 corpus: 11,291 `kubectl` commands across 243 sessions, more
than every other domain combined).

It is built on an **app→namespace→pod resolver**: most namespaces hold exactly
one app, so `<app>` defaults to the namespace, and the target defaults to
`deploy/<app>` (kubectl resolves a pod from the Deployment). `-n`/`--pod`/`-c`/
`-l`/`--tty` override; multi-pod namespaces (`dbaas`, `monitoring`) need
specificity. The CLI uses the ambient kubeconfig — no per-call auth flags.

Verbs: read — `status`, `get`, `logs`, `describe`, `debug` (one-shot triage),
`pf`, `rollout-status`; write/operational — `db`, `exec`, `restart`, `rm-pod`.

## Decisions worth recording

- **Config-mutation verbs are deliberately NOT exposed** (`apply`/`edit`/`patch`/
  `scale`/`create`). They stay raw `kubectl`, by design, per the repo's
  Terraform-only policy — the corpus confirms they're low-frequency, and a
  friendly verb would normalise a policy violation.
- **`rm-pod` is restricted to pods/jobs only** — deleting Deployments/STS/PVCs is
  config mutation and forbidden; the verb cannot target them.
- **`db` encodes the dbaas exec pattern** (the single highest-value k8s
  sub-pattern, ~886 dbaas ops): PG via `pg-cluster-rw -c postgres`,
  `psql -U postgres -d <app>`; MySQL via `mysql-standalone-0` with a
  `bash -c 'mysql -p"$MYSQL_ROOT_PASSWORD" …'` wrapper so the password comes from
  the pod env and never appears on the command line.
- Read verbs were smoke-tested against the live cluster; write verbs are
  unit-tested (resolver, db-plan, shell-quoting) but not fired at live state.
