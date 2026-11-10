# Network IDS runbook

Operating the network IDS pipeline. Design and as-built:
`docs/architecture/network-security-monitoring.md`. Suricata tuning on the
firewall: `docs/runbooks/opnsense.md`, "Suricata tuning".

## Query

```sh
homelab netsec schema                     # tables, retention, examples
homelab netsec sql "SELECT count(), max(ts) FROM netsec.flows WHERE ts > now() - INTERVAL 1 HOUR"
homelab netsec sql "SELECT event_type, count() FROM netsec.eve WHERE ts > now() - INTERVAL 30 MINUTE GROUP BY event_type"
```

Traffic between VLAN 10 and 20 is seen on both inspected interfaces and logged
twice with one `community_id`. Collapse the copies in any count:

```sql
SELECT dns_rrname, count() FROM (
  SELECT * FROM netsec.eve
  WHERE event_type = 'dns' AND ts > now() - INTERVAL 1 DAY
  LIMIT 1 BY community_id, event_type, dns_rrname
) GROUP BY dns_rrname ORDER BY count() DESC LIMIT 20
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

## Is Suricata metadata flowing? (netsec.eve)

1. Test: `dig icanhazip.com @10.0.10.1` from the devvm, then
   `homelab netsec sql "SELECT ts, in_iface, signature FROM netsec.eve WHERE signature_id = 2054169 ORDER BY ts DESC LIMIT 1"`.
   It arrived in 16 seconds on 2026-11-10.
2. On OPNsense (root shell is csh, so `ssh root@10.0.10.1 sh -s <<EOF`):
   `ls -la /var/log/suricata/eve-meta.json` grows; `sockstat -4 -c | grep 5140`
   shows syslog-ng connected to 10.0.20.211.
3. Suricata running: `pgrep -fl suricata`; a refused config shows as `<Error>`
   in `/var/log/suricata/latest.log`.
4. After an OPNsense upgrade the `netsec_eve` area may refuse to install with
   "OPNsense's Suricata outputs changed": render the template's outputs again,
   restate them in `playbooks/files/opnsense/suricata-netsec-outputs.yaml`
   (keep `eve-meta.json` last), diff `suricata --dump-config` output for
   `outputs.0` to `outputs.3` before and after, then update the fingerprint in
   `netsec_eve.yml`.

## Alerts

| Alert | Meaning | First step |
|---|---|---|
| `NetsecVectorDown` | the netsec Vector pod is not scraped for 10 minutes | `kubectl get pods -n netsec`, then its logs |
| `NetsecSinkErrors` | a ClickHouse write failed | Vector logs; a 401/516 is the `netsec_writer` password (Vault `secret/claude-sessions` vs the pod's `netsec-secrets`), a quota error means a runaway source |
| `NetsecFlowsStale` | no row written to `flows` for 30 minutes | the four checks above, in order |
| `NetsecEveStale` | no row written to `eve` for 30 minutes | "Is Suricata metadata flowing?" above |
| `NetsecHomeHostMalware` | a malware or C2 alert involving one of our hosts (CronJob `netsec-alerts`) | "A home host hit a malware rule" below |
| `CameraVlanBlockedTraffic` | the VLAN 30 camera started traffic the firewall blocked | "Camera VLAN blocked traffic" below |
| `CrowdSecOpnsenseAgentSilent` | OPNsense's agent sent nothing to LAPI for 15 minutes | `ssh root@10.0.10.1 'service crowdsec status'`, `/var/log/crowdsec/crowdsec.log` |
| `CrowdSecOpnsenseBouncerNotPulling` | OPNsense's bouncer pulled nothing for 15 minutes | `service crowdsec_firewall status`, `/var/log/crowdsec/crowdsec-firewall-bouncer.log` |
| `CrowdSecC2MirrorNotPulling` | the C2 blocklist mirror pulled nothing for 15 minutes | `kubectl logs -n crowdsec deploy/crowdsec-c2-mirror` |

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

## Alerts into bans (phase 3)

Suricata's stock `eve.json` feeds OPNsense's CrowdSec agent (machine
`opnsense-edge`). Every scenario on that agent is **simulated** until the
phase 6 review: decisions are recorded with `simulated=true` and no bouncer,
pf table or mirror receives them.

```sh
ssh root@10.0.10.1 'cscli simulation status'          # global simulation: enabled
ssh root@10.0.10.1 'grep performed /var/log/crowdsec/crowdsec.log | tail'
# On the LAPI: alerts and would-be decisions from the firewall
L=$(kubectl get pods -n crowdsec -l type=lapi -o name | head -1)
kubectl exec -n crowdsec $L -- cscli alerts list --since 24h -o raw
kubectl exec -n crowdsec $L -- cscli decisions list --all -o raw   # last column but one: simulated
```

An alert whose source is in the `trusted-infra` allowlist (our ranges and
what we depend on, `stacks/crowdsec` `lapi_allowlist`) never reaches the
alerts list: the firewall agent has no parser whitelist of its own, so the
LAPI allowlist is what keeps our hosts from being banned.

### Reviewing the would-be bans (phase 6)

Two weeks after phase 3 landed (2026-11-10, so from 2026-11-24), with Viktor:

```sh
kubectl exec -n crowdsec $L -- cscli decisions list --all -o raw \
  | awk -F, 'NR > 1 && $10 == "true" {print $4}' | sort | uniq -c | sort -rn   # by scenario
kubectl exec -n crowdsec $L -- cscli decisions list --all -o raw \
  | awk -F, 'NR > 1 && $10 == "true" {print $3, $4, $6, $7}' | sort | uniq -c | sort -rn | head -50
```

Simulated decisions expire like real ones (4h bans, 24h C2 blocks), so also
read the alerts list, which keeps 7 days (`flush.max_age`). For each address
that would have been banned, decide: a real attacker (keep), something we use
(add it to `lapi_allowlist`), or a noisy signature (turn it off in
`opn_ids_disabled_sids`, `playbooks/tasks/opnsense/suricata.yml`).

### Turning bans on

1. Edit `playbooks/files/opnsense/crowdsec/simulation.yaml` to
   `simulation: false` and the assert in `playbooks/tasks/opnsense/crowdsec.yml`
   to `global simulation: disabled`.
2. `ansible-playbook -i playbooks/inventory.ini playbooks/opnsense.yml -e opnsense_allow_production=true --tags crowdsec --check --diff`, then without `--check`.
3. Watch `cscli decisions list` on the LAPI and the pf tables on OPNsense:
   `pfctl -t crowdsec_blocklists -T show | wc -l`, `pfctl -t crowdsec_c2 -T show`.

To keep one scenario simulated after that, add it under `exclusions:` in the
same file (with `simulation: false`, exclusions are the simulated ones).

### C2 blocks

One hit of an abuse.ch rule (Feodo Tracker, SSL Blacklist) involving one of
our hosts makes a 24h decision of type `c2-block` on the C2 address. Only
`crowdsec-c2-mirror` (LB `10.0.20.212:41412`, source ranges OPNsense only)
serves that type; OPNsense refreshes alias `crowdsec_c2` from it about every
5 minutes and blocks it outbound on VLAN 10 and 20, logged.

```sh
ssh root@10.0.10.1 'pfctl -t crowdsec_c2 -T show'        # what is blocked now
ssh root@10.0.10.1 'curl -s http://10.0.20.212:41412/security/blocklist'
kubectl exec -n crowdsec $L -- cscli decisions delete --id <id>   # unblock one
```

With no decisions the mirror answers `404 no decisions available`; OPNsense
then keeps the alias as it was (empty). A blocked connection shows in the
filter log with the rule description "Block our hosts reaching CrowdSec C2
blocks".

### A home host hit a malware rule

`NetsecHomeHostMalware` names the host and the signature. Look at what else
the host did:

```sh
homelab netsec sql "SELECT ts, event_type, src_ip, dest_ip, signature, dns_rrname, tls_sni, http_hostname FROM netsec.eve WHERE (src_ip = toIPv6('<host>') OR dest_ip = toIPv6('<host>')) AND ts > now() - INTERVAL 1 HOUR ORDER BY ts DESC LIMIT 100"
homelab netsec sql "SELECT dst_ip, sum(bytes) FROM netsec.flows WHERE src_ip = toIPv6('<host>') AND ts > now() - INTERVAL 1 HOUR GROUP BY dst_addr ORDER BY 2 DESC LIMIT 20"
```

A k8s node's address means a pod on that node (Calico NAT) until phase 4 adds
pod DNS. The query and its test: `stacks/netsec/files/alerts.sql`,
`sh stacks/netsec/files/alerts_test.sh` (read-only against the live
ClickHouse with fixed rows).

### Camera VLAN blocked traffic

`CameraVlanBlockedTraffic` fires when OPNsense's default deny drops traffic
the VLAN 30 camera started. Its late RTSP and HTTP replies to Frigate and
ha-sofia (source port 554 or 80) are excluded: they are blocked after every
filter reload, 64 in the 6 hours measured on 2026-11-10.

```
{job="syslog", host="opnsense", app="filterlog"} |= ",vtnet3,match,block,in,"
```

### Testing the whole path without touching a real C2

Append fake alerts using TEST-NET addresses to the files the agent and the
netsec pipeline read (OPNsense shell is csh, so run through `sh -s`):

```sh
ssh root@10.0.10.1 sh -s <<'EOS'
ts=$(date +%Y-%m-%dT%H:%M:%S.000000%z)
printf '%s\n' "{\"timestamp\":\"$ts\",\"flow_id\":1,\"in_iface\":\"vtnet2\",\"event_type\":\"alert\",\"src_ip\":\"10.0.20.104\",\"src_port\":51515,\"dest_ip\":\"192.0.2.1\",\"dest_port\":8080,\"proto\":\"TCP\",\"alert\":{\"signature_id\":99000001,\"rev\":1,\"signature\":\"Feodo Tracker: TEST\",\"category\":\"A Network Trojan was detected\",\"severity\":1}}" \
  | tee -a /var/log/suricata/eve.json >> /var/log/suricata/eve-meta.json
EOS
```

Expect within a minute: `Ip 192.0.2.1 performed 'viktor/abusech-c2-destination'`
in the agent log, a simulated `c2-block` decision on the LAPI, and
`NetsecHomeHostMalware` for 10.0.20.104 in Slack; within 10 minutes the
grouped CrowdSec Slack message. Run 2026-11-10: all four seen, nothing reached
pf.

## Server journals and pod DNS (phase 4)

### Is the journals agent reading?

```sh
kubectl -n crowdsec logs deploy/crowdsec-journals | tail
kubectl -n crowdsec exec deploy/crowdsec-journals -- cscli metrics show acquisition parsers
homelab metrics query 'sum by (source, type) (rate(cs_parser_hits_total{pod=~"crowdsec-journals.*"}[1h]))'
```

If the agent cannot log in to the LAPI, the machine `journals` is not
registered yet: the `crowdsec-lapi-reconcile` CronJob registers it every 15
minutes, or run it now with
`kubectl -n crowdsec create job --from=cronjob/crowdsec-lapi-reconcile reconcile-now`.

Its decisions are simulated until the phase 6 review, together with the
OPNsense agent's; turning bans on means setting `simulation: false` in
`kubernetes_config_map.crowdsec_journals` too.

### Which pod looked up a name?

```sh
homelab netsec sql "SELECT ts, client_ip, qtype, qname, rcode FROM netsec.dns_queries WHERE qname = 'icanhazip.com' ORDER BY ts DESC LIMIT 20"
# then name the pod that held that IP at that time (unix seconds after @):
homelab metrics query 'max by (namespace, pod) (max_over_time(kube_pod_info{pod_ip="10.10.3.17"}[10m] @ 1794320586))'
```

Rows cover names outside the cluster only. A pod IP that resolves to a
`node-local-dns` or host-network pod means the query came from the node itself.

### No rows in netsec.dns_queries (`NetsecDnsStale`)

1. node-local-dns still logs: `kubectl -n kube-system logs ds/node-local-dns | grep -c netsec-dns`.
   No lines: the `log` line is gone from the Corefile (`stacks/nodelocal-dns`).
2. Alloy sends: `kubectl -n monitoring logs ds/alloy | grep -i -E 'otlphttp|netsec'` for export errors.
3. Vector receives: `vector_component_received_events_total{namespace="netsec", component_id="otlp"}`.

