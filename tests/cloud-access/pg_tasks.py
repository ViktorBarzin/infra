"""Cases for Cloud's Postgres task Jobs (the cloud repo's B28b and B28c).

Usage: python3 pg_tasks.py <pg-tasks.json> <pg_task.json> <out dir>

pg-tasks.json is what render.ts wrote from Cloud's own code: each kind's Job
and its credentials Secret. pg_task.json is local.cloud_pg_task from
stacks/cloud/access_rules.tf. Writes one JSON file per case and cases.tsv
(file, who, expected, what) for cloud-access.test.sh's run_cases, and exits
1 when Cloud and infra disagree on the image.
"""
import copy
import json
import pathlib
import sys

tasks = json.loads(pathlib.Path(sys.argv[1]).read_text())
infra = json.loads(pathlib.Path(sys.argv[2]).read_text())
out = pathlib.Path(sys.argv[3])
out.mkdir(parents=True, exist_ok=True)

if tasks["image"] != infra["image"]:
    print(f"Postgres task image: Cloud runs {tasks['image']}, infra admits {infra['image']}")
    sys.exit(1)

cases = []


def case(name, who, expect, what, obj):
    path = out / f"{len(cases):03d}-{name}.json"
    path.write_text(json.dumps(obj))
    cases.append((path.name, who, expect, what))


def variant(obj, change):
    o = copy.deepcopy(obj)
    change(o)
    return o


def pod(o):
    return o["spec"]["template"]["spec"]


def c(o):
    return pod(o)["containers"][0]


NAME = "is named pg-<kind>-<9 hex digits>"
ONCE = "runs one pod once"
POD = "mounts no service account token"
ONE = "has one container"
PORTS = "listens only for an export"
VOLS = "may use only bounded emptyDirs"
MOUNTS = "mounts the dump directories read-only"
SECRET = "creates only Secrets pg-task-"
SCOPE = "may write only in namespaces named p-"

for kind in ["backups", "backup", "export", "restore"]:
    job = tasks[kind]["job"]
    secret = tasks[kind]["secret"]
    case(f"{kind}-job", "kr", "ok", f"the {kind} Job Cloud builds, in cloud", job)
    if secret:
        case(f"{kind}-secret", "kr", "ok", f"the {kind} Job's credentials Secret", secret)

    rules = [
        ("other-name", lambda o: o["metadata"].update({"name": "pg-dump-0123456789"}), NAME),
        ("other-kind-name", lambda o: o["metadata"].update({"name": "pg-other-5c4b3a291"}), NAME),
        ("label-mismatch", lambda o: o["spec"]["template"]["metadata"]["labels"].update({"cloud.viktorbarzin.me/component": "app"}), NAME),
        ("owned", lambda o: o["metadata"].update({"ownerReferences": [{"apiVersion": "apps/v1", "kind": "Deployment", "name": "cloud", "uid": "00000000-0000-4000-8000-000000000031"}]}), NAME),
        ("retries", lambda o: o["spec"].update({"backoffLimit": 2}), ONCE),
        ("long-deadline", lambda o: o["spec"].update({"activeDeadlineSeconds": 90000}), ONCE),
        ("no-ttl", lambda o: o["spec"].pop("ttlSecondsAfterFinished"), ONCE),
        ("token", lambda o: pod(o).update({"automountServiceAccountToken": True}), POD),
        ("serviceaccount", lambda o: pod(o).update({"serviceAccountName": "cloud"}), POD),
        ("root", lambda o: pod(o)["securityContext"].update({"runAsUser": 0}), POD),
        ("host-network", lambda o: pod(o).update({"hostNetwork": True}), POD),
        ("init", lambda o: pod(o).update({"initContainers": [{k: v for k, v in dict(copy.deepcopy(c(o)), name="setup").items() if k not in ("ports", "readinessProbe")}]}), POD),
        ("second-container", lambda o: pod(o)["containers"].append(dict(copy.deepcopy(c(o)), name="x")), ONE),
        ("image-tag", lambda o: c(o).update({"image": "docker.io/library/postgres:18.7-trixie"}), ONE),
        ("other-image", lambda o: c(o).update({"image": "docker.io/library/alpine@sha256:" + "a" * 64}), ONE),
        ("shell-only", lambda o: c(o).update({"command": ["/bin/sh"]}), ONE),
        ("args", lambda o: c(o).update({"args": ["x"]}), ONE),
        ("privileged", lambda o: c(o)["securityContext"].update({"privileged": True, "allowPrivilegeEscalation": True}), ONE),
        ("writable-root", lambda o: c(o)["securityContext"].update({"readOnlyRootFilesystem": False}), ONE),
        ("cap-add", lambda o: c(o)["securityContext"]["capabilities"].update({"add": ["NET_ADMIN"]}), ONE),
        ("other-secret", lambda o: c(o).update({"envFrom": [{"secretRef": {"name": "cloud-secrets"}}]}), PORTS),
        ("env-from-secret", lambda o: c(o).setdefault("env", []).append({"name": "X", "valueFrom": {"secretKeyRef": {"name": "cloud", "key": "x"}}}), PORTS),
        ("hostpath", lambda o: pod(o).setdefault("volumes", []).append({"name": "host", "hostPath": {"path": "/"}}), VOLS),
        ("homelab-dumps", lambda o: pod(o).setdefault("volumes", []).append({"name": "homelab", "persistentVolumeClaim": {"claimName": "dbaas-postgresql-backup-host", "readOnly": True}}), VOLS),
        ("unbounded-emptydir", lambda o: pod(o).setdefault("volumes", []).append({"name": "big", "emptyDir": {}}), VOLS),
    ]
    if kind != "export":
        rules.append(("listens", lambda o: c(o).update({"ports": [{"containerPort": 8080}]}), PORTS))
    else:
        rules.append(("other-port", lambda o: c(o).update({"ports": [{"containerPort": 22}]}), PORTS))
        rules.append(("mounts-dumps", lambda o: pod(o)["volumes"].append({"name": "nightly", "persistentVolumeClaim": {"claimName": infra["nightly_claim"], "readOnly": True}}), VOLS))
    if kind in ("backups", "restore"):
        def writable_nightly(o):
            for v in pod(o)["volumes"]:
                if v["name"] == "nightly":
                    v["persistentVolumeClaim"]["readOnly"] = False
        def writable_mount(o):
            for m in c(o)["volumeMounts"]:
                if m["name"] == "manual":
                    m["readOnly"] = False
        def sub_path(o):
            for m in c(o)["volumeMounts"]:
                if m["name"] == "nightly":
                    m["subPath"] = "p_other"
        rules.append(("writable-nightly", writable_nightly, VOLS))
        rules.append(("writable-manual-mount", writable_mount, MOUNTS))
        rules.append(("subpath", sub_path, MOUNTS))
    if kind == "backup":
        rules.append(("mounts-nightly", lambda o: pod(o)["volumes"].append({"name": "nightly", "persistentVolumeClaim": {"claimName": infra["nightly_claim"], "readOnly": True}}), VOLS))
    for name, change, expect in rules:
        case(f"{kind}-{name}", "kr", expect, f"{kind} Job with {name}", variant(job, change))

    if secret:
        secret_rules = [
            ("other-name", lambda o: o["metadata"].update({"name": "cloud-secrets"}), SECRET),
            ("no-owner", lambda o: o["metadata"].pop("ownerReferences"), SECRET),
            ("other-owner", lambda o: o["metadata"]["ownerReferences"][0].update({"name": "pg-backup-999999999"}), SECRET),
            ("owner-kind", lambda o: o["metadata"]["ownerReferences"][0].update({"kind": "Deployment", "apiVersion": "apps/v1"}), SECRET),
            ("other-key", lambda o: o["data"].update({"AWS_SECRET": "eA=="}), SECRET),
            ("other-type", lambda o: o.update({"type": "example.com/other"}), SECRET),
        ]
        for name, change, expect in secret_rules:
            case(f"{kind}-secret-{name}", "kr", expect, f"{kind} Secret with {name}", variant(secret, change))

# Elsewhere than cloud, cloud-reconciler-scope still refuses the shape:
# the reconciler writes Jobs only in managed p-* namespaces, and these are
# not Project Jobs.
job = tasks["backups"]["job"]
case("default-ns", "kr", "is forbidden|" + SCOPE, "a backups Job in namespace default", variant(job, lambda o: o["metadata"].update({"namespace": "default"})))

# For the delete checks in cloud-access.test.sh: a task Job and another
# Job in cloud, both suspended so no pod starts.
task_job = copy.deepcopy(tasks["backups"]["job"])
task_job["spec"]["suspend"] = True
(out / "delete-task-job.json").write_text(json.dumps(task_job))
other = copy.deepcopy(task_job)
other["metadata"] = {"name": "cloud-other-job", "namespace": "cloud"}
other["spec"]["template"]["metadata"] = {"labels": {"app": "other"}}
(out / "delete-other-job.json").write_text(json.dumps(other))

with open(out / "cases.tsv", "w") as f:
    for row in cases:
        f.write("\t".join(row) + "\n")
print(f"{len(cases)} cases")
