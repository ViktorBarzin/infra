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

1. Test: `curl -s -A BlackSun http://example.com/ -o /dev/null` from the devvm, then
   `homelab netsec sql "SELECT ts, in_iface, signature FROM netsec.eve WHERE signature_id = 2008983 ORDER BY ts DESC LIMIT 1"`
   (`ET USER_AGENTS Suspicious User Agent (BlackSun)`; plain HTTP, so Suricata
   sees the header). The older `dig icanhazip.com` test used an `emerging-info`
   rule, and that category is off since 2026-11-11.
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
| `SuricataCaptureDrops` | Suricata missed more than 1% of the packets it should inspect over an hour (blind spots, not dropped traffic) | `docs/runbooks/opnsense.md`, "Suricata tuning", capture section |
| `NetsecHomeHostMalware` | a malware or C2 alert involving one of our hosts (CronJob `netsec-alerts`) | "A home host hit a malware rule" below |
| `CameraVlanBlockedTraffic` | the VLAN 30 camera started traffic the firewall blocked | "Camera VLAN blocked traffic" below |
| `CrowdSecOpnsenseAgentSilent` | OPNsense's agent sent nothing to LAPI for 15 minutes | `ssh root@10.0.10.1 'service crowdsec status'`, `/var/log/crowdsec/crowdsec.log` |
| `CrowdSecOpnsenseBouncerNotPulling` | OPNsense's bouncer pulled nothing for 15 minutes | `service crowdsec_firewall status`, `/var/log/crowdsec/crowdsec-firewall-bouncer.log` |
| `CrowdSecC2MirrorNotPulling` | the C2 blocklist mirror pulled nothing for 15 minutes | `kubectl logs -n crowdsec deploy/crowdsec-c2-mirror` |
| `NetsecProxyStale` | machines are opted in but no Squid row reached `proxy` for 30 minutes (silent while the alias is empty) | "Decryption (phase 5)" below |
| `SquidInterceptDown` | Squid is down while machines are opted in: their web traffic is cut off | `ssh root@10.0.10.1 'configctl proxy restart'`; `/var/log/squid/cache.log`; to stop the impact at once, empty `opted_in` |
| `SquidInterceptCAExpiring` | the interception intermediate expires within 30 days | "CA renewal" below |
| `SquidInterceptMetricsMissing` | the cron `netsec-squid-metrics` on OPNsense stopped writing its metrics | `ssh root@10.0.10.1 /usr/local/bin/netsec-squid-metrics`, then `cat /var/tmp/node_exporter/netsec_squid.prom` |

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
grouped CrowdSec Slack message (the C2 profile still notifies; ban profiles
stopped on 2026-11-11). Run 2026-11-10: all four seen, nothing reached
pf.

## Server journals and pod DNS (phase 4)

### Is the journals agent reading?

```sh
kubectl -n crowdsec logs deploy/crowdsec-journals | tail
kubectl -n crowdsec exec deploy/crowdsec-journals -- cscli metrics show acquisition parsers
homelab metrics query 'cs_lokisource_hits_total{pod=~"crowdsec-journals.*"}'
homelab metrics query 'cs_node_hits_ok_total{pod=~"crowdsec-journals.*", name="crowdsecurity/sshd-logs"}'
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
homelab netsec sql "SELECT ts, toUnixTimestamp(ts) unix, replaceOne(toString(client_ip), '::ffff:', '') ip, qtype, qname, rcode FROM netsec.dns_queries WHERE qname = 'icanhazip.com' ORDER BY ts DESC LIMIT 20"
# then name the pod that held that IP at that moment (unix seconds after @):
homelab metrics query 'kube_pod_info{pod_ip="10.10.108.9"} @ 1794334286'
```

IPv4 clients are stored IPv4-mapped (`::ffff:10.10.108.9`); the query above
strips the prefix. Use the instant query at the row's time, not a window: pod
IPs are reused within minutes, and on 2026-11-10 a 10-minute window returned
both the test pod and an earlier `netsec-alerts` CronJob pod for one address.
Rows cover names outside the cluster only. A pod IP that resolves to a
`node-local-dns` or host-network pod means the query came from the node itself.

### No rows in netsec.dns_queries (`NetsecDnsStale`)

1. node-local-dns still logs: `kubectl -n kube-system logs ds/node-local-dns | grep -c netsec-dns`.
   No lines: the `log` line is gone from the Corefile (`stacks/nodelocal-dns`).
2. Alloy sends: `kubectl -n monitoring logs ds/alloy | grep -i -E 'otlphttp|netsec'` for export errors.
3. Vector receives: `vector_component_received_events_total{namespace="netsec", component_id="otlp"}`.

## Tetragon (phase 4b)

Which program in which pod connected to an address:

```sh
homelab netsec sql "SELECT ts, node, namespace, pod, binary, arguments, parent_binary, dst_port
  FROM netsec.tetragon WHERE event_type = 'connect' AND dst_ip = toIPv6('203.0.113.7')
  ORDER BY ts DESC LIMIT 50"
```

Shells started in application pods (the case Tetragon is for: a web app spawning `sh`):

```sh
homelab netsec sql "SELECT ts, namespace, pod, parent_binary, binary, arguments
  FROM netsec.tetragon WHERE event_type = 'exec' AND ts > now() - INTERVAL 1 DAY
  AND match(binary, '/(ba|da|a)?sh$') AND NOT match(parent_binary, '/(ba|da|a)?sh$|/containerd-shim|/runc')
  ORDER BY ts DESC LIMIT 100"
```

The process tree of one event: `payload.exec_id` and `payload.parent_exec_id` link rows.

Volume by namespace (find what to quiet):

```sh
homelab netsec sql "SELECT event_type, namespace, count() n FROM netsec.tetragon
  WHERE ts > now() - INTERVAL 1 HOUR GROUP BY event_type, namespace ORDER BY n DESC LIMIT 30"
```

Quieting a noisy platform namespace: add it to `local.exec_quiet_namespaces` in
`stacks/tetragon/main.tf` (exec only; its connects stay). Never add an
enforcement action to the policy: the stack is watch-only by decision.

### No rows in netsec.tetragon (`NetsecTetragonStale`)

1. Agents ready: `kubectl -n tetragon get ds tetragon` (also `TetragonNotReady`).
2. Events exported: `kubectl -n tetragon logs ds/tetragon -c export-stdout --tail=3`.
   Empty: check `kubectl -n tetragon get tracingpolicies` and the agent log
   (`-c tetragon`).
3. Alloy sends: `kubectl -n monitoring logs ds/alloy | grep -i -E 'otlphttp|netsec'`.
4. Vector writes: `vector_component_sent_events_total{namespace="netsec", component_id="tetragon_ch"}`.

## Decryption (phase 5)

Squid on OPNsense decrypts HTTP and HTTPS for the machines in the firewall
alias `opted_in` and nobody else. The alias is empty today, so Squid runs but
no traffic reaches it. Design: architecture doc, "Phase 5".

```sh
ssh root@10.0.10.1 'pfctl -t opted_in -T show'          # who is opted in (empty = nobody)
ssh root@10.0.10.1 'pfctl -sn | grep opted_in'           # the redirects (8: 80/443, v4/v6, VLAN 10/20)
ssh root@10.0.10.1 'tail -n 3 /var/log/squid/netsec.json'
homelab netsec sql "SELECT ts, toString(client_ip), method, url, sni, bump_mode, status FROM netsec.proxy ORDER BY ts DESC LIMIT 20"
```

`bump_mode` says what happened to a TLS connection: `bump` was decrypted (the
`url` row after it has the path), `splice` passed through untouched because
its name is on the no-bump list (only the SNI is logged). The `CONNECT` row
with status 0 before each bumped request is Squid's own log of the TLS step.
Query strings are stripped (`?` stays), and no Referer or cookie is logged.

### Opting a machine in

Only with the agreement of whoever uses the machine: it exposes their logins
and messages to the firewall.

1. Install the root certificate as trusted on the machine:
   `playbooks/files/opnsense/netsec-interception-root.pem` (SHA-256
   `87:1D:C9:B2:A2:02:70:CC:68:F0:34:C3:8C:B4:A4:40:D6:7E:AB:8C:D4:94:45:5F:8C:42:CD:B9:D0:A5:9E:B1`).
   Windows: `certutil -addstore Root netsec-interception-root.pem`. Debian or
   Ubuntu: copy to `/usr/local/share/ca-certificates/netsec-root.crt`, then
   `update-ca-certificates`. Firefox keeps its own store
   (`security.enterprise_roots.enabled` on Windows and macOS, or import it).
   Phones: most apps ignore user-installed roots, so only the browser is
   decrypted, and apps that pin certificates fail unless their domains are
   on the no-bump list.
2. Give it a fixed address (Kea reservation in `playbooks/files/opnsense/dhcp.yml`).
   IPv6 must be off on the machine, or fixed and listed too: SLAAC privacy
   addresses change and would bypass Squid.
3. Add the address to `opted_in` in `playbooks/files/opnsense/aliases.yml`
   and apply `--tags aliases` (production flag as usual).
4. Check: `echo | openssl s_client -connect example.com:443 -servername example.com | openssl x509 -noout -issuer`
   on the machine names `Homelab interception intermediate 2026-11`, and rows
   with its address appear in `netsec.proxy` within a minute.

Opting out is the reverse: remove the address from the alias and apply; the
machine is untouched from the next connection on. Remove the root
certificate from it too.

A site that breaks under interception (pinned certificate, client
certificate): add its domain with a leading dot to `opn_squid_nobump` in
`playbooks/tasks/opnsense/squid.yml` and apply `--tags squid`.

### CA renewal

The intermediate that signs Squid's certificates is valid until 2027-11-10;
the root until 2027-12-15. The root's private key was destroyed right after
it signed the intermediate (2026-11-10), so no key exists that could sign
another intermediate. Renewal is therefore a new pair, about a month before
`SquidInterceptCAExpiring` would fire:

```sh
D=/dev/shm/netsec-ca; umask 077; mkdir -m 700 $D; cd $D     # tmpfs: keys never touch disk
openssl ecparam -name prime256v1 -genkey -noout -out root.key
openssl req -new -x509 -key root.key -sha256 -days 400 \
  -subj "/O=viktorbarzin.me homelab/CN=Homelab interception root YYYY-MM" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:1" -addext "keyUsage=critical,keyCertSign,cRLSign" -out root.crt
openssl ecparam -name prime256v1 -genkey -noout -out int.key
openssl req -new -key int.key -subj "/O=viktorbarzin.me homelab/CN=Homelab interception intermediate YYYY-MM" -out int.csr
printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,digitalSignature,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n' > int.ext
openssl x509 -req -in int.csr -CA root.crt -CAkey root.key -CAcreateserial -days 365 -sha256 -extfile int.ext -out int.crt
vault kv patch secret/opnsense squid_ca_intermediate_key=@int.key
cp root.crt ~/code/infra/playbooks/files/opnsense/netsec-interception-root.pem
cp int.crt ~/code/infra/playbooks/files/opnsense/netsec-interception-intermediate.pem
shred -u -z root.key int.key; cd /; rm -rf $D
```

Then change `opn_squid_root_descr` and `opn_squid_int_descr` in
`playbooks/tasks/opnsense/squid.yml` to the new month, apply `--tags squid`
(it imports the new pair and points Squid at it), install the new root on
every opted-in machine, and delete the old two entries in System > Trust >
Authorities once nothing uses them. Commit the two certificates.

### No rows in netsec.proxy (`NetsecProxyStale`)

1. Somebody opted in: `ssh root@10.0.10.1 'pfctl -t opted_in -T show'`.
2. Squid writes: `tail /var/log/squid/netsec.json` on OPNsense. Empty while
   the machine browses: `pfctl -sn | grep opted_in` and `pfctl -vsr | grep opted_in`
   (counters on the redirect pass rules).
3. syslog-ng sends: `syslog-ng-ctl stats | grep netsec_vector_proxy` on OPNsense.
4. Vector writes: `vector_component_sent_events_total{namespace="netsec", component_id="proxy_ch"}`;
   a line that is not JSON is dropped by the `proxy` transform.

### Testing the whole path without a real machine

Done on 2026-11-10: a network namespace on the Proxmox host, attached to
`vmbr1` with VLAN 20 untagged, address 10.0.20.190 (outside the Kea pool and
the LoadBalancer range), IPv6 off, temporarily added to `opted_in` with
`POST /api/firewall/alias_util/add/opted_in {"address":"10.0.20.190"}`.
Result: with the root trusted, `https://example.com/...?token=...` returned
through Squid and logged the path without the token; without it curl failed
with `self-signed certificate in certificate chain`; `www.apple.com` came
back with Apple's own certificate (spliced); plain HTTP was logged; UDP 443
was refused; the devvm, not opted in, kept seeing the real certificate.
Afterwards: `alias_util/delete`, `ip netns del netsec-test`, the veth and
`/etc/netns/netsec-test` removed, the test rows deleted from `netsec.proxy`.
