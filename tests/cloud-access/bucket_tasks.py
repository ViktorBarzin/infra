"""Cases for Cloud's Bucket restore Jobs (the cloud repo's B26c).

Usage: python3 bucket_tasks.py <bucket_task.json> <out dir> [bucket-tasks.json]

bucket_task.json is local.cloud_bucket_task from stacks/cloud/access_rules.tf.
bucket-tasks.json is what render.ts wrote from Cloud's own code
(src/reconciler/bucket-task-jobs.ts): the image, a restore Job and its key
Secret. Without it (a cloud checkout from before B26) the Job and Secret are
built here to the shape Cloud and infra agreed for B26
(docs/architecture/cloud.md, "Buckets"). The pod the Job controller makes is
derived from the Job either way. Writes one JSON file per case and
cases.tsv (file, who, expected, what) for cloud-access.test.sh's run_cases,
and exits 1 when Cloud and infra disagree on the image.
"""
import copy
import json
import pathlib
import sys

infra = json.loads(pathlib.Path(sys.argv[1]).read_text())
out = pathlib.Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)

COMP = "cloud.viktorbarzin.me/component"
HEX = "a1b2c3d4e"
NAME = infra["prefix"] + HEX
TASK_ID = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"
labels = {COMP: infra["component"], infra["task_label"]: TASK_ID, infra["project_label"]: "demo"}
# What a restore script looks like: the first dated directory after the
# date that holds the key, else current/, copied into the bucket.
SCRIPT = r"""set -eu
bucket="$1"; key="$2"; from="$3"
src=""
for d in $(ls -1 /backup | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort); do
  if [ "$d" \> "$from" ] && [ -f "/backup/$d/$bucket/$key" ]; then src="/backup/$d/$bucket/$key"; break; fi
done
[ -n "$src" ] || src="/backup/current/$bucket/$key"
[ -f "$src" ] || { echo "no_backup: $key"; exit 3; }
rclone copyto --s3-no-check-bucket "$src" ":s3:$bucket/$key"
"""

cloud = json.loads(pathlib.Path(sys.argv[3]).read_text()) if len(sys.argv) > 3 else None
if cloud is not None and cloud["image"] != infra["image"]:
    print(f"Bucket restore image: Cloud runs {cloud['image']}, infra admits {infra['image']}")
    sys.exit(1)

job = {
    "apiVersion": "batch/v1", "kind": "Job",
    "metadata": {"name": NAME, "namespace": "cloud", "labels": dict(labels)},
    "spec": {
        "suspend": True, "backoffLimit": 0, "ttlSecondsAfterFinished": 3600, "activeDeadlineSeconds": 1800,
        "template": {
            "metadata": {"labels": dict(labels)},
            "spec": {
                "restartPolicy": "Never", "automountServiceAccountToken": False, "enableServiceLinks": False,
                "securityContext": {"runAsNonRoot": True, "runAsUser": infra["uid"], "runAsGroup": infra["uid"],
                                    "seccompProfile": {"type": "RuntimeDefault"}},
                "containers": [{
                    "name": infra["container"], "image": infra["image"],
                    "command": ["/bin/sh", "-c", SCRIPT, infra["component"], "p-demo-files-0123456789", "photos/2026/cat.jpg", "2026-11-18"],
                    "env": [
                        {"name": "HOME", "value": "/tmp"},
                        {"name": "RCLONE_S3_PROVIDER", "value": "Other"},
                        {"name": "RCLONE_S3_ENDPOINT", "value": "http://garage.garage.svc.cluster.local:3900"},
                        {"name": "RCLONE_S3_REGION", "value": "garage"},
                        {"name": "RCLONE_S3_FORCE_PATH_STYLE", "value": "true"},
                        {"name": "RCLONE_S3_ENV_AUTH", "value": "false"},
                        {"name": "RCLONE_S3_NO_CHECK_BUCKET", "value": "true"},
                        {"name": "RCLONE_CONFIG", "value": "/dev/null"},
                    ],
                    "envFrom": [{"secretRef": {"name": NAME}}],
                    "resources": {"requests": {"cpu": "50m", "memory": "64Mi", "ephemeral-storage": "32Mi"},
                                  "limits": {"cpu": "500m", "memory": "256Mi", "ephemeral-storage": "64Mi"}},
                    "securityContext": {"readOnlyRootFilesystem": True, "allowPrivilegeEscalation": False,
                                        "capabilities": {"drop": ["ALL"]}},
                    "terminationMessagePolicy": "FallbackToLogsOnError",
                    "volumeMounts": [{"name": "backups", "mountPath": infra["mount_path"], "readOnly": True},
                                     {"name": "tmp", "mountPath": "/tmp"}],
                }],
                "volumes": [{"name": "backups", "persistentVolumeClaim": {"claimName": infra["claim"], "readOnly": True}},
                            {"name": "tmp", "emptyDir": {"sizeLimit": "64Mi"}}],
            },
        },
    },
}
secret = {
    "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
    "metadata": {"name": NAME, "namespace": "cloud",
                 "labels": {COMP: infra["component"], infra["task_label"]: TASK_ID},
                 "ownerReferences": [{"apiVersion": "batch/v1", "kind": "Job", "name": NAME,
                                      "uid": "00000000-0000-4000-8000-000000000026", "controller": True}]},
    "data": {k: "eA==" for k in infra["secret_keys"]},
}

if cloud is not None:
    job, secret = cloud["job"], cloud["secret"]

name = job["metadata"]["name"]
# The pod the Job controller makes from it.
pod_obj = {
    "apiVersion": "v1", "kind": "Pod",
    "metadata": {"name": name + "-x7k2p", "namespace": "cloud",
                 "labels": dict(job["spec"]["template"]["metadata"]["labels"], **{"batch.kubernetes.io/job-name": name}),
                 "ownerReferences": [{"apiVersion": "batch/v1", "kind": "Job", "name": name,
                                      "uid": "00000000-0000-4000-8000-000000000026", "controller": True, "blockOwnerDeletion": True}]},
    "spec": copy.deepcopy(job["spec"]["template"]["spec"]),
}

cases = []


def case(cname, who, expect, what, obj):
    path = out / f"{len(cases):03d}-{cname}.json"
    path.write_text(json.dumps(obj))
    cases.append((path.name, who, expect, what))


def variant(obj, change):
    o = copy.deepcopy(obj)
    change(o)
    return o


def spec(o):
    return o["spec"]["template"]["spec"] if o["kind"] == "Job" else o["spec"]


def c(o):
    return spec(o)["containers"][0]


def arg(i, value):
    def change(o):
        c(o)["command"][i] = value
    return change


def mount(name_, **kw):
    def change(o):
        for m in c(o)["volumeMounts"]:
            if m["name"] == name_:
                m.update(kw)
    return change


def claim_writable(o):
    for v in spec(o)["volumes"]:
        if "persistentVolumeClaim" in v:
            v["persistentVolumeClaim"]["readOnly"] = False


J_NAME = "is named bucket-restore-"
J_ONCE = "a Bucket restore Job runs one pod once"
J_POD = "a Bucket restore pod sets restartPolicy Never"
J_ONE = "a Bucket restore pod has one container restore"
J_ARGS = "a Bucket restore's arguments are a Cloud bucket name"
J_ENV = "a Bucket restore pod sets only HOME"
J_VOLS = "a Bucket restore pod may use only bounded emptyDirs and cloud-bucket-backups"
J_MOUNTS = "a Bucket restore pod mounts cloud-bucket-backups read-only at"
S_RULE = "creates only Secrets bucket-restore-"
SCOPE = "is forbidden|may write only in namespaces named p-"
PG_NAME = "is named pg-<kind>-<9 hex digits>"

case("job", "kr", "ok", "the Bucket restore Job, in cloud", job)
case("secret", "kr", "ok", "the Bucket restore Job's key Secret", secret)
case("job-dotted-key", "kr", "ok", "a restore of a key with dots in a name (a..b.jpg)", variant(job, arg(5, "photos/a..b.jpg")))
case("job-max-script", "kr", "ok", f"a restore with a {infra['max_script_len']}-character script", variant(job, arg(2, "#" * infra["max_script_len"])))
case("job-max-key", "kr", "ok", f"a restore of a {infra['max_key_len']}-character key", variant(job, arg(5, "k" * infra["max_key_len"])))

job_rules = [
    ("other-name", lambda o: o["metadata"].update({"name": "bucket-restore-xyz"}), J_NAME),
    ("long-name", lambda o: o["metadata"].update({"name": "bucket-restore-0123456789"}), J_NAME),
    ("label-mismatch", lambda o: o["spec"]["template"]["metadata"]["labels"].update({COMP: "pg-restore"}), J_NAME),
    ("other-component", lambda o: (o["metadata"]["labels"].update({COMP: "pg-restore"}), o["spec"]["template"]["metadata"]["labels"].update({COMP: "pg-restore"})), J_NAME),
    ("no-project-label", lambda o: o["spec"]["template"]["metadata"]["labels"].pop(infra["project_label"]), J_NAME),
    ("owned", lambda o: o["metadata"].update({"ownerReferences": [{"apiVersion": "apps/v1", "kind": "Deployment", "name": "cloud", "uid": "00000000-0000-4000-8000-000000000031"}]}), J_NAME),
    ("retries", lambda o: o["spec"].update({"backoffLimit": 2}), J_ONCE),
    ("long-deadline", lambda o: o["spec"].update({"activeDeadlineSeconds": infra["max_deadline"] + 1}), J_ONCE),
    ("no-ttl", lambda o: o["spec"].pop("ttlSecondsAfterFinished"), J_ONCE),
    ("long-ttl", lambda o: o["spec"].update({"ttlSecondsAfterFinished": infra["max_ttl"] + 1}), J_ONCE),
    ("parallel", lambda o: o["spec"].update({"parallelism": 2, "completions": 2}), J_ONCE),
    ("token", lambda o: spec(o).update({"automountServiceAccountToken": True}), J_POD),
    ("service-links", lambda o: spec(o).update({"enableServiceLinks": True}), J_POD),
    ("serviceaccount", lambda o: spec(o).update({"serviceAccountName": "cloud"}), J_POD),
    ("root", lambda o: spec(o)["securityContext"].update({"runAsUser": 0}), J_POD),
    ("root-group", lambda o: spec(o)["securityContext"].update({"runAsGroup": 0}), J_POD),
    ("no-seccomp", lambda o: spec(o)["securityContext"].pop("seccompProfile"), J_POD),
    ("host-network", lambda o: spec(o).update({"hostNetwork": True}), J_POD),
    ("init", lambda o: spec(o).update({"initContainers": [dict(copy.deepcopy(c(o)), name="setup")]}), J_POD),
    ("second-container", lambda o: spec(o)["containers"].append(dict(copy.deepcopy(c(o)), name="x")), J_ONE),
    ("image-tag", lambda o: c(o).update({"image": "docker.io/rclone/rclone:1.76.0"}), J_ONE),
    ("other-image", lambda o: c(o).update({"image": "docker.io/library/alpine@sha256:" + "a" * 64}), J_ONE),
    ("bash", arg(0, "/bin/bash"), J_ONE),
    ("other-task-word", arg(3, "pg-task"), J_ONE),
    ("short-command", lambda o: c(o)["command"].pop(), J_ONE),
    ("long-command", lambda o: c(o)["command"].append("x"), J_ONE),
    ("long-script", arg(2, "#" * (infra["max_script_len"] + 1)), J_ONE),
    ("args", lambda o: c(o).update({"args": ["x"]}), J_ONE),
    ("port", lambda o: c(o).update({"ports": [{"containerPort": 8080}]}), J_ONE),
    ("probe", lambda o: c(o).update({"readinessProbe": {"tcpSocket": {"port": 8080}}}), J_ONE),
    ("privileged", lambda o: c(o)["securityContext"].update({"privileged": True, "allowPrivilegeEscalation": True}), J_ONE),
    ("writable-root", lambda o: c(o)["securityContext"].update({"readOnlyRootFilesystem": False}), J_ONE),
    ("cap-add", lambda o: c(o)["securityContext"]["capabilities"].update({"add": ["NET_ADMIN"]}), J_ONE),
    ("bucket-no-hex", arg(4, "p-demo-files"), J_ARGS),
    ("bucket-path", arg(4, "p-demo-files-0123456789/../p-other-x-0123456789"), J_ARGS),
    ("key-climbs", arg(5, "../../current/p-other-files-0123456789/secret.txt"), J_ARGS),
    ("key-climbs-inside", arg(5, "photos/../../p-other-files-0123456789/x"), J_ARGS),
    ("key-dot", arg(5, "photos/./cat.jpg"), J_ARGS),
    ("key-absolute", arg(5, "/etc/passwd"), J_ARGS),
    ("key-newline", arg(5, "cat.jpg\nrm -rf /"), J_ARGS),
    ("key-empty", arg(5, ""), J_ARGS),
    ("key-long", arg(5, "k" * (infra["max_key_len"] + 1)), J_ARGS),
    ("date-word", arg(6, "yesterday"), J_ARGS),
    ("env-other", lambda o: c(o)["env"].append({"name": "RCLONE_CONFIG_X_TYPE", "value": "local"}), J_ENV),
    ("env-from-secret", lambda o: c(o)["env"].append({"name": "HOME", "valueFrom": {"secretKeyRef": {"name": "cloud", "key": "x"}}}), J_ENV),
    ("other-secret", lambda o: c(o).update({"envFrom": [{"secretRef": {"name": "cloud-secrets"}}]}), J_ENV),
    ("env-prefix", lambda o: c(o)["envFrom"][0].update({"prefix": "X_"}), J_ENV),
    ("two-env-from", lambda o: c(o)["envFrom"].append({"configMapRef": {"name": "x"}}), J_ENV),
    ("no-env-from", lambda o: c(o).pop("envFrom"), J_ENV),
    ("no-limits", lambda o: c(o)["resources"].pop("limits"), J_ENV),
    ("hostpath", lambda o: spec(o)["volumes"].append({"name": "host", "hostPath": {"path": "/"}}), J_VOLS),
    ("pg-dumps", lambda o: spec(o)["volumes"].append({"name": "nightly", "persistentVolumeClaim": {"claimName": "cloud-pg-backups-nightly", "readOnly": True}}), J_VOLS),
    ("writable-claim", claim_writable, J_VOLS),
    ("unbounded-emptydir", lambda o: spec(o)["volumes"].append({"name": "big", "emptyDir": {}}), J_VOLS),
    ("nfs", lambda o: spec(o)["volumes"].append({"name": "nfs", "nfs": {"server": "192.168.1.127", "path": "/srv/nfs/cloud-buckets"}}), J_VOLS),
    ("writable-mount", mount("backups", readOnly=False), J_MOUNTS),
    ("subpath", mount("backups", subPath="current/p-other-files-0123456789"), J_MOUNTS),
    ("other-mount-path", mount("backups", mountPath="/data"), J_MOUNTS),
]
for rname, change, expect in job_rules:
    case(f"job-{rname}", "kr", expect, f"Bucket restore Job with {rname}", variant(job, change))
# Named for the Postgres rules, it is checked by them, and refused.
case("job-pg-name", "kr", PG_NAME, "a Bucket restore Job named pg-restore-<9 hex>", variant(job, lambda o: o["metadata"].update({"name": "pg-restore-" + HEX})))
case("job-default-ns", "kr", SCOPE, "a Bucket restore Job in namespace default", variant(job, lambda o: o["metadata"].update({"namespace": "default"})))

secret_rules = [
    ("other-name", lambda o: o["metadata"].update({"name": "bucket-restore-xyz"}), S_RULE),
    ("no-owner", lambda o: o["metadata"].pop("ownerReferences"), S_RULE),
    ("other-owner", lambda o: o["metadata"]["ownerReferences"][0].update({"name": "bucket-restore-999999999"}), S_RULE),
    ("owner-kind", lambda o: o["metadata"]["ownerReferences"][0].update({"kind": "Deployment", "apiVersion": "apps/v1"}), S_RULE),
    ("not-controller", lambda o: o["metadata"]["ownerReferences"][0].update({"controller": False}), S_RULE),
    ("other-key", lambda o: o["data"].update({"AWS_SECRET": "eA=="}), S_RULE),
    ("other-type", lambda o: o.update({"type": "example.com/other"}), S_RULE),
]
for rname, change, expect in secret_rules:
    case(f"secret-{rname}", "kr", expect, f"Bucket restore Secret with {rname}", variant(secret, change))
case("secret-default-ns", "kr", "is forbidden|may write only in namespaces named p-", "a Bucket restore Secret in namespace default", variant(secret, lambda o: o["metadata"].update({"namespace": "default"})))

# The mount guard, cloud-bucket-backups-mount, on pods from anyone (here the
# cluster admin): only the restore pod mounts the backups.
P_INLINE = "never as an inline nfs or csi volume"
P_WHO = "only a Bucket restore pod"
P_SHAPE = "a pod that mounts cloud-bucket-backups runs one container restore"
P_RO = "cloud-bucket-backups is mounted read-only"
inline_nfs = {"name": "nfs", "nfs": {"server": "192.168.1.127", "path": "/srv/nfs/cloud-buckets"}}
plain = {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "nfs-reader", "namespace": "default"},
         "spec": {"containers": [{"name": "c", "image": "docker.io/library/alpine@sha256:" + "a" * 64,
                                  "volumeMounts": [{"name": "nfs", "mountPath": "/m"}]}], "volumes": [inline_nfs]}}

case("pod", "ka", "ok", "the restore pod the Job controller makes, in cloud", pod_obj)
pod_rules = [
    ("default-ns", lambda o: o["metadata"].update({"namespace": "default"}), P_WHO),
    ("other-component", lambda o: o["metadata"]["labels"].update({COMP: "pg-backups"}), P_WHO),
    ("console-pod", lambda o: o["metadata"].update({"labels": {"app": "cloud"}, "ownerReferences": [{"apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "cloud-5d8f", "uid": "00000000-0000-4000-8000-000000000032", "controller": True}]}), P_WHO),
    ("no-owner", lambda o: o["metadata"].pop("ownerReferences"), P_WHO),
    ("other-owner", lambda o: o["metadata"]["ownerReferences"][0].update({"name": "pg-restore-" + HEX}), P_WHO),
    ("other-image", lambda o: c(o).update({"image": "docker.io/library/alpine@sha256:" + "a" * 64}), P_SHAPE),
    ("token", lambda o: o["spec"].update({"automountServiceAccountToken": True}), P_SHAPE),
    ("root", lambda o: o["spec"]["securityContext"].update({"runAsUser": 0}), P_SHAPE),
    ("writable-root", lambda o: c(o)["securityContext"].update({"readOnlyRootFilesystem": False}), P_SHAPE),
    ("second-container", lambda o: o["spec"]["containers"].append(dict(copy.deepcopy(c(o)), name="x")), P_SHAPE),
    ("writable-claim", claim_writable, P_RO),
    ("writable-mount", mount("backups", readOnly=False), P_RO),
    ("subpath", mount("backups", subPath="current"), P_RO),
    ("plus-inline-nfs", lambda o: o["spec"]["volumes"].append(inline_nfs), P_INLINE),
]
for rname, change, expect in pod_rules:
    case(f"pod-{rname}", "ka", expect, f"restore pod with {rname}", variant(pod_obj, change))
case("inline-nfs", "ka", P_INLINE, "a pod in default with an inline nfs volume on /srv/nfs/cloud-buckets", plain)
case("inline-nfs-slashes", "ka", P_INLINE, "a pod in default with an inline nfs volume on //srv/nfs//cloud-buckets/current",
     variant(plain, lambda o: o["spec"]["volumes"][0]["nfs"].update({"path": "//srv/nfs//cloud-buckets/current"})))
case("inline-csi", "ka", P_INLINE, "a pod in default with an inline csi volume on the backup share",
     variant(plain, lambda o: o["spec"].update({"volumes": [{"name": "nfs", "csi": {"driver": "nfs.csi.k8s.io", "volumeAttributes": {"server": "192.168.1.127", "share": "/srv/nfs/cloud-buckets"}}}]})))
for label, path in (("parent", "/srv/nfs"), ("parent-slash", "/srv/nfs/"), ("srv", "/srv"), ("root", "/"),
                    ("dot", "/srv/./nfs/cloud-buckets"), ("dotdot", "/srv/nfs/other/../cloud-buckets")):
    case(f"inline-nfs-{label}", "ka", P_INLINE, f"a pod in default with an inline nfs volume on {path}",
         variant(plain, lambda o, path=path: o["spec"]["volumes"][0]["nfs"].update({"path": path})))
case("inline-csi-parent", "ka", P_INLINE, "a pod in default with an inline csi volume on /srv/nfs with subDir cloud-buckets",
     variant(plain, lambda o: o["spec"].update({"volumes": [{"name": "nfs", "csi": {"driver": "nfs.csi.k8s.io", "volumeAttributes": {"server": "192.168.1.127", "share": "/srv/nfs", "subDir": "cloud-buckets"}}}]})))
case("other-nfs-near", "ka", "ok", "a pod in default with an inline nfs volume on /srv/nfs/cloud-bucketsx (another share)",
     variant(plain, lambda o: o["spec"]["volumes"][0]["nfs"].update({"path": "/srv/nfs/cloud-bucketsx"})))
case("other-nfs", "ka", "ok", "a pod in default with an inline nfs volume on another share (the guard leaves it alone)",
     variant(plain, lambda o: o["spec"]["volumes"][0]["nfs"].update({"path": "/srv/nfs/other"})))
case("claim-elsewhere", "ka", P_WHO, "a pod in default naming a claim cloud-bucket-backups",
     variant(plain, lambda o: o["spec"].update({"volumes": [{"name": "nfs", "persistentVolumeClaim": {"claimName": infra["claim"], "readOnly": True}}]})))

# For the delete check in cloud-access.test.sh: a restore Job, suspended.
(out / "delete-bucket-job.json").write_text(json.dumps(job))

with open(out / "cases.tsv", "w") as f:
    for row in cases:
        f.write("\t".join(row) + "\n")
print(f"{len(cases)} cases")
