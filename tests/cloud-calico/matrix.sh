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
# recipes is the private App (oauth2-proxy in front), menu the public one.
probe "$ns" app-recipes "{\"$C\": \"app\", \"$S\": \"recipes\"}"
probe "$ns" edge-recipes "{\"$C\": \"edge\", \"$S\": \"recipes\"}"
probe "$ns" auth-recipes "{\"$C\": \"oauth2-proxy\", \"$S\": \"recipes\"}"
probe "$ns" app-menu "{\"$C\": \"app\", \"$S\": \"menu\"}"
probe "$ns" edge-menu "{\"$C\": \"edge\", \"$S\": \"menu\"}"
# Another Project, with an edge pod claiming to front recipes.
probe p-other edge-recipes "{\"$C\": \"edge\", \"$S\": \"recipes\"}"
probe p-other app-other "{\"$C\": \"app\", \"$S\": \"other\"}"

# Every probe answers its kubelet readiness probe, which comes from the node:
# the floors must not block it.
# Cloud's own pods may still be terminating, so wait for the probes by name.
if k wait --for=condition=Ready -n "$ns" pod/app-recipes pod/edge-recipes pod/auth-recipes pod/app-menu pod/edge-menu --timeout=180s >/dev/null 2>&1 \
  && k wait --for=condition=Ready -n p-other pod/edge-recipes pod/app-other --timeout=60s >/dev/null 2>&1; then
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
# Traefik's view.
can    "${T[@]}" "$(ip "$ns" edge-menu):8080"     "Traefik reaches a public App's edge"
can    "${T[@]}" "$(ip "$ns" auth-recipes):8080"  "Traefik reaches a private App's oauth2-proxy"
cannot "${T[@]}" "$(ip "$ns" app-menu):8080"      "Traefik does not reach a public App's pods"
cannot "${T[@]}" "$(ip "$ns" app-recipes):8080"   "Traefik does not reach a private App's pods"
cannot "${T[@]}" "$(ip "$ns" edge-recipes):8080"  "Traefik does not reach a private App's edge (oauth2-proxy is in front)"
# The oauth2-proxy and the edges.
can    "$ns" auth-recipes "$(ip "$ns" edge-recipes):8080" "oauth2-proxy reaches its own edge"
cannot "$ns" auth-recipes "$(ip "$ns" app-recipes):8080"  "oauth2-proxy does not reach its App's pods"
cannot "$ns" auth-recipes "$(ip "$ns" edge-menu):8080"    "oauth2-proxy does not reach another App's edge"
can    "$ns" edge-recipes "$(ip "$ns" app-recipes):8080"  "the private App's edge reaches its own App"
can    "$ns" edge-menu "$(ip "$ns" app-menu):8080"        "the public App's edge reaches its own App"
cannot "$ns" edge-recipes "$(ip "$ns" app-menu):8080"     "an edge does not reach another App's pods"
cannot "$ns" app-menu "$(ip "$ns" app-recipes):8080"      "App pods do not reach another App's pods"
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
if [ "${CALICO_INTERNET:-0}" = "1" ]; then
  can "$ns" app-recipes "1.1.1.1:443"                      "App pods reach the internet (1.1.1.1:443)"
fi

k delete pod --all -n "$ns" --wait=false >/dev/null 2>&1
python3 -c 'import json,sys; o=json.load(open(sys.argv[1])); [i["metadata"].pop(f, None) for i in o["items"] for f in ["uid","resourceVersion","creationTimestamp","managedFields"]]; [i.pop("status", None) for i in o["items"]]; print(json.dumps(o))' "$out.quota.json" \
  | k create -f - >/dev/null || bad "could not put the Project's quota back"
true
