"""First step of the garage-backup CronJob (stacks/garage/main.tf).

Uses Garage's admin API (v2) to make sure the S3 key `cloud-backup` exists
and can read every bucket, then writes two files for the rclone step:

  /work/buckets      one bucket name (its global alias) per line
  /work/rclone.env   the key as RCLONE_CONFIG_GARAGE_* lines, mode 0600

Cloud's reconciler creates buckets at any time, so the grant is renewed on
every run. The key has read only: the backup cannot change a bucket. A bucket
without a global alias is not a Cloud bucket (Cloud names every bucket
p-<project>-<service>); it is skipped with a warning.

Any API error stops the job with exit code 1 before rclone starts, so a
partial bucket list never looks like a complete backup.
"""

import json
import os
import sys
import urllib.error
import urllib.request

ADMIN_URL = os.environ["GARAGE_ADMIN_URL"].rstrip("/")
S3_URL = os.environ["GARAGE_S3_URL"]
TOKEN = os.environ["GARAGE_ADMIN_TOKEN"].strip()
KEY_NAME = os.environ.get("BACKUP_KEY_NAME", "cloud-backup")
WORK = os.environ.get("WORK_DIR", "/work")


def api(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        ADMIN_URL + path,
        data=data,
        method=method,
        headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as e:
        # The body is Garage's error JSON; it never holds a secret.
        sys.exit(f"admin API {method} {path}: HTTP {e.code}: {e.read()[:300]!r}")
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        sys.exit(f"admin API {method} {path}: {e}")


def backup_key():
    keys = [k for k in api("GET", "/v2/ListKeys") if k.get("name") == KEY_NAME]
    if len(keys) > 1:
        sys.exit(f"{len(keys)} keys are named {KEY_NAME}; delete all but one")
    if keys:
        key_id = keys[0]["id"]
    else:
        key_id = api("POST", "/v2/CreateKey", {"name": KEY_NAME})["accessKeyId"]
        print(f"created key {KEY_NAME} ({key_id})")
    return api("GET", f"/v2/GetKeyInfo?id={key_id}&showSecretKey=true")


def main():
    key = backup_key()
    readable = {b["id"] for b in key["buckets"] if b["permissions"].get("read")}
    names = []
    for bucket in api("GET", "/v2/ListBuckets"):
        aliases = bucket.get("globalAliases") or []
        if not aliases:
            print(f"WARN: bucket {bucket['id']} has no global alias; skipped")
            continue
        if bucket["id"] not in readable:
            api(
                "POST",
                "/v2/AllowBucketKey",
                {
                    "bucketId": bucket["id"],
                    "accessKeyId": key["accessKeyId"],
                    "permissions": {"read": True, "write": False, "owner": False},
                },
            )
            print(f"granted read on {aliases[0]}")
        names.append(sorted(aliases)[0])

    with open(os.path.join(WORK, "buckets"), "w") as f:
        f.writelines(n + "\n" for n in sorted(names))
    env_path = os.path.join(WORK, "rclone.env")
    fd = os.open(env_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(
            "RCLONE_CONFIG_GARAGE_TYPE=s3\n"
            "RCLONE_CONFIG_GARAGE_PROVIDER=Other\n"
            f"RCLONE_CONFIG_GARAGE_ENDPOINT={S3_URL}\n"
            "RCLONE_CONFIG_GARAGE_REGION=garage\n"
            "RCLONE_CONFIG_GARAGE_FORCE_PATH_STYLE=true\n"
            f"RCLONE_CONFIG_GARAGE_ACCESS_KEY_ID={key['accessKeyId']}\n"
            f"RCLONE_CONFIG_GARAGE_SECRET_ACCESS_KEY={key['secretAccessKey']}\n"
        )
    print(f"{len(names)} bucket(s) to back up")


if __name__ == "__main__":
    main()
