"""Garage for Cloud Buckets (stacks/garage), against the real images in docker.

Run by tests/garage.test.sh. Starts the pinned Garage with the stack's own
garage.toml, a Pushgateway, and runs the backup CronJob's two scripts in their
pinned images, the way the Job does. Needs docker and python3 (stdlib only).
"""

import json
import os
import re
import secrets
import shutil
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STACK = os.path.join(REPO, "stacks", "garage")
MAIN_TF = open(os.path.join(STACK, "main.tf")).read()


def tf_local(name):
    m = re.search(r'^\s*%s\s*=\s*"([^"]+)"' % name, MAIN_TF, re.M)
    assert m, f"local {name} not found in main.tf"
    return m.group(1)


GARAGE_IMAGE = tf_local("garage_image")
RCLONE_IMAGE = tf_local("rclone_image")
PYTHON_IMAGE = tf_local("python_image")
PUSHGATEWAY_IMAGE = os.environ.get("GARAGE_TEST_PUSHGATEWAY_IMAGE", "prom/pushgateway:v1")
SUFFIX = secrets.token_hex(4)
NET = f"garage-test-{SUFFIX}"
GARAGE = f"garage-test-{SUFFIX}"
PGW = f"garage-test-pgw-{SUFFIX}"
UID = f"{os.getuid()}:{os.getgid()}"
BUCKET = "p-demo-files-0123456789"


def docker(*args, check=True, capture=True):
    r = subprocess.run(["docker", *args], capture_output=capture, text=True)
    if check and r.returncode != 0:
        raise AssertionError(f"docker {' '.join(args[:3])}... failed: {r.stderr[-2000:]}")
    return r


def host_port(container, port):
    out = docker("port", container, str(port)).stdout.strip().splitlines()[0]
    return int(out.rsplit(":", 1)[1])


class Garage(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="garage-test-")
        for d in ("meta", "data", "backup", "work", "up"):
            os.makedirs(os.path.join(cls.tmp, d))
        cls.admin_token = secrets.token_urlsafe(32)
        env_file = os.path.join(cls.tmp, "garage.env")
        fd = os.open(env_file, os.O_WRONLY | os.O_CREAT, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(f"GARAGE_RPC_SECRET={secrets.token_hex(32)}\n")
            f.write(f"GARAGE_ADMIN_TOKEN={cls.admin_token}\n")
            f.write("NO_COLOR=1\n")
        docker("network", "create", NET)
        docker(
            "run", "-d", "--name", GARAGE, "--network", NET, "--user", UID,
            "-p", "127.0.0.1::3900", "-p", "127.0.0.1::3903",
            "--env-file", env_file,
            "-v", f"{STACK}/files/garage.toml:/etc/garage.toml:ro",
            "-v", f"{cls.tmp}/meta:/var/lib/garage/meta",
            "-v", f"{cls.tmp}/data:/var/lib/garage/data",
            GARAGE_IMAGE, "/garage", "server", "--single-node",
        )
        docker("run", "-d", "--name", PGW, "--network", NET, "-p", "127.0.0.1::9091", PUSHGATEWAY_IMAGE)
        cls.wait_healthy()
        cls.pgw = f"http://127.0.0.1:{host_port(PGW, 9091)}"

    @classmethod
    def tearDownClass(cls):
        docker("rm", "-f", GARAGE, PGW, check=False)
        docker("network", "rm", NET, check=False)
        # Files written by containers belong to this uid, so this works.
        shutil.rmtree(cls.tmp, ignore_errors=True)

    @classmethod
    def wait_healthy(cls):
        deadline = time.time() + 60
        while time.time() < deadline:
            try:
                cls.admin = f"http://127.0.0.1:{host_port(GARAGE, 3903)}"
                cls.s3 = f"http://127.0.0.1:{host_port(GARAGE, 3900)}"
                with urllib.request.urlopen(cls.admin + "/health", timeout=2) as r:
                    if r.status == 200:
                        return
            except (urllib.error.URLError, OSError, IndexError, AssertionError):
                pass
            time.sleep(1)
        raise AssertionError("garage never became healthy: " + docker("logs", GARAGE, check=False).stderr[-2000:])

    # ── helpers ──

    def api(self, method, path, body=None, token=None):
        req = urllib.request.Request(
            self.admin + path,
            data=None if body is None else json.dumps(body).encode(),
            method=method,
            headers={"Authorization": "Bearer " + (token or self.admin_token), "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read() or b"null")

    def app_key(self, bucket_id, name):
        key = self.api("POST", "/v2/CreateKey", {"name": name})
        self.api("POST", "/v2/AllowBucketKey", {
            "bucketId": bucket_id, "accessKeyId": key["accessKeyId"],
            "permissions": {"read": True, "write": True, "owner": False},
        })
        path = os.path.join(self.tmp, re.sub(r"[^a-z0-9-]", "_", name) + ".env")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(
                "RCLONE_CONFIG_G_TYPE=s3\nRCLONE_CONFIG_G_PROVIDER=Other\n"
                f"RCLONE_CONFIG_G_ENDPOINT=http://{GARAGE}:3900\nRCLONE_CONFIG_G_REGION=garage\n"
                "RCLONE_CONFIG_G_FORCE_PATH_STYLE=true\n"
                f"RCLONE_CONFIG_G_ACCESS_KEY_ID={key['accessKeyId']}\n"
                f"RCLONE_CONFIG_G_SECRET_ACCESS_KEY={key['secretAccessKey']}\n"
            )
        return path

    def rclone(self, env_file, *args, check=True):
        return docker(
            "run", "--rm", "--network", NET, "--user", UID, "-e", "HOME=/tmp",
            "--env-file", env_file, "-v", f"{self.tmp}/up:/up", RCLONE_IMAGE, *args, check=check,
        )

    def put(self, env_file, bucket, key, text):
        local = os.path.join(self.tmp, "up", "obj")
        with open(local, "w") as f:
            f.write(text)
        self.rclone(env_file, "copyto", "/up/obj", f"g:{bucket}/{key}")

    def night(self, date, extra_bucket_line=None):
        """One backup run, as the CronJob does it: prepare, then sync."""
        docker(
            "run", "--rm", "--network", NET, "--user", UID,
            "-e", f"GARAGE_ADMIN_URL=http://{GARAGE}:3903",
            "-e", f"GARAGE_S3_URL=http://{GARAGE}:3900",
            "-e", f"GARAGE_ADMIN_TOKEN={self.admin_token}",
            "-v", f"{STACK}/files:/scripts:ro", "-v", f"{self.tmp}/work:/work",
            PYTHON_IMAGE, "python3", "-I", "/scripts/backup_prepare.py",
        )
        if extra_bucket_line:
            with open(os.path.join(self.tmp, "work", "buckets"), "a") as f:
                f.write(extra_bucket_line + "\n")
        return docker(
            "run", "--rm", "--network", NET, "--user", UID, "--entrypoint", "/bin/sh",
            "-e", "BACKUP_ROOT=/backup", "-e", "KEEP=7", "-e", f"BACKUP_DATE={date}",
            "-e", f"PUSHGATEWAY=http://{PGW}:9091", "-e", "HOME=/tmp",
            "-v", f"{STACK}/files:/scripts:ro", "-v", f"{self.tmp}/work:/work:ro",
            "-v", f"{self.tmp}/backup:/backup",
            RCLONE_IMAGE, "/scripts/backup_sync.sh", check=False,
        )

    def read(self, *parts):
        with open(os.path.join(self.tmp, "backup", *parts)) as f:
            return f.read()

    def exists(self, *parts):
        return os.path.exists(os.path.join(self.tmp, "backup", *parts))

    def pushed(self):
        with urllib.request.urlopen(self.pgw + "/metrics", timeout=5) as r:
            text = r.read().decode()
        return {
            m.group(1): float(m.group(2))
            for m in re.finditer(r'^(\w+)\{[^}]*job="garage-backup"[^}]*\} (\S+)$', text, re.M)
        }

    # ── tests (unittest runs them in name order) ──

    def test_1_server(self):
        logs = docker("logs", GARAGE).stderr + docker("logs", GARAGE).stdout
        self.assertFalse("\x1b[" in logs, "log lines carry colour codes; NO_COLOR=1 did not take")
        layout = self.api("GET", "/v2/GetClusterLayout")
        self.assertEqual(layout["version"], 1)
        self.assertEqual(len(layout["roles"]), 1)
        self.assertEqual(self.api("GET", "/v2/GetClusterHealth")["status"], "healthy")
        # --single-node again after a restart: same layout, no new version.
        docker("restart", GARAGE)
        self.wait_healthy()
        self.assertEqual(self.api("GET", "/v2/GetClusterLayout")["version"], 1)

    def test_2_metrics_open(self):
        # metrics_require_token = false: the NetworkPolicy guards the port.
        deadline = time.time() + 30
        while True:
            with urllib.request.urlopen(self.admin + "/metrics", timeout=5) as r:
                text = r.read().decode()
            if "cluster_healthy 1" in text or time.time() > deadline:
                break
            time.sleep(1)
        for series in ("cluster_healthy 1", 'garage_local_disk_avail{volume="data"}', 'garage_local_disk_total{volume="metadata"}'):
            self.assertTrue(series in text, f"{series} not in /metrics")
        # Everything else on the admin port still needs the admin token.
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.urlopen(self.admin + "/v2/GetClusterHealth", timeout=5)
        self.assertIn(cm.exception.code, (401, 403))

    def test_3_quota(self):
        b = self.api("POST", "/v2/CreateBucket", {"globalAlias": "p-quota-test"})
        self.api("POST", f"/v2/UpdateBucket?id={b['id']}", {"quotas": {"maxSize": 1000, "maxObjects": None}})
        env = self.app_key(b["id"], "quota-test")
        self.put(env, "p-quota-test", "small", "x" * 600)
        with open(os.path.join(self.tmp, "up", "big"), "w") as f:
            f.write("y" * 600)
        r = self.rclone(env, "copyto", "/up/big", "g:p-quota-test/big", "--retries", "1", "--low-level-retries", "1", check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("StatusCode: 403", r.stderr)
        self.assertIn("api error AccessDenied: Forbidden: Bucket size quota is reached", r.stderr)
        self.rclone(env, "deletefile", "g:p-quota-test/small")
        self.api("POST", f"/v2/DeleteBucket?id={b['id']}")

    def test_4_backup_layout(self):
        b = self.api("POST", "/v2/CreateBucket", {"globalAlias": BUCKET})
        env = self.app_key(b["id"], "cloud:demo/files")
        self.put(env, BUCKET, "a.txt", "a v1")
        self.put(env, BUCKET, "b.txt", "b v1")
        self.put(env, BUCKET, "dir/c.txt", "c v1")

        r = self.night("2026-01-01")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.read("current", BUCKET, "a.txt"), "a v1")
        self.assertEqual(self.read("current", BUCKET, "dir", "c.txt"), "c v1")
        first = self.pushed()
        self.assertEqual(first["garage_backup_failed_buckets"], 0)
        self.assertEqual(first["garage_backup_buckets"], 1)
        self.assertIn("backup_last_success_timestamp", first)

        # Next night: one object changed, one deleted.
        self.put(env, BUCKET, "a.txt", "a v2")
        self.rclone(env, "deletefile", f"g:{BUCKET}/b.txt")
        time.sleep(1)
        r = self.night("2026-01-02")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.read("current", BUCKET, "a.txt"), "a v2")
        self.assertFalse(self.exists("current", BUCKET, "b.txt"))
        self.assertEqual(self.read("2026-01-02", BUCKET, "a.txt"), "a v1")
        self.assertEqual(self.read("2026-01-02", BUCKET, "b.txt"), "b v1")
        self.assertFalse(self.exists("2026-01-02", BUCKET, "dir", "c.txt"))

        # A second run the same day adds to 2026-01-02 but keeps its a.txt:
        # the dated copy stays the previous night's version.
        self.put(env, BUCKET, "a.txt", "a v3")
        self.rclone(env, "deletefile", f"g:{BUCKET}/dir/c.txt")
        time.sleep(1)
        r = self.night("2026-01-02")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.read("current", BUCKET, "a.txt"), "a v3")
        self.assertEqual(self.read("2026-01-02", BUCKET, "a.txt"), "a v1")
        self.assertEqual(self.read("2026-01-02", BUCKET, "dir", "c.txt"), "c v1")
        self.assertFalse(self.exists(".staging"))

        # The backup key is made once and only reads.
        keys = [k for k in self.api("GET", "/v2/ListKeys") if k["name"] == "cloud-backup"]
        self.assertEqual(len(keys), 1)
        info = self.api("GET", f"/v2/GetKeyInfo?id={keys[0]['id']}")
        self.assertEqual({(x["permissions"].get("read"), x["permissions"].get("write")) for x in info["buckets"]}, {(True, False)})

    def test_5_deleted_bucket_ages_out(self):
        b = self.api("POST", "/v2/CreateBucket", {"globalAlias": "p-gone-files"})
        env = self.app_key(b["id"], "cloud:gone/files")
        self.put(env, "p-gone-files", "x.txt", "x")
        self.assertEqual(self.night("2026-01-03").returncode, 0)
        self.assertEqual(self.read("current", "p-gone-files", "x.txt"), "x")
        self.rclone(env, "deletefile", "g:p-gone-files/x.txt")
        self.api("POST", f"/v2/DeleteBucket?id={b['id']}")
        r = self.night("2026-01-04")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(self.exists("current", "p-gone-files"))
        self.assertEqual(self.read("2026-01-04", "p-gone-files", "x.txt"), "x")

    def test_6_retention_keeps_seven(self):
        for day in range(10, 25):
            os.makedirs(os.path.join(self.tmp, "backup", f"2025-12-{day}"), exist_ok=True)
        os.makedirs(os.path.join(self.tmp, "backup", "notes"), exist_ok=True)
        self.assertEqual(self.night("2026-01-05").returncode, 0)
        names = sorted(os.listdir(os.path.join(self.tmp, "backup")))
        dated = [n for n in names if re.fullmatch(r"\d{4}-\d{2}-\d{2}", n)]
        self.assertEqual(len(dated), 7, names)
        self.assertEqual(dated[-1], "2026-01-04")  # 01-05 overwrote nothing, so rclone made no directory
        self.assertIn("2026-01-02", dated)
        self.assertIn("current", names)
        self.assertIn("notes", names)

    def test_7_failed_bucket_fails_the_run(self):
        before = self.pushed()["backup_last_success_timestamp"]
        time.sleep(1)
        r = self.night("2026-01-06", extra_bucket_line="p-does-not-exist")
        self.assertNotEqual(r.returncode, 0)
        after = self.pushed()
        self.assertEqual(after["garage_backup_failed_buckets"], 1)
        self.assertEqual(after["backup_last_success_timestamp"], before)
        self.assertGreater(after["garage_backup_last_run_timestamp"], before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
