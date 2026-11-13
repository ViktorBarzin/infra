"""Variants of the objects Cloud's modules really wrote, for cloud-access.test.sh.

Usage: python3 variants.py <dump dir> <out dir> <target namespace>

Reads namespace.json and objects.json (dump.sh), strips what the API server
added, moves every namespaced object into <target namespace>, and writes one
JSON file per case into <out dir> plus cases.tsv, one line per case:

    <file>  <who: kr|ka>  <expect: ok, or a regex the refusal must match>  <what>

kr is the reconciler, ka is admin. Each object as rendered must be admitted;
each variant changes one thing the M2 contract forbids and must be refused
with that rule's message. The test sends every case as a server-side dry run.
"""

import copy
import json
import pathlib
import sys

dump, out, target = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
out.mkdir(parents=True, exist_ok=True)

namespace = json.loads((dump / "namespace.json").read_text())
objects = json.loads((dump / "objects.json").read_text())["items"]

SERVER_FIELDS = ["uid", "resourceVersion", "creationTimestamp", "managedFields", "generation", "selfLink", "ownerReferences"]
SERVER_ANNOTATIONS = ["deployment.kubernetes.io/revision"]
COMPONENT = "cloud.viktorbarzin.me/component"
EDGE = "edge"

cases = []


def clean(obj):
    o = copy.deepcopy(obj)
    o.pop("status", None)
    md = o["metadata"]
    for f in SERVER_FIELDS:
        md.pop(f, None)
    anns = md.get("annotations") or {}
    for a in SERVER_ANNOTATIONS:
        anns.pop(a, None)
    if not anns:
        md.pop("annotations", None)
    if o["kind"] == "Service":
        for f in ["clusterIP", "clusterIPs"]:
            o["spec"].pop(f, None)
    if o["kind"] != "Namespace":
        md["namespace"] = target
    return o


def case(name, who, expect, what, obj):
    path = out / f"{len(cases):03d}-{name}.json"
    path.write_text(json.dumps(obj))
    cases.append((path.name, who, expect, what))


def of_kind(kind, **labels):
    found = [clean(o) for o in objects if o["kind"] == kind and all(o["metadata"].get("labels", {}).get(k) == v for k, v in labels.items())]
    return sorted(found, key=lambda o: o["metadata"]["name"])


def one(kind, name):
    found = [clean(o) for o in objects if o["kind"] == kind and o["metadata"]["name"] == name]
    assert len(found) == 1, f"{kind} {name}: found {len(found)}"
    return found[0]


def variant(obj, change):
    o = copy.deepcopy(obj)
    change(o)
    return o


# --- the namespace ------------------------------------------------------------
ns = clean(namespace)
ns["metadata"]["name"] = "p-variant"
ns["metadata"]["labels"].pop("kubernetes.io/metadata.name", None)
case("ns", "kr", "ok", "the rendered namespace (as p-variant)", ns)
case("ns-baseline", "kr", "must carry", "namespace with Pod Security enforce=baseline",
     variant(ns, lambda o: o["metadata"]["labels"].update({"pod-security.kubernetes.io/enforce": "baseline"})))
for key in ["resource-governance/custom-quota", "resource-governance/custom-limitrange", "pod-security.kubernetes.io/enforce"]:
    case("ns-no-" + key.split("/")[-1], "kr", "must carry", f"namespace without {key}",
         variant(ns, lambda o, k=key: o["metadata"]["labels"].pop(k)))
case("ns-extra-label", "kr", "may set only these namespace labels", "namespace with chrome-service.viktorbarzin.me/client=true",
     variant(ns, lambda o: o["metadata"]["labels"].update({"chrome-service.viktorbarzin.me/client": "true"})))

# --- every object as rendered, admitted --------------------------------------
KINDS = ["ConfigMap", "Service", "Deployment", "Ingress", "ResourceQuota", "LimitRange", "SecretStore", "ExternalSecret", "RoleBinding"]
MANAGED = {"cloud.viktorbarzin.me/managed": "true"}
for kind in KINDS:
    for o in of_kind(kind, **MANAGED):
        case(f"{kind.lower()}-{o['metadata']['name']}", "kr", "ok", f"rendered {kind} {o['metadata']['name']}", o)

# --- Deployments ----------------------------------------------------------------
apps = of_kind("Deployment", **{COMPONENT: "app"})
proxies = of_kind("Deployment", **{COMPONENT: "oauth2-proxy"})
assert apps and proxies, "the render needs an App and a private App's oauth2-proxy"
app = apps[0]
proxy = proxies[0]
assert any(c["name"] == "cookie-strip" for c in app["spec"]["template"]["spec"]["containers"])


def spec_of(o):
    return o["spec"]["template"]["spec"] if o["kind"] == "Deployment" else o["spec"]


def containers(o, name):
    return [c for c in spec_of(o)["containers"] if c["name"] == name]


case("deploy-no-strip", "kr", "holds a container named cookie-strip", "App Deployment without the cookie-strip container",
     variant(app, lambda o: spec_of(o).update({"containers": [c for c in spec_of(o)["containers"] if c["name"] != "cookie-strip"]})))
case("deploy-strip-image", "kr", "holds a container named cookie-strip", "App Deployment whose cookie-strip runs caddy:latest",
     variant(app, lambda o: containers(o, "cookie-strip")[0].update({"image": "docker.io/library/caddy:latest"})))
def drop_component(o):
    o["spec"]["template"]["metadata"]["labels"].pop(COMPONENT)
    o["spec"]["selector"]["matchLabels"].pop(COMPONENT)
    o["metadata"]["labels"].pop(COMPONENT)


case("deploy-no-component", "kr", "are labelled cloud.viktorbarzin.me/component", "Deployment whose pods carry no component label",
     variant(proxy, drop_component))


def init_container(s):
    c = s["containers"][0]
    s["initContainers"] = [{"name": "init", "image": c["image"], "securityContext": c.get("securityContext", {}), "resources": c.get("resources", {})}]


# Pod-level rules, checked on the App Deployment and on a pod made from its
# template. Each: name, change, expected message.
POD_RULES = [
    # Pod Security restricted refuses some of these on a pod before the
    # policy runs; on a Deployment only the policy refuses them.
    ("nfs", lambda s: s["volumes"].append({"name": "x", "nfs": {"server": "192.168.1.127", "path": "/srv/nfs"}}), "may use only emptyDir|violates PodSecurity"),
    ("ephemeral", lambda s: s["volumes"].append({"name": "x", "ephemeral": {"volumeClaimTemplate": {"spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "1Gi"}}}}}}), "may use only emptyDir"),
    ("csi", lambda s: s["volumes"].append({"name": "x", "csi": {"driver": "nfs.csi.k8s.io"}}), "may use only emptyDir"),
    ("pvc", lambda s: s["volumes"].append({"name": "x", "persistentVolumeClaim": {"claimName": "data"}}), "may use only emptyDir"),
    ("hostpath", lambda s: s["volumes"].append({"name": "x", "hostPath": {"path": "/"}}), "may use only emptyDir|violates PodSecurity"),
    ("runtimeclass", lambda s: s.update({"runtimeClassName": "nvidia"}), "may not set runtimeClassName"),
    ("nodename", lambda s: s.update({"nodeName": "k8s-master"}), "may not set nodeName"),
    ("nodeselector", lambda s: s.update({"nodeSelector": {"kubernetes.io/hostname": "k8s-node1"}}), "may not set nodeSelector"),
    ("affinity", lambda s: s.update({"affinity": {"nodeAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": {"nodeSelectorTerms": [{"matchExpressions": [{"key": "kubernetes.io/hostname", "operator": "In", "values": ["k8s-node1"]}]}]}}}}), "may not set affinity"),
    ("toleration", lambda s: s.update({"tolerations": [{"key": "node-role.kubernetes.io/control-plane", "operator": "Exists", "effect": "NoSchedule"}]}), "default not-ready and unreachable tolerations"),
    ("hostnetwork", lambda s: s.update({"hostNetwork": True}), "host network|violates PodSecurity"),
    ("priority", lambda s: s.update({"priorityClassName": "tier-0-core"}), "only priority class tier-4-aux"),
    ("gpu", lambda s: s["containers"][0].setdefault("resources", {}).setdefault("limits", {}).update({"nvidia.com/gpu": "1"}), "no GPU or other extended resource"),
    ("serviceaccount", lambda s: s.update({"serviceAccountName": "cloud-secrets"}), "runs as service account default"),
    ("init", init_container, "may not have init containers"),
    ("edge-on-app", lambda s: [c.update({"ports": [{"name": EDGE, "containerPort": 3001}]}) for c in s["containers"] if c["name"] == "app"], "only a container named cookie-strip"),
]
for name, change, expect in POD_RULES:
    case(f"deploy-{name}", "kr", expect, f"App Deployment with {name}", variant(app, lambda o, ch=change: ch(spec_of(o))))

pod = {
    "apiVersion": "v1",
    "kind": "Pod",
    "metadata": {"name": "rendered-app-pod", "namespace": target, "labels": app["spec"]["template"]["metadata"]["labels"],
                 "annotations": app["spec"]["template"]["metadata"].get("annotations", {})},
    "spec": copy.deepcopy(app["spec"]["template"]["spec"]),
}
case("pod", "ka", "ok", "a pod from the rendered App template (Pod Security restricted and cloud-managed-pod)", pod)
for name, change, expect in POD_RULES:
    case(f"pod-{name}", "ka", expect, f"pod with {name}", variant(pod, lambda o, ch=change: ch(spec_of(o))))
# Kyverno's inject-gpu-workload-priority gives a GPU pod priority class
# gpu-workload before validation; the refusal must still name the GPU.
case("pod-gpu-kyverno", "ka", "no GPU or other extended resource", "GPU pod after Kyverno set priority class gpu-workload",
     variant(pod, lambda o: (o["spec"]["containers"][0].setdefault("resources", {}).setdefault("limits", {}).update({"nvidia.com/gpu": "1"}),
                             o["spec"].update({"priorityClassName": "gpu-workload"}))))

# --- Kubernetes Services ----------------------------------------------------------
svc = [s for s in of_kind("Service", **{COMPONENT: "app"})][0]
case("svc-edge-number", "kr", "must target the container port named edge", "edge Service port targeting a number",
     variant(svc, lambda o: [p.update({"targetPort": 3000}) for p in o["spec"]["ports"] if p["name"] == EDGE]))
case("svc-edge-other", "kr", "must target the container port named edge", "edge Service port targeting port app",
     variant(svc, lambda o: [p.update({"targetPort": "app"}) for p in o["spec"]["ports"] if p["name"] == EDGE]))
case("svc-nodeport", "kr", "must be type ClusterIP", "NodePort Service",
     variant(svc, lambda o: o["spec"].update({"type": "NodePort"})))

# --- Ingresses ----------------------------------------------------------------------
ingresses = of_kind("Ingress")
public = [i for i in ingresses if "traefik.ingress.kubernetes.io/router.middlewares" in i["metadata"].get("annotations", {})]
assert public, "the render needs a public App"
ing = public[0]


def annotate(k, v):
    return lambda o: o["metadata"].setdefault("annotations", {}).update({k: v})


def paths(o):
    return [p for r in o["spec"]["rules"] for p in r["http"]["paths"]]


for key, value in [("external-dns.alpha.kubernetes.io/hostname", "wpad.viktorbarzin.lan"), ("external-dns.alpha.kubernetes.io/target", "10.0.10.10"),
                   ("gethomepage.dev/enabled", "true"), ("uptime.viktorbarzin.me/external-monitor", "true"),
                   ("traefik.ingress.kubernetes.io/router.tls", "true"), ("traefik.ingress.kubernetes.io/router.priority", "100000")]:
    case("ing-ann-" + key.replace("/", "-"), "kr", "only annotations an Ingress may set", f"Ingress with annotation {key}", variant(ing, annotate(key, value)))
case("ing-entrypoint-web", "kr", "router.entrypoints: websecure", "Ingress on entrypoint web",
     variant(ing, annotate("traefik.ingress.kubernetes.io/router.entrypoints", "web")))
case("ing-own-middleware", "kr", "router.middlewares may name only", "Ingress naming a Middleware in its own namespace",
     variant(ing, annotate("traefik.ingress.kubernetes.io/router.middlewares", f"{target}-buffer@kubernetescrd")))
case("ing-foreign-middleware", "kr", "router.middlewares may name only", "Ingress naming another namespace's Middleware",
     variant(ing, annotate("traefik.ingress.kubernetes.io/router.middlewares", "terminal-tl-proxy-secret@kubernetescrd")))
case("ing-port-number", "kr", "backend is a Kubernetes Service port named edge", "Ingress backend by port number",
     variant(ing, lambda o: [p["backend"]["service"].update({"port": {"number": 80}}) for p in paths(o)]))
case("ing-port-http", "kr", "backend is a Kubernetes Service port named edge", "Ingress backend on port http (oauth2-proxy)",
     variant(ing, lambda o: [p["backend"]["service"].update({"name": "auth-recipes", "port": {"name": "http"}}) for p in paths(o)]))
case("ing-no-class", "kr", "ingressClassName traefik", "Ingress without ingressClassName",
     variant(ing, lambda o: o["spec"].pop("ingressClassName")))
case("ing-tls-secret", "kr", "tls.secretName", "Ingress with tls.secretName",
     variant(ing, lambda o: [t.update({"secretName": "tls-secret"}) for t in o["spec"]["tls"]]))
case("ing-reserved", "kr", "reserved name", "Ingress for vault.viktorbarzin.me",
     variant(ing, lambda o: ([r.update({"host": "vault.viktorbarzin.me"}) for r in o["spec"]["rules"]], [t.update({"hosts": ["vault.viktorbarzin.me"]}) for t in o["spec"]["tls"]])))

# --- ResourceQuota and LimitRange -------------------------------------------------------
quota = one("ResourceQuota", "cloud-quota")
limits = one("LimitRange", "cloud-limits")
MANAGED_BY = "app.kubernetes.io/managed-by"
case("quota-unlabelled", "kr", "may write only ResourceQuota cloud-quota", "quota without managed-by=cloud",
     variant(quota, lambda o: o["metadata"]["labels"].pop(MANAGED_BY)))
case("quota-renamed", "kr", "may write only ResourceQuota cloud-quota", "a second quota, named extra",
     variant(quota, lambda o: o["metadata"].update({"name": "extra"})))
case("quota-tier", "kr", "may write only ResourceQuota cloud-quota", "a quota named tier-quota, as Kyverno's",
     variant(quota, lambda o: (o["metadata"].update({"name": "tier-quota"}), o["metadata"]["labels"].pop(MANAGED_BY))))
# The API server allows a scope only on a quota of pod resources, so the
# scoped variant also drops the PersistentVolumeClaim and Service keys.
def scoped(o):
    for k in ["persistentvolumeclaims", "services.loadbalancers", "services.nodeports"]:
        o["spec"]["hard"].pop(k)
    o["spec"]["scopeSelector"] = {"matchExpressions": [{"scopeName": "PriorityClass", "operator": "In", "values": ["tier-0-core"]}]}


case("quota-scoped", "kr", "must have no scopes", "quota that counts only tier-0-core pods", variant(quota, scoped))
for key in ["limits.cpu", "pods"]:
    case(f"quota-no-{key}", "kr", "must have no scopes", f"quota without {key}", variant(quota, lambda o, k=key: o["spec"]["hard"].pop(k)))
case("quota-pvc", "kr", "must have no scopes", "quota allowing PersistentVolumeClaims",
     variant(quota, lambda o: o["spec"]["hard"].update({"persistentvolumeclaims": "5"})))
case("limits-unlabelled", "kr", "LimitRange cloud-limits", "limit range without managed-by=cloud",
     variant(limits, lambda o: o["metadata"]["labels"].pop(MANAGED_BY)))

# --- SecretStore and ExternalSecrets -------------------------------------------------------
store = one("SecretStore", "cloud-vault")
case("store-role", "kr", "role cloud-project", "SecretStore with Vault role eso",
     variant(store, lambda o: o["spec"]["provider"]["vault"]["auth"]["kubernetes"].update({"role": "eso"})))
for es in of_kind("ExternalSecret"):
    case(f"es-cluster-{es['metadata']['name']}", "kr", "must be a SecretStore", f"ExternalSecret {es['metadata']['name']} on the vault-kv ClusterSecretStore",
         variant(es, lambda o: o["spec"]["secretStoreRef"].update({"kind": "ClusterSecretStore", "name": "vault-kv"})))

# --- Middlewares -------------------------------------------------------------------------
mw = {"apiVersion": "traefik.io/v1alpha1", "kind": "Middleware", "metadata": {"name": "buffer", "namespace": target},
      "spec": {"buffering": {"maxRequestBodyBytes": 10737418240, "memRequestBodyBytes": 10737418240}}}
case("mw-buffering", "kr", "forbidden|no Traefik Middleware", "a buffering Middleware from the reconciler", mw)
case("mw-buffering-admin", "ka", "no Traefik Middleware", "a buffering Middleware from admin", mw)
case("mw-headers-admin", "ka", "no Traefik Middleware", "a headers Middleware from admin",
     dict(mw, spec={"headers": {"customResponseHeaders": {"X-Frame-Options": "DENY"}}}))

with open(out / "cases.tsv", "w") as f:
    for c in cases:
        f.write("\t".join(c) + "\n")

# What the real apply produced, for the test's own checks.
summary = {
    "deployments": sorted(o["metadata"]["name"] for o in objects if o["kind"] == "Deployment"),
    "pods": sorted(o["metadata"]["labels"].get("cloud.viktorbarzin.me/service", "") + "/" + o["metadata"]["labels"].get(COMPONENT, "") for o in objects if o["kind"] == "Pod"),
    "kinds": sorted({o["kind"] for o in objects}),
}
(out / "summary.json").write_text(json.dumps(summary))
