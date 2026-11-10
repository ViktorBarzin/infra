# Network IDS runbook

Operating the network IDS pipeline. Design and as-built:
`docs/architecture/network-security-monitoring.md`. Suricata tuning on the
firewall: `docs/runbooks/opnsense.md`, "Suricata tuning".

## Query

```sh
homelab netsec schema                     # tables, retention, examples
homelab netsec sql "SELECT count(), max(ts) FROM netsec.flows WHERE ts > now() - INTERVAL 1 HOUR"
```

Viktor only (`/etc/netsec/reader.env`). Admin access for schema changes:

```sh
kubectl exec -n claude-sessions deploy/clickhouse -- sh -c 'clickhouse-client --password "$CLICKHOUSE_PASSWORD" --query "..."'
```

Schema changes are applied by hand as the default user and copied into
`stacks/claude-sessions/files/schema.sql` in the same commit (the same rule
as the `claude` tables).

## Is data flowing?

1. Rows: `homelab netsec sql "SELECT count(), max(ts), max(received) FROM netsec.flows WHERE received > now() - INTERVAL 10 MINUTE"`.
   About 100 flows a second is normal (2026-11-10).
2. Vector: `kubectl logs -n netsec deploy/netsec-vector`; sink errors show as
   ClickHouse HTTP status codes. `vector_component_errors_total{namespace="netsec"}`
   in Prometheus.
3. goflow2 sidecar: `kubectl logs -n monitoring deploy/goflow2 -c vector`.
   goflow2 itself: `kubectl logs -n monitoring deploy/goflow2 -c goflow2`
   (not in Loki, see the architecture doc).
4. NetFlow arriving at all: `homelab metrics query 'sum(rate(goflow2_flow_process_nf_flowset_records_total[10m]))'`.

After goflow2 restarts it decodes nothing until OPNsense resends its NetFlow
templates (`template error` in its log); on 2026-11-10 rows resumed within
about five minutes.

The sidecar's sink address needs the `http://` scheme. Without it Vector 0.61
starts, fails its healthcheck with `client error (Connect)` and delivers
nothing, although the TCP port answers.

## Alerts

| Alert | Meaning | First step |
|---|---|---|
| `NetsecVectorDown` | the netsec Vector pod is not scraped for 10 minutes | `kubectl get pods -n netsec`, then its logs |
| `NetsecSinkErrors` | a ClickHouse write failed | Vector logs; a 401/516 is the `netsec_writer` password (Vault `secret/claude-sessions` vs the pod's `netsec-secrets`), a quota error means a runaway source |
| `NetsecFlowsStale` | no row written to `flows` for 30 minutes | the four checks above, in order |

## Vector config tests

```sh
cd stacks/netsec/files
mkdir -p /tmp/netsec-secrets && echo -n test > /tmp/netsec-secrets/netsec_writer_password
docker run --rm -v "$PWD/vector.yaml:/etc/vector/vector.yaml:ro" -v /tmp/netsec-secrets:/etc/vector/secrets:ro \
  docker.io/timberio/vector:0.61.0-debian test /etc/vector/vector.yaml
```

The secret directory must exist, or `vector test` fails before it runs.

## goflow2 byte counts read 0

If `flows.bytes` is 0 for every row, check that goflow2 still runs with
`-mapping /etc/goflow2/mapping.yaml` and that its JSON lines carry
`in_bytes`. Without the mapping, OPNsense's OUT_BYTES=0 overwrites IN_BYTES
(architecture doc, "Byte counts").
