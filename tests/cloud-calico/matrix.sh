#!/usr/bin/env bash
# Run by cloud-calico.test.sh from inside `tofu test` (a terraform_data
# local-exec that depends on every module), while Cloud's modules have a
# Project in the kind cluster and before the test destroys it.
#
# Cloud's own pods run images that need a real Authentik and registry, so the
# matrix uses probe pods (agnhost) carrying the same component and service
# labels: Calico selects them exactly as it selects Cloud's pods. The Project's
# quota is set aside while they run and put back before the destroy.
#
# Writes one line per check to $CALICO_RESULTS: "ok - what" or "FAIL - what".
#
# Environment: ADMIN_KUBECONFIG, CLOUD_NAMESPACE, CALICO_RESULTS,
# AGNHOST_IMAGE, CALICO_INTERNET (1 to check 1.1.1.1:443).
set -uo pipefail
k() { kubectl --kubeconfig "$ADMIN_KUBECONFIG" "$@"; }
ns="$CLOUD_NAMESPACE"
out="$CALICO_RESULTS"
ok()  { echo "ok   - $1" >>"$out"; }
bad() { echo "FAIL - $1" >>"$out"; }

# The quota counts pods; Cloud's Deployments go to 0 and the quota is set
# aside so the probes fit, then both come back.
k get resourcequota -n "$ns" -o json >"$out.quota.json"
k scale deployment --all -n "$ns" --replicas=0 >/dev/null
k delete resourcequota --all -n "$ns" >/dev/null

probe() { # namespace name labels(json) [port]
  k apply -f - >/dev/null <<EOF
{"apiVersion": "v1", "kind": "Pod",
 "metadata": {"name": "$2", "namespace": "$1", "labels": $3},
 "spec": {
   "securityContext": {"runAsNonRoot": true, "runAsUser": 65534, "seccompProfile": {"type": "RuntimeDefault"}},
   "containers": [{"name": "probe", "image": "$AGNHOST_IMAGE",
     "args": ["netexec", "--http-port=${4:-8080}", "--udp-port=-1"],
     "ports": [{"containerPort": ${4:-8080}}],
     "readinessProbe": {"tcpSocket": {"port": ${4:-8080}}, "periodSeconds": 2},
     "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}},
     "resources": {"requests": {"cpu": "10m", "memory": "32Mi", "ephemeral-storage": "16Mi"},
                   "limits": {"cpu": "100m", "memory": "64Mi", "ephemeral-storage": "32Mi"}}}]}}
EOF
}
C=cloud.viktorbarzin.me/component
S=cloud.viktorbarzin.me/service
E=cloud.viktorbarzin.me/edge-config
A=cloud.viktorbarzin.me/access
# recipes is the private App, menu the public one; both have an oauth2-proxy,
# which listens on its real port, 4180 (app-kit K1: the edge asks it). Edge
# pods carry the Caddyfile digest label E, as modules/app sets it;
# edge-recipes-old is an edge pod from before K1, which has no such label
# and no sign-in check.
probe "$ns" app-recipes "{\"$C\": \"app\", \"$S\": \"recipes\"}"
probe "$ns" edge-recipes "{\"$C\": \"edge\", \"$S\": \"recipes\", \"$E\": \"0123456789abcdef\"}"
probe "$ns" edge-recipes-old "{\"$C\": \"edge\", \"$S\": \"recipes\"}"
probe "$ns" auth-recipes "{\"$C\": \"oauth2-proxy\", \"$S\": \"recipes\"}" 4180
probe "$ns" app-menu "{\"$C\": \"app\", \"$S\": \"menu\"}"
probe "$ns" edge-menu "{\"$C\": \"edge\", \"$S\": \"menu\", \"$E\": \"fedcba9876543210\"}"
probe "$ns" auth-menu "{\"$C\": \"oauth2-proxy\", \"$S\": \"menu\"}" 4180
# pricing is the internal App: no edge, no oauth2-proxy; its pod listens on
# the App port, 3000. menu lists it in connects; recipes does not.
probe "$ns" app-pricing "{\"$C\": \"app\", \"$S\": \"pricing\", \"$A\": \"internal\"}" 3000
# A pod of the private App that listens on the mail ports and on 8080
# (agnhost porter; the sysctl lets it bind ports under 1024 as non-root).
# Its own edge reaches it, so a refused mail port shows the Deny rule.
k apply -f - >/dev/null <<EOF
{"apiVersion": "v1", "kind": "Pod",
 "metadata": {"name": "mail-recipes", "namespace": "$ns", "labels": {"$C": "app", "$S": "recipes"}},
 "spec": {
   "securityContext": {"runAsNonRoot": true, "runAsUser": 65534, "seccompProfile": {"type": "RuntimeDefault"},
     "sysctls": [{"name": "net.ipv4.ip_unprivileged_port_start", "value": "0"}]},
   "containers": [{"name": "probe", "image": "$AGNHOST_IMAGE", "args": ["porter"],
     "env": [{"name": "SERVE_PORT_8080", "value": "ok"}, {"name": "SERVE_PORT_25", "value": "ok"},
             {"name": "SERVE_PORT_465", "value": "ok"}, {"name": "SERVE_PORT_587", "value": "ok"},
             {"name": "SERVE_PORT_2525", "value": "ok"}],
     "readinessProbe": {"tcpSocket": {"port": 25}, "periodSeconds": 2},
     "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}},
     "resources": {"requests": {"cpu": "10m", "memory": "32Mi", "ephemeral-storage": "16Mi"},
                   "limits": {"cpu": "100m", "memory": "64Mi", "ephemeral-storage": "32Mi"}}}]}}
EOF
# Another Project, with an edge pod claiming to front recipes.
probe p-other edge-recipes "{\"$C\": \"edge\", \"$S\": \"recipes\", \"$E\": \"0123456789abcdef\"}"
probe p-other app-other "{\"$C\": \"app\", \"$S\": \"other\"}"
# A third Project with no Project policy at all (its first apply, or a
# failed Calico apply): a public App's pod and an internal App's pod, both
# on the App port. Only the floor stands between them and p-other.
probe p-third app-shop "{\"$C\": \"app\", \"$S\": \"shop\"}" 3000
probe p-third app-quotes "{\"$C\": \"app\", \"$S\": \"quotes\", \"$A\": \"internal\"}" 3000

# Every probe answers its kubelet readiness probe, which comes from the node:
# the floors must not block it.
# Cloud's own pods may still be terminating, so wait for the probes by name.
if k wait --for=condition=Ready -n "$ns" pod/app-recipes pod/mail-recipes pod/edge-recipes pod/edge-recipes-old pod/auth-recipes pod/app-menu pod/edge-menu pod/auth-menu pod/app-pricing --timeout=180s >/dev/null 2>&1 \
  && k wait --for=condition=Ready -n p-other pod/edge-recipes pod/app-other --timeout=60s >/dev/null 2>&1 \
  && k wait --for=condition=Ready -n p-third pod/app-shop pod/app-quotes --timeout=60s >/dev/null 2>&1; then
  ok "every probe pod in $ns and p-other passes the kubelet's readiness probe"
else
  bad "probe pods not Ready: $( (k get pods -n "$ns" --no-headers; k get pods -n p-other --no-headers) 2>&1 | tr '\n' ';')"
fi

ip() { k get pod -n "$1" "$2" -o jsonpath='{.status.podIP}'; }
# reach <src ns> <src pod> <host:port>: the TCP handshake completes.
reach() { k exec -n "$1" "$2" -- /agnhost connect "$3" --timeout=3s >/dev/null 2>&1; }
can()    { if reach "$1" "$2" "$3"; then ok "$4"; else bad "$4: no connection"; fi; }
cannot() { if reach "$1" "$2" "$3"; then bad "$4: connected"; else ok "$4"; fi; }

T=(traefik client)
# Traefik's view: every App's edge, public or private (app-kit K1).
can    "${T[@]}" "$(ip "$ns" edge-menu):8080"     "Traefik reaches a public App's edge"
can    "${T[@]}" "$(ip "$ns" edge-recipes):8080"  "Traefik reaches a private App's edge"
cannot "${T[@]}" "$(ip "$ns" edge-recipes-old):8080" "Traefik does not reach an edge pod without the Caddyfile digest label (pre-K1, no sign-in check)"
cannot "${T[@]}" "$(ip "$ns" app-menu):8080"      "Traefik does not reach a public App's pods"
cannot "${T[@]}" "$(ip "$ns" app-recipes):8080"   "Traefik does not reach a private App's pods"
cannot "${T[@]}" "$(ip "$ns" auth-recipes):4180"  "Traefik does not reach a private App's oauth2-proxy"
cannot "${T[@]}" "$(ip "$ns" auth-menu):4180"     "Traefik does not reach a public App's oauth2-proxy"
# The edges and the oauth2-proxies.
can    "$ns" edge-recipes "$(ip "$ns" auth-recipes):4180" "the private App's edge reaches its own oauth2-proxy on 4180"
can    "$ns" edge-menu "$(ip "$ns" auth-menu):4180"       "the public App's edge reaches its own oauth2-proxy on 4180"
cannot "$ns" edge-recipes "$(ip "$ns" auth-menu):4180"    "an edge does not reach another App's oauth2-proxy"
cannot p-other edge-recipes "$(ip "$ns" auth-recipes):4180" "an edge pod in another Project does not reach this App's oauth2-proxy, even with its service label"
cannot "$ns" app-recipes "$(ip "$ns" auth-recipes):4180"  "App pods do not reach their oauth2-proxy"
cannot "$ns" auth-recipes "$(ip "$ns" edge-recipes):8080" "oauth2-proxy does not reach its edge"
cannot "$ns" auth-recipes "$(ip "$ns" app-recipes):8080"  "oauth2-proxy does not reach its App's pods"
cannot "$ns" auth-recipes "$(ip "$ns" edge-menu):8080"    "oauth2-proxy does not reach another App's edge"
can    "$ns" edge-recipes "$(ip "$ns" app-recipes):8080"  "the private App's edge reaches its own App"
can    "$ns" edge-menu "$(ip "$ns" app-menu):8080"        "the public App's edge reaches its own App"
cannot "$ns" edge-recipes "$(ip "$ns" app-menu):8080"     "an edge does not reach another App's pods"
cannot "$ns" app-menu "$(ip "$ns" app-recipes):8080"      "App pods do not reach another App's pods"
# The internal App: only the App that lists it in connects, on the App port.
pricing="$(ip "$ns" app-pricing):3000"
can    "$ns" app-menu "$pricing"                         "an App reaches the internal App it connects to, on the App port"
cannot "$ns" app-recipes "$pricing"                      "an App that does not list the internal App in connects does not reach it"
cannot p-other app-other "$pricing"                      "an App in another Project does not reach the internal App"
cannot "${T[@]}" "$pricing"                              "Traefik does not reach the internal App"
cannot "$ns" edge-menu "$pricing"                        "an edge does not reach the internal App"
cannot homelab-app client "$pricing"                     "a homelab namespace does not reach the internal App"
# With no Project policy in p-third, the floor alone decides.
cannot p-other app-other "$(ip p-third app-shop):3000"   "with no Project policy, an App in another Project does not reach a public App's pod on the App port (the floor needs access=internal)"
can    p-other app-other "$(ip p-third app-quotes):3000" "with no Project policy, the floor alone passes an internal App's pod on the App port (the Project policy, which modules/app waits for, narrows it)"
# Other namespaces.
cannot p-other edge-recipes "$(ip "$ns" app-recipes):8080" "an edge pod in another Project does not reach this App, even with its service label"
cannot "$ns" app-recipes "$(ip p-other app-other):8080"    "App pods do not reach another Project's pods"
cannot homelab-app client "$(ip "$ns" app-recipes):8080"   "a homelab namespace does not reach App pods"
cannot "$ns" app-recipes "$(ip homelab-app client):8080"   "App pods do not reach a homelab namespace"
# Egress the floor and the Project policy allow.
can    "$ns" app-recipes "$(ip dbaas primary):5432"        "App pods reach the CNPG primary on 5432"
cannot "$ns" app-recipes "$(ip dbaas replica):5432"        "App pods do not reach a CNPG replica"
can    "$ns" app-recipes "10.96.0.10:53"                   "App pods reach DNS on the kube-dns ClusterIP (TCP 53)"
dns_pod="$(k get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[0].status.podIP}')"
can    "$ns" app-recipes "$dns_pod:53"                     "App pods reach a CoreDNS pod (TCP 53)"
can    "$ns" app-recipes "pg.dbaas.svc.cluster.local:5432"  "App pods resolve a Service name through the cluster DNS and reach the primary through it"
cannot "$ns" app-recipes "$(ip authentik server):9000"     "App pods do not reach the Authentik server"
can    "$ns" auth-recipes "$(ip authentik server):9000"    "oauth2-proxy reaches the Authentik server on 9000"
cannot "$ns" auth-recipes "$(ip vault vault):8200"         "oauth2-proxy does not reach Vault"
cannot "$ns" app-recipes "$(ip vault vault):8200"          "App pods do not reach Vault"
cannot "$ns" app-recipes "10.96.0.1:443"                   "App pods do not reach the API server's ClusterIP"
node_ip="$(k get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
cannot "$ns" app-recipes "$node_ip:10250"                  "App pods do not reach the node's kubelet ($node_ip, a private address)"
cannot "$ns" app-recipes "176.12.22.76:443"                "App pods do not reach the home WAN IP 176.12.22.76"
cannot "$ns" app-recipes "92.5.132.215:9100"               "App pods do not reach backup-mx 92.5.132.215 (node_exporter, admitted from the home WAN IP)"
# The mail ports (V8): the pod listens on all of them (its readiness probe
# on 25 passes), its own edge reaches it on 8080, and on none of them.
mail="$(ip "$ns" mail-recipes)"
can    "$ns" edge-recipes "$mail:8080"                     "the private App's edge reaches the mail-port probe on 8080"
for port in 25 465 587 2525; do
  cannot "$ns" edge-recipes "$mail:$port"                  "TCP $port is denied, even to a pod the sender may reach"
done
if [ "${CALICO_INTERNET:-0}" = "1" ]; then
  can "$ns" app-recipes "1.1.1.1:443"                      "App pods reach the internet (1.1.1.1:443)"
  # Resolved here: kind's DNS may not resolve public names, and a lookup
  # failure would make the refusals pass for the wrong reason.
  smtp="$(getent ahostsv4 smtp.gmail.com | awk 'NR==1 {print $1}')"
  if [ -z "$smtp" ]; then
    bad "could not resolve smtp.gmail.com on the test host"
  else
    # smtp.gmail.com answers on 25 and 587 from the devvm, but not on 443
    # (checked 2026-11-16), so 1.1.1.1:443 above is the positive control.
    for port in 25 465 587 2525; do
      cannot "$ns" app-recipes "$smtp:$port"               "App pods do not reach smtp.gmail.com ($smtp) on TCP $port"
    done
  fi
fi

# The floor alone. A Project policy in the default tier that allows every
# connection (a mistaken or hostile reconciler) opens only what the floor
# passes. Traefik reaching the pre-K1 edge pod, which Cloud's policy refuses,
# shows the allow-all is in force; the request path of a private App before
# app-kit K1 (Traefik -> oauth2-proxy -> edge) stays denied by the floor.
k apply -f - >/dev/null <<EOF
{"apiVersion": "projectcalico.org/v3", "kind": "NetworkPolicy",
 "metadata": {"name": "allow-all", "namespace": "$ns"},
 "spec": {"order": 1, "selector": "all()", "types": ["Ingress", "Egress"], "ingress": [{"action": "Allow"}], "egress": [{"action": "Allow"}]}}
EOF
old_edge="$(ip "$ns" edge-recipes-old):8080"
for _ in $(seq 1 30); do reach "${T[@]}" "$old_edge" && break; done
can    "${T[@]}" "$old_edge"                          "with an allow-all Project policy, Traefik reaches what the floor passes (an edge pod Cloud's policy refuses)"
cannot "${T[@]}" "$(ip "$ns" auth-recipes):4180"     "with an allow-all Project policy, the floor still denies Traefik -> oauth2-proxy"
cannot "${T[@]}" "$(ip "$ns" auth-menu):4180"        "with an allow-all Project policy, the floor still denies Traefik -> a public App's oauth2-proxy"
cannot "$ns" auth-recipes "$(ip "$ns" edge-recipes):8080" "with an allow-all Project policy, the floor still denies oauth2-proxy -> edge"
cannot "${T[@]}" "$(ip "$ns" app-recipes):8080"      "with an allow-all Project policy, the floor still denies Traefik -> App pods"
cannot "${T[@]}" "$pricing"                          "with an allow-all Project policy, the floor still denies Traefik -> the internal App"
cannot "$ns" app-menu "$(ip "$ns" app-recipes):8080" "with an allow-all Project policy, the floor still denies App pods -> App pods off the App port"
cannot homelab-app client "$pricing"                 "with an allow-all Project policy, the floor still denies a homelab namespace -> the internal App"
can    "$ns" edge-recipes "$mail:8080"                     "with an allow-all Project policy, the edge still reaches the mail-port probe on 8080"
for port in 25 465 587 2525; do
  cannot "$ns" edge-recipes "$mail:$port"                  "with an allow-all Project policy, the floor still denies TCP $port"
done
k delete networkpolicies.projectcalico.org allow-all -n "$ns" >/dev/null 2>&1 || bad "could not delete the allow-all Project policy"

k delete pod --all -n "$ns" --wait=false >/dev/null 2>&1
python3 -c 'import json,sys; o=json.load(open(sys.argv[1])); [i["metadata"].pop(f, None) for i in o["items"] for f in ["uid","resourceVersion","creationTimestamp","managedFields"]]; [i.pop("status", None) for i in o["items"]]; print(json.dumps(o))' "$out.quota.json" \
  | k create -f - >/dev/null || bad "could not put the Project's quota back"
true
