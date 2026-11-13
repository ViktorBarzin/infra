"""Variants of the objects Cloud's modules really wrote, for cloud-access.test.sh.

Usage: python3 variants.py <dump dir> <out dir> <target namespace> [admitted-only]

Reads namespace.json and objects.json (dump.sh), strips what the API server
added, moves every namespaced object into <target namespace>, and writes one
JSON file per case into <out dir> plus cases.tsv, one line per case:

    <file>  <who: kr|ka>  <expect: ok, or a regex the refusal must match>  <what>

kr is the reconciler, ka is admin. Each object as rendered must be admitted;
each variant changes one thing the M2 contract forbids and must be refused
with that rule's message. The test sends every case as a server-side dry run.

admitted-only writes only the cases that must be admitted: the namespace,
every rendered object, and a pod made from each Deployment's template. The
test uses it for Cloud's snapshot fixtures, which need not hold every kind
(a Postgres-only Project has no Deployment).
"""

import copy
import json
import pathlib
import sys

dump, out, target = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
admitted_only = sys.argv[4:] == ["admitted-only"]
out.mkdir(parents=True, exist_ok=True)

namespace = json.loads((dump / "namespace.json").read_text())
SOURCE_NS = namespace["metadata"]["name"]
objects = json.loads((dump / "objects.json").read_text())["items"]

SERVER_FIELDS = ["uid", "resourceVersion", "creationTimestamp", "managedFields", "generation", "selfLink", "ownerReferences"]
SERVER_ANNOTATIONS = ["deployment.kubernetes.io/revision"]
COMPONENT = "cloud.viktorbarzin.me/component"
EDGE = "edge"
SERVICE = "cloud.viktorbarzin.me/service"

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
    # The edge's Caddyfile names its App's Service by namespace, and the
    # oauth2-proxy's args name its edge Service by namespace; the policies
    # check both against the namespace, so follow the move.
    if o["kind"] == "ConfigMap" and md["name"].startswith("edge-"):
        o["data"]["Caddyfile"] = o["data"]["Caddyfile"].replace(f".{SOURCE_NS}.svc.", f".{target}.svc.")
    if o["kind"] == "Deployment":
        for c in o["spec"]["template"]["spec"]["containers"]:
            if "args" in c:
                c["args"] = [a.replace(f".{SOURCE_NS}.svc.", f".{target}.svc.") for a in c["args"]]
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


def as_pod(d, name):
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {"name": name, "namespace": target, "labels": d["spec"]["template"]["metadata"]["labels"],
                     "annotations": d["spec"]["template"]["metadata"].get("annotations", {})},
        "spec": copy.deepcopy(d["spec"]["template"]["spec"]),
    }


def finish():
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


def variant(obj, change):
    o = copy.deepcopy(obj)
    change(o)
    return o


# --- the namespace ------------------------------------------------------------
ns = clean(namespace)
ns["metadata"]["name"] = "p-variant"
ns["metadata"]["labels"].pop("kubernetes.io/metadata.name", None)
case("ns", "kr", "ok", "the rendered namespace (as p-variant)", ns)
if not admitted_only:
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

if admitted_only:
    for d in of_kind("Deployment", **MANAGED):
        case(f"pod-of-{d['metadata']['name']}", "ka", "ok", f"a pod from the rendered {d['metadata']['name']} template", as_pod(d, f"rendered-{d['metadata']['name']}"))
    finish()
    sys.exit(0)

# --- Deployments ----------------------------------------------------------------
apps = of_kind("Deployment", **{COMPONENT: "app"})
edges = of_kind("Deployment", **{COMPONENT: "edge"})
proxies = of_kind("Deployment", **{COMPONENT: "oauth2-proxy"})
assert apps and edges and proxies, "the render needs an App, its edge and a private App's oauth2-proxy"
app = apps[0]
edge = edges[0]
proxy = proxies[0]
assert all(c["name"] != "cookie-strip" for o in apps for c in o["spec"]["template"]["spec"]["containers"]), "the edge runs in its own pod"


def spec_of(o):
    return o["spec"]["template"]["spec"] if o["kind"] == "Deployment" else o["spec"]


def meta_of(o):
    return o["spec"]["template"]["metadata"] if o["kind"] == "Deployment" else o["metadata"]


def relabel(component):
    def f(o):
        for m in ([o["metadata"], o["spec"]["template"]["metadata"]] + ([{"labels": o["spec"]["selector"]["matchLabels"]}] if o["kind"] == "Deployment" else [])):
            m["labels"][COMPONENT] = component
    return f


def drop_component(o):
    o["spec"]["template"]["metadata"]["labels"].pop(COMPONENT)
    o["spec"]["selector"]["matchLabels"].pop(COMPONENT)
    o["metadata"]["labels"].pop(COMPONENT)


COMPONENT_MSG = "a pod is labelled cloud.viktorbarzin.me/component"
case("deploy-no-component", "kr", COMPONENT_MSG, "Deployment whose pods carry no component label", variant(proxy, drop_component))
case("deploy-component-other", "kr", COMPONENT_MSG, "Deployment whose pods are component=worker", variant(app, relabel("worker")))


def app_container_alone():
    """The App's container without its volume mounts, to add to another pod."""
    c = copy.deepcopy(app_c(spec_of(app)))
    c.pop("volumeMounts", None)
    return c


def init_container(s):
    c = s["containers"][0]
    s["initContainers"] = [{"name": "init", "image": c["image"], "securityContext": c.get("securityContext", {}), "resources": c.get("resources", {})}]


def app_c(s):
    return [c for c in s["containers"] if c["name"] == "app"][0]


def probe_host(s):
    app_c(s)["livenessProbe"] = {"httpGet": {"host": "192.168.1.1", "path": "/", "port": 80}}


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
    ("emptydir-unbounded", lambda s: [v["emptyDir"].pop("sizeLimit") for v in s["volumes"] if "emptyDir" in v], "every emptyDir sets a sizeLimit"),
    ("no-ephemeral-limit", lambda s: app_c(s)["resources"]["limits"].pop("ephemeral-storage"), "sets an ephemeral-storage limit"),
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
    ("share-pid", lambda s: s.update({"shareProcessNamespace": True}), "may not share its process namespace"),
    ("probe-host", probe_host, "may not name a host|violates PodSecurity"),
]
for name, change, expect in POD_RULES:
    case(f"deploy-{name}", "kr", expect, f"App Deployment with {name}", variant(app, lambda o, ch=change: ch(spec_of(o))))



pod = as_pod(app, "rendered-app-pod")
case("pod", "ka", "ok", "a pod from the rendered App template (Pod Security restricted and cloud-managed-pod)", pod)
case("pod-edge", "ka", "ok", "a pod from the rendered edge template", as_pod(edge, "rendered-edge-pod"))
case("pod-proxy", "ka", "ok", "a pod from the rendered oauth2-proxy template", as_pod(proxy, "rendered-proxy-pod"))
for name, change, expect in POD_RULES:
    case(f"pod-{name}", "ka", expect, f"pod with {name}", variant(pod, lambda o, ch=change: ch(spec_of(o))))
# Kyverno's inject-gpu-workload-priority gives a GPU pod priority class
# gpu-workload before validation; the refusal must still name the GPU.
case("pod-gpu-kyverno", "ka", "no GPU or other extended resource", "GPU pod after Kyverno set priority class gpu-workload",
     variant(pod, lambda o: (o["spec"]["containers"][0].setdefault("resources", {}).setdefault("limits", {}).update({"nvidia.com/gpu": "1"}),
                             o["spec"].update({"priorityClassName": "gpu-workload"}))))
PROM = "prometheus.io/\\* annotations"
case("deploy-prometheus", "kr", PROM, "App Deployment whose pods ask to be scraped",
     variant(app, lambda o: meta_of(o).setdefault("annotations", {}).update({"prometheus.io/scrape": "true", "prometheus.io/port": "3000"})))
case("pod-prometheus", "ka", PROM, "pod asking to be scraped",
     variant(pod, lambda o: meta_of(o).setdefault("annotations", {}).update({"prometheus.io/scrape": "true"})))

# --- the edge Deployment ------------------------------------------------------------
E_ONE = "an edge pod has one container, edge"
E_RUNS = "the edge runs as Cloud renders it"
E_PORT = "the edge has one port, edge = 8080"
E_PROBE = "the edge has a tcpSocket readiness probe"
E_MOUNTS = "the edge mounts only ConfigMap edge-"


def ec(s):
    return s["containers"][0]


def mount(s, path):
    return [m for m in ec(s)["volumeMounts"] if m["mountPath"] == path][0]


EDGE_RULES = [
    ("image", lambda s: ec(s).update({"image": "docker.io/library/caddy:latest"}), E_ONE),
    ("renamed", lambda s: ec(s).update({"name": "caddy"}), E_ONE),
    ("app-image", lambda s: ec(s).update({"image": app_c(spec_of(app))["image"]}), E_ONE),
    ("second-container", lambda s: s["containers"].append(app_container_alone()), E_ONE),
    ("command", lambda s: ec(s).update({"command": ["/bin/sh", "-c", "caddy reverse-proxy --from :8080 --to app-x:80"]}), E_RUNS),
    ("args", lambda s: ec(s).update({"args": ["caddy", "run", "--config", "/run/caddy/Caddyfile", "--adapter", "caddyfile"]}), E_RUNS),
    ("env", lambda s: ec(s)["env"].append({"name": "CADDY_ADMIN", "value": "0.0.0.0:2019"}), E_RUNS),
    ("env-from", lambda s: ec(s)["env"][0].update({"valueFrom": {"configMapKeyRef": {"name": "x", "key": "y"}}, "value": None}) or ec(s)["env"][0].pop("value"), E_RUNS),
    ("envfrom", lambda s: ec(s).update({"envFrom": [{"configMapRef": {"name": "x"}}]}), E_RUNS),
    ("poststart", lambda s: ec(s).update({"lifecycle": {"postStart": {"exec": {"command": ["/bin/sh", "-c", "true"]}}}}), E_RUNS),
    ("liveness", lambda s: ec(s).update({"livenessProbe": {"exec": {"command": ["/bin/sh", "-c", "true"]}}}), E_RUNS),
    ("port-9090", lambda s: ec(s)["ports"][0].update({"containerPort": 9090}), E_PORT),
    ("port-renamed", lambda s: ec(s)["ports"][0].update({"name": "web"}), E_PORT),
    ("second-port", lambda s: ec(s)["ports"].append({"name": "admin", "containerPort": 2019}), E_PORT),
    ("no-probe", lambda s: ec(s).pop("readinessProbe"), E_PROBE),
    ("exec-probe", lambda s: ec(s).update({"readinessProbe": {"exec": {"command": ["/bin/true"]}, "periodSeconds": 5}}), E_PROBE),
    ("probe-other-port", lambda s: ec(s)["readinessProbe"]["tcpSocket"].update({"port": 9090}), E_PROBE),
    ("config-emptydir", lambda s: (s["volumes"].append({"name": "shared", "emptyDir": {"sizeLimit": "1Mi"}}), mount(s, "/etc/caddy").update({"name": "shared"})), E_MOUNTS),
    ("config-other-cm", lambda s: [v["configMap"].update({"name": "edge-other"}) for v in s["volumes"] if "configMap" in v], E_MOUNTS),
    ("config-emails-cm", lambda s: [v["configMap"].update({"name": "auth-recipes"}) for v in s["volumes"] if "configMap" in v], E_MOUNTS),
    ("config-items", lambda s: [v["configMap"].update({"items": [{"key": "Caddyfile", "path": "Caddyfile"}]}) for v in s["volumes"] if "configMap" in v], E_MOUNTS),
    ("config-subpath", lambda s: mount(s, "/etc/caddy").update({"subPath": "Caddyfile"}), E_MOUNTS),
    ("config-writable", lambda s: mount(s, "/etc/caddy").update({"readOnly": False}), E_MOUNTS),
    ("extra-mount", lambda s: (s["volumes"].append({"name": "tmp", "emptyDir": {"sizeLimit": "1Mi"}}), ec(s)["volumeMounts"].append({"name": "tmp", "mountPath": "/tmp"})), E_MOUNTS),
]
for name, change, expect in EDGE_RULES:
    case(f"edge-{name}", "kr", expect, f"edge Deployment with {name}", variant(edge, lambda o, ch=change: ch(spec_of(o))))
case("edge-pod-port-9090", "ka", E_PORT, "edge pod with port edge = 9090", variant(as_pod(edge, "edge-9090"), lambda o: ec(spec_of(o))["ports"][0].update({"containerPort": 9090})))
case("app-as-edge", "kr", E_ONE, "App Deployment labelled component=edge", variant(app, relabel("edge")))

# --- the oauth2-proxy Deployment -----------------------------------------------------
A_ONE = "an oauth2-proxy pod has one container, oauth2-proxy"
A_RUNS = "the oauth2-proxy runs as Cloud renders it"
A_PORT = "the oauth2-proxy has one port, http = 4180"
A_MOUNTS = "the oauth2-proxy mounts only ConfigMap auth-"


def arg(prefix, value):
    def f(s):
        args = ec(s)["args"]
        i = [n for n, a in enumerate(args) if a.startswith(prefix + "=")]
        assert len(i) == 1, f"no single {prefix} in {args}"
        args[i[0]] = f"{prefix}={value}"
    return f


PROXY_RULES = [
    ("image", lambda s: ec(s).update({"image": "quay.io/oauth2-proxy/oauth2-proxy:latest"}), A_ONE),
    ("app-image", lambda s: ec(s).update({"image": app_c(spec_of(app))["image"]}), A_ONE),
    ("second-container", lambda s: s["containers"].append(app_container_alone()), A_ONE),
    ("command", lambda s: ec(s).update({"command": ["/bin/oauth2-proxy"]}), A_RUNS),
    ("upstream-app", arg("--upstream", f"http://app-recipes.{target}.svc.cluster.local:80/"), A_RUNS),
    ("upstream-other-ns", arg("--upstream", "http://edge-recipes.p-other.svc.cluster.local:80/"), A_RUNS),
    ("upstream-vault", arg("--upstream", "http://vault-active.vault.svc.cluster.local:8200/"), A_RUNS),
    ("client-id", arg("--client-id", "kubernetes"), A_RUNS),
    ("cookie-domain-parent", arg("--cookie-domain", ".viktorbarzin.me"), A_RUNS),
    ("other-host", arg("--redirect-url", "https://menu.viktorbarzin.me/oauth2/callback"), A_RUNS),
    ("issuer", arg("--oidc-issuer-url", "https://evil.example.com/"), A_RUNS),
    ("skip-jwt", lambda s: ec(s)["args"].append("--skip-jwt-bearer-tokens=true"), A_RUNS),
    ("email-domain", lambda s: ec(s)["args"].append("--email-domain=*"), A_RUNS),
    ("env", lambda s: ec(s).update({"env": [{"name": "OAUTH2_PROXY_EMAIL_DOMAINS", "value": "*"}]}), A_RUNS),
    ("envfrom-other", lambda s: ec(s)["envFrom"][0]["secretRef"].update({"name": "env-recipes"}), A_RUNS),
    ("envfrom-cm", lambda s: ec(s)["envFrom"].append({"configMapRef": {"name": "auth-recipes"}}), A_RUNS),
    ("exec-probe", lambda s: ec(s).update({"livenessProbe": {"exec": {"command": ["/bin/true"]}}}), A_RUNS),
    ("port", lambda s: ec(s)["ports"][0].update({"containerPort": 8080}), A_PORT),
    ("second-port", lambda s: ec(s)["ports"].append({"name": "metrics", "containerPort": 44180}), A_PORT),
    ("emails-other-cm", lambda s: [v["configMap"].update({"name": "auth-menu"}) for v in s["volumes"] if "configMap" in v], A_MOUNTS),
    ("emails-writable", lambda s: ec(s)["volumeMounts"][0].update({"readOnly": False}), A_MOUNTS),
]
for name, change, expect in PROXY_RULES:
    case(f"proxy-{name}", "kr", expect, f"oauth2-proxy Deployment with {name}", variant(proxy, lambda o, ch=change: ch(spec_of(o))))
case("app-as-proxy", "kr", A_ONE, "App Deployment labelled component=oauth2-proxy (Calico lets those reach Authentik)", variant(app, relabel("oauth2-proxy")))

# --- Kubernetes Services ----------------------------------------------------------
edge_svc = one("Service", "edge-recipes")
auth_svc = one("Service", "auth-recipes")
E_SVC = "Service edge-<app> selects"
A_SVC = "Service auth-<app> selects"
case("svc-edge-selects-app", "kr", E_SVC, "edge Service selecting the App pods",
     variant(edge_svc, lambda o: o["spec"]["selector"].update({COMPONENT: "app"})))
case("svc-edge-no-component", "kr", E_SVC, "edge Service selecting the App's pods of every component",
     variant(edge_svc, lambda o: o["spec"]["selector"].pop(COMPONENT)))
case("svc-edge-other-app", "kr", E_SVC, "edge Service selecting another App's edge",
     variant(edge_svc, lambda o: o["spec"]["selector"].update({SERVICE: "menu"})))
case("svc-edge-number", "kr", E_SVC, "edge Service port targeting a number",
     variant(edge_svc, lambda o: o["spec"]["ports"][0].update({"targetPort": 8080})))
case("svc-edge-second-port", "kr", E_SVC, "edge Service with a second port",
     variant(edge_svc, lambda o: o["spec"]["ports"].append({"name": "app", "port": 3000, "targetPort": "app"})))
case("svc-auth-selects-app", "kr", A_SVC, "oauth2-proxy Service selecting the App pods",
     variant(auth_svc, lambda o: o["spec"]["selector"].update({COMPONENT: "app"})))
case("svc-auth-port", "kr", A_SVC, "oauth2-proxy Service port targeting app",
     variant(auth_svc, lambda o: o["spec"]["ports"][0].update({"targetPort": "app"})))
case("svc-nodeport", "kr", "must be type ClusterIP", "NodePort Service",
     variant(edge_svc, lambda o: o["spec"].update({"type": "NodePort"})))
case("svc-prometheus", "kr", PROM, "Service asking to be scraped",
     variant(one("Service", "app-menu"), lambda o: o["metadata"].setdefault("annotations", {}).update({"prometheus.io/scrape": "true", "prometheus.io/port": "3000"})))

# --- Ingresses ----------------------------------------------------------------------
ingresses = of_kind("Ingress")
public = [i for i in ingresses if "traefik.ingress.kubernetes.io/router.middlewares" in i["metadata"].get("annotations", {})]
assert public, "the render needs a public App"
ing = public[0]
private_ing = one("Ingress", "app-recipes")
assert private_ing["spec"]["rules"][0]["http"]["paths"][0]["backend"]["service"] == {"name": "auth-recipes", "port": {"name": "http"}}, "a private App's Ingress names its oauth2-proxy"
assert ing["spec"]["rules"][0]["http"]["paths"][0]["backend"]["service"]["name"].startswith("edge-"), "a public App's Ingress names its edge"


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
BACKEND = "every Ingress backend is an edge Service"
case("ing-port-number", "kr", BACKEND, "Ingress backend by port number",
     variant(ing, lambda o: [p["backend"]["service"].update({"port": {"number": 80}}) for p in paths(o)]))
case("ing-app-service", "kr", BACKEND, "Ingress backend on the App's own Service, skipping the edge",
     variant(ing, lambda o: [p["backend"]["service"].update({"name": "app-menu", "port": {"name": "app"}}) for p in paths(o)]))
case("ing-app-service-edge-port", "kr", BACKEND, "Ingress backend on Service app-menu port edge",
     variant(ing, lambda o: [p["backend"]["service"].update({"name": "app-menu"}) for p in paths(o)]))
case("ing-auth-edge-port", "kr", BACKEND, "Ingress backend on Service auth-recipes port edge",
     variant(private_ing, lambda o: [p["backend"]["service"].update({"port": {"name": "edge"}}) for p in paths(o)]))
case("ing-no-class", "kr", "ingressClassName traefik", "Ingress without ingressClassName",
     variant(ing, lambda o: o["spec"].pop("ingressClassName")))
case("ing-tls-secret", "kr", "tls.secretName", "Ingress with tls.secretName",
     variant(ing, lambda o: [t.update({"secretName": "tls-secret"}) for t in o["spec"]["tls"]]))
case("ing-reserved", "kr", "reserved name", "Ingress for vault.viktorbarzin.me",
     variant(ing, lambda o: ([r.update({"host": "vault.viktorbarzin.me"}) for r in o["spec"]["rules"]], [t.update({"hosts": ["vault.viktorbarzin.me"]}) for t in o["spec"]["tls"]])))
case("ing-taken", "kr", "already routes", "Ingress for nextcloud.viktorbarzin.me, a homelab host",
     variant(ing, lambda o: ([r.update({"host": "nextcloud.viktorbarzin.me"}) for r in o["spec"]["rules"]], [t.update({"hosts": ["nextcloud.viktorbarzin.me"]}) for t in o["spec"]["tls"]])))
case("ing-taken-path", "kr", "already routes", "Ingress for nextcloud.viktorbarzin.me/login, a longer rule than the homelab's",
     variant(ing, lambda o: ([r.update({"host": "nextcloud.viktorbarzin.me"}) for r in o["spec"]["rules"]], [p.update({"path": "/login"}) for p in paths(o)], o["spec"].pop("tls"))))

# --- the edge's Caddyfile (ConfigMap edge-<app>) ------------------------------------
private_cf = one("ConfigMap", "edge-recipes")
public_cf = one("ConfigMap", "edge-menu")
CADDY = "Caddyfile"
assert f"reverse_proxy app-recipes.{target}.svc.cluster.local:80" in private_cf["data"][CADDY], "the edge proxies to its App's Service"


def edit(old, new):
    def f(o):
        assert old in o["data"][CADDY], f"not in the Caddyfile: {old}"
        o["data"][CADDY] = o["data"][CADDY].replace(old, new, 1)
    return f


COOKIE_LIST = "authentik_proxy_[^=;]*|tsgate[^=;]*|anubis[^=;]*|techaro\\.lol-anubis-[^=;]*|_oauth2_proxy[^=;]*"
RENDERED = "Caddyfile is the one Cloud renders"
case("edge-cm-more-cookies", "kr", "ok", "Caddyfile stripping one more cookie, in another order",
     variant(public_cf, edit(COOKIE_LIST, "_oauth2_proxy[^=;]*|techaro\\.lol-anubis-[^=;]*|anubis[^=;]*|grafana_session|tsgate[^=;]*|authentik_proxy_[^=;]*")))
case("edge-cm-comment", "kr", "ok", "Caddyfile with a comment line before it", variant(public_cf, lambda o: o["data"].update({CADDY: "# reviewed\n" + o["data"][CADDY]})))
for cookie in COOKIE_LIST.split("|")[:4]:
    short = cookie.split("[")[0].rstrip("_").replace("\\.", ".")
    case("edge-cm-keep-" + short.replace(".", "-"), "kr", "strips at least", f"Caddyfile that keeps {short}* cookies",
         variant(private_cf, edit(COOKIE_LIST, "|".join(c for c in COOKIE_LIST.split("|") if c != cookie))))
case("edge-cm-exact-tsgate", "kr", "strips at least", "Caddyfile that strips tsgate but not tsgate_fb",
     variant(public_cf, edit("tsgate[^=;]*", "tsgate")))
case("edge-cm-extra-key", "kr", "holds only the key Caddyfile", "edge ConfigMap with a second key",
     variant(public_cf, lambda o: o["data"].update({"evil": "x"})))
case("edge-cm-binary", "kr", "holds only the key Caddyfile", "edge ConfigMap with binaryData",
     variant(public_cf, lambda o: o.update({"binaryData": {"x": "eA=="}})))
case("edge-cm-no-cookie-line", "kr", RENDERED, "Caddyfile without the Cookie rule",
     variant(public_cf, lambda o: o["data"].update({CADDY: "\n".join(l for l in o["data"][CADDY].split("\n") if "header_up Cookie `(?:" not in l)})))
case("edge-cm-no-set-cookie", "kr", RENDERED, "Caddyfile that lets parent-domain Set-Cookie through",
     variant(public_cf, lambda o: o["data"].update({CADDY: "\n".join(l for l in o["data"][CADDY].split("\n") if "header_down Set-Cookie" not in l)})))
case("edge-cm-no-response-cap", "kr", RENDERED, "Caddyfile without the response header cap",
     variant(public_cf, edit("max_response_header 64KB", "max_response_header 10MB")))
case("edge-cm-no-request-cap", "kr", RENDERED, "Caddyfile with a 1MB request header cap",
     variant(public_cf, edit("max_header_size 64KB", "max_header_size 1MB")))
case("edge-cm-vault", "kr", RENDERED, "Caddyfile proxying to Vault",
     variant(public_cf, edit("reverse_proxy app-menu.", "reverse_proxy vault-active.vault.")))
case("edge-cm-other-app", "kr", RENDERED, "Caddyfile proxying to another App's Service",
     variant(public_cf, edit("reverse_proxy app-menu.", "reverse_proxy app-recipes.")))
case("edge-cm-other-ns", "kr", RENDERED, "Caddyfile proxying to another namespace's App",
     variant(public_cf, lambda o: o["data"].update({CADDY: o["data"][CADDY].replace(f"app-menu.{target}.svc.", "app-menu.p-other.svc.")})))
case("edge-cm-extra-route", "kr", RENDERED, "Caddyfile with an extra site block",
     variant(public_cf, lambda o: o["data"].update({CADDY: o["data"][CADDY] + ":8081 {\n\treverse_proxy app-menu:80\n}\n"})))
case("edge-cm-comment-trick", "kr", RENDERED, "Caddyfile with a directive after a comment",
     variant(public_cf, edit(":8080 {", ":8080 {\n# x\n\troute { header_up +Cookie x }")))
case("edge-cm-admin", "kr", RENDERED, "Caddyfile with the admin API on",
     variant(public_cf, edit("admin off", "admin 0.0.0.0:2019")))
case("edge-cm-admin-user", "ka", RENDERED, "admin is refused another Caddyfile too",
     variant(public_cf, edit("admin off", "admin 0.0.0.0:2019")))

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
# The API server allows a PriorityClass scope only on a quota of pod CPU,
# memory and count, so the scoped variant drops every other key
# (PersistentVolumeClaims, Services, ephemeral storage).
SCOPABLE = {"pods", "cpu", "memory", "requests.cpu", "requests.memory", "limits.cpu", "limits.memory"}


def scoped(o):
    for k in [k for k in o["spec"]["hard"] if k not in SCOPABLE]:
        o["spec"]["hard"].pop(k)
    o["spec"]["scopeSelector"] = {"matchExpressions": [{"scopeName": "PriorityClass", "operator": "In", "values": ["tier-0-core"]}]}


case("quota-scoped", "kr", "must have no scopes", "quota that counts only tier-0-core pods", variant(quota, scoped))
for key in ["limits.cpu", "pods", "requests.ephemeral-storage", "limits.ephemeral-storage"]:
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

finish()
