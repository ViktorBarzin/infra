#!/usr/bin/env python3
"""Checks for devvm-io-guard's decisions, against a fake /proc and cgroup tree.

Run it by hand, from anywhere, with no dependencies:

    python3 playbooks/files/devvm/devvm-io-guard-test.py

The guard throttles every user and kills processes owned by other users, so
three things are pinned down here: which processes it is willing to kill, which
one it picks, and when it moves between watching, clamping and killing. Nothing
here touches the real disk, the real cgroups or a real process.

The argv shapes are the ones measured on the devvm on 2026-10-11. An agent's
grep, find and rg in the Bash tool are shell-snapshot functions that run the
claude binary with argv0 set to ugrep, bfs or rg, and the built-in Grep tool
does the same with ugrep. Real grep shows up behind xargs, which does not see
shell functions.
"""
import importlib.util
import os
import shutil
import signal
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "devvm-io-guard")

BASH_SCOPE = ("/user.slice/user-1000.slice/user@1000.service/app.slice/"
              "run-u5001.scope")
PANE_SCOPE = ("/user.slice/user-1000.slice/user@1000.service/app.slice/"
              "tmux-spawn-abc.scope")
EMO_SCOPE = ("/user.slice/user-1002.slice/user@1002.service/app.slice/"
             "run-u77.scope")
SYSTEM = "/system.slice/docker.service"
CLAUDE = "/home/wizard/.local/share/claude/versions/2.3.1"
MB = 1024 * 1024


def load():
    spec = importlib.util.spec_from_loader("devvm_io_guard", loader=None)
    mod = importlib.util.module_from_spec(spec)
    with open(SCRIPT) as fh:
        exec(compile(fh.read(), SCRIPT, "exec"), mod.__dict__)
    return mod


G = load()


class Box:
    """A fake /proc and /sys/fs/cgroup, plus a record of what the guard did."""

    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="io-guard-test-")
        self.proc = os.path.join(self.root, "proc")
        self.cg = os.path.join(self.root, "cg")
        self.state = os.path.join(self.root, "run")
        os.makedirs(os.path.join(self.proc, "pressure"))
        os.makedirs(os.path.join(self.cg, "user.slice"))
        self.signals = []
        self.fairshare_runs = 0
        self.lines = []
        self.pressure(0.0, 0.0)

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def pressure(self, avg10, avg60):
        """Fractions, as the guard thinks of them; the file holds percent."""
        with open(os.path.join(self.proc, "pressure", "io"), "w") as fh:
            fh.write("some avg10=%.2f avg60=%.2f avg300=0.00 total=1\n"
                     % (avg10 * 100, avg60 * 100))
            fh.write("full avg10=%.2f avg60=%.2f avg300=0.00 total=1\n"
                     % (avg10 * 100, avg60 * 100))

    def slice(self, uid, rios=0):
        d = os.path.join(self.cg, "user.slice", "user-%d.slice" % uid)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "io.stat"), "w") as fh:
            fh.write("7:7 rbytes=1 wbytes=0 rios=9 wios=0 dbytes=0 dios=0\n")
            fh.write("252:0 rbytes=%d wbytes=0 rios=%d wios=0 dbytes=0 "
                     "dios=0\n" % (rios * 4096, rios))
        iomax = os.path.join(d, "io.max")
        if not os.path.exists(iomax):
            open(iomax, "w").close()

    def io_max(self, uid):
        with open(os.path.join(self.cg, "user.slice", "user-%d.slice" % uid,
                               "io.max")) as fh:
            return fh.read().strip()

    def proc_add(self, pid, argv, cgroup, ppid=1, start=1000,
                 read_bytes=0, blkio_ticks=0, stderr=None):
        d = os.path.join(self.proc, str(pid))
        os.makedirs(os.path.join(d, "fd"), exist_ok=True)
        with open(os.path.join(d, "cmdline"), "wb") as fh:
            fh.write(b"\0".join(a.encode() for a in argv) + b"\0")
        with open(os.path.join(d, "cgroup"), "w") as fh:
            fh.write("0::%s\n" % cgroup)
        if stderr:
            os.symlink(stderr, os.path.join(d, "fd", "2"))
        scope = os.path.join(self.cg, cgroup.lstrip("/"))
        os.makedirs(scope, exist_ok=True)
        with open(os.path.join(scope, "cgroup.procs"), "a") as fh:
            fh.write("%d\n" % pid)
        self.proc_io(pid, read_bytes, blkio_ticks, ppid=ppid, start=start)

    def proc_io(self, pid, read_bytes, blkio_ticks, ppid=None, start=None):
        d = os.path.join(self.proc, str(pid))
        if ppid is None or start is None:
            with open(os.path.join(d, "stat")) as fh:
                old = G.parse_stat(fh.read())
            ppid = old["ppid"] if ppid is None else ppid
            start = old["starttime"] if start is None else start
        # Field 3 onwards; field N sits at index N-3.
        rest = ["0"] * 50
        rest[0] = "S"
        rest[1] = str(ppid)          # field 4
        rest[19] = str(start)        # field 22
        rest[39] = str(blkio_ticks)  # field 42
        with open(os.path.join(d, "stat"), "w") as fh:
            fh.write("%d (2.3.1 x) %s\n" % (pid, " ".join(rest)))
        with open(os.path.join(d, "io"), "w") as fh:
            fh.write("rchar: %d\nwchar: 0\nsyscr: 1\nsyscw: 0\n"
                     "read_bytes: %d\nwrite_bytes: 0\n"
                     "cancelled_write_bytes: 0\n" % (read_bytes, read_bytes))

    def proc_del(self, pid):
        shutil.rmtree(os.path.join(self.proc, str(pid)), ignore_errors=True)

    def guard(self, **overrides):
        env = {
            "DEVVM_IO_GUARD_DRY_RUN": "0",
            "DEVVM_IO_GUARD_DEVNUM": "252:0",
            "DEVVM_IO_GUARD_PROC_ROOT": self.proc,
            "DEVVM_IO_GUARD_CGROUP_ROOT": self.cg,
            "DEVVM_IO_GUARD_STATE_DIR": self.state,
            "DEVVM_IO_GUARD_TEXTFILE_DIR": "",
        }
        env.update({"DEVVM_IO_GUARD_" + k: str(v)
                    for k, v in overrides.items()})
        cfg = G.Config(env)

        def kill(pid, sig):
            self.signals.append((pid, sig))

        def fairshare():
            self.fairshare_runs += 1

        return G.Guard(cfg, kill=kill, run_fairshare=fairshare,
                       log=self.lines.append, uid_name=lambda u: "u%d" % u)

    def logged(self, word):
        return [line for line in self.lines if ("action=%s " % word) in line]


class Scanners(unittest.TestCase):
    def test_measured_agent_shapes_are_scanners(self):
        for argv in (["ugrep", "-G", "--hidden", "-r", "foo", "/home"],
                     ["bfs", "-S", "dfs", "/", "-name", "x"],
                     ["rg", "foo", "/"],
                     ["/usr/bin/grep", "-l", "foo", "a.jsonl"],
                     ["egrep", "x"], ["du", "-sh", "/home"],
                     ["find", "/", "-name", "x"], ["tree", "/"],
                     ["locate", "x"], ["ls", "-R", "/"], ["ls", "-laR", "/"],
                     ["ls", "--recursive", "/"]):
            self.assertTrue(G.is_scanner(argv), argv)

    def test_everything_else_is_left_to_the_throttle(self):
        for argv in ([CLAUDE, "--session-id", "x"],
                     ["/home/wizard/.local/bin/claude"],
                     ["npm", "ci"], ["node", "vitest"], ["python3", "x.py"],
                     ["git", "grep", "foo"], ["ls", "-la", "/"],
                     ["ls", "-r"], ["tmux"], ["sshd: wizard"], ["xargs", "grep"],
                     ["docker", "buildx", "build", "."], []):
            self.assertFalse(G.is_scanner(argv), argv)

    def test_only_user_slice_processes_are_eligible(self):
        self.assertTrue(G.eligible(["ugrep", "x"], BASH_SCOPE))
        self.assertTrue(G.eligible(["ugrep", "x"], PANE_SCOPE))
        self.assertFalse(G.eligible(["ugrep", "x"], SYSTEM))
        self.assertFalse(G.eligible(["ugrep", "x"],
                                    "/system.slice/user.slice-lookalike"))

    def test_psi_is_read_as_a_fraction(self):
        text = ("some avg10=30.60 avg60=13.97 avg300=17.36 total=3\n"
                "full avg10=27.62 avg60=12.72 avg300=16.19 total=2\n")
        self.assertEqual(G.parse_psi(text), (0.2762, 0.1272))


class Stages(unittest.TestCase):
    """Watch, clamp, kill, release, against a fake clock."""

    def setUp(self):
        self.box = Box()
        self.box.slice(1000, rios=0)
        self.box.slice(1002, rios=0)
        self.out = os.path.join(self.box.root, "task.output")
        open(self.out, "w").close()

    def tearDown(self):
        self.box.close()

    def run_until(self, guard, start, end, every=2, before=None):
        t = start
        while t <= end:
            if before:
                before(t)
            guard.step(t)
            t += every
        return t

    def grow(self, pid, rate_bytes, rate_ticks):
        """A process that keeps reading: counters climb with the clock."""
        def before(t):
            self.box.proc_io(pid, int(rate_bytes * t), int(rate_ticks * t))
        return before

    def test_brief_pressure_does_nothing(self):
        g = self.box.guard()
        self.box.pressure(0.9, 0.9)
        self.run_until(g, 0, 18)
        self.assertFalse(g.clamped)
        self.assertEqual(self.box.io_max(1000), "")

    def test_pressure_for_twenty_seconds_clamps_reading_slices(self):
        g = self.box.guard()
        self.box.pressure(0.9, 0.9)
        rios = {"n": 0}

        def before(t):
            rios["n"] += 50
            self.box.slice(1000, rios=rios["n"])
            self.box.slice(1002, rios=rios["n"])
        self.run_until(g, 0, 20, before=before)
        self.assertTrue(g.clamped)
        # Two slices read in the window, so 100 total is 50 each.
        self.assertEqual(self.box.io_max(1000), "252:0 riops=50")
        self.assertEqual(self.box.io_max(1002), "252:0 riops=50")
        with open(os.path.join(self.box.state, "clamp")) as fh:
            self.assertEqual(fh.read().strip(), "50")
        self.assertEqual(len(self.box.logged("clamp")), 1)

    def test_a_lone_reader_gets_the_whole_clamp(self):
        g = self.box.guard()
        self.box.pressure(0.9, 0.9)
        rios = {"n": 0}

        def before(t):
            rios["n"] += 50
            self.box.slice(1000, rios=rios["n"])
        self.run_until(g, 0, 20, before=before)
        self.assertEqual(self.box.io_max(1000), "252:0 riops=100")

    def test_scanner_is_killed_after_the_clamp_fails_to_help(self):
        self.box.proc_add(400, ["zsh", "-c", "source snap; grep -r x ~"],
                          BASH_SCOPE, ppid=1, start=10, stderr=self.out)
        self.box.proc_add(401, ["ugrep", "-r", "x", "/home"], BASH_SCOPE,
                          ppid=400, start=11, stderr="/dev/null")
        g = self.box.guard()
        self.box.pressure(0.9, 0.9)
        # 20 s to clamp, then 30 s clamped before a kill is allowed.
        self.run_until(g, 0, 48, before=self.grow(401, 4 * MB, 50))
        self.assertEqual(self.box.signals, [])
        self.run_until(g, 50, 50, before=self.grow(401, 4 * MB, 50))
        # The scope holds nothing but the shell and the scanner, so the whole
        # command goes, which is what stops an xargs batch from carrying on.
        self.assertEqual(sorted(self.box.signals),
                         [(400, signal.SIGTERM), (401, signal.SIGTERM)])
        self.assertEqual(len(self.box.logged("kill")), 1)
        # The message lands where Claude reads the command's output: the
        # scope's shell, because the scanner's own stderr went to /dev/null.
        with open(self.out) as fh:
            note = fh.read()
        self.assertIn("devvm-io-guard", note)
        self.assertIn("homelab claude-usage", note)
        # Two seconds later anything left in the scope is SIGKILLed.
        g.step(52)
        kill_file = os.path.join(self.box.cg, BASH_SCOPE.lstrip("/"),
                                 "cgroup.kill")
        with open(kill_file) as fh:
            self.assertEqual(fh.read().strip(), "1")

    def test_kill_needs_pressure_still_high(self):
        self.box.proc_add(401, ["ugrep", "x"], PANE_SCOPE, start=11)
        g = self.box.guard()
        self.box.pressure(0.9, 0.9)
        self.run_until(g, 0, 40, before=self.grow(401, 4 * MB, 50))
        self.assertTrue(g.clamped)
        self.box.pressure(0.3, 0.5)   # the clamp worked
        self.run_until(g, 42, 70, before=self.grow(401, 4 * MB, 50))
        self.assertEqual(self.box.signals, [])

    def test_builds_are_throttled_never_killed(self):
        self.box.proc_add(500, ["npm", "ci"], BASH_SCOPE, start=10)
        self.box.proc_add(501, ["python3", "loop.py"], PANE_SCOPE, start=10)
        self.box.proc_add(502, ["git", "status"], PANE_SCOPE, start=10)
        g = self.box.guard()
        self.box.pressure(0.9, 0.9)

        def before(t):
            for pid in (500, 501, 502):
                self.box.proc_io(pid, 50 * MB * t, 100 * t)
        self.run_until(g, 0, 120, before=before)
        self.assertTrue(g.clamped)
        self.assertEqual(self.box.signals, [])
        self.assertEqual(self.box.logged("kill"), [])
        # It says why it did nothing, for the calibration read on 2026-10-14.
        self.assertTrue(self.box.logged("no-victim"))

    def test_picks_the_heaviest_scanner_and_waits_out_the_cooldown(self):
        self.box.proc_add(601, ["ugrep", "small"], PANE_SCOPE, start=11)
        self.box.proc_add(602, ["bfs", "-S", "dfs", "/"], EMO_SCOPE, start=11)
        g = self.box.guard()
        self.box.pressure(0.9, 0.9)

        def before(t):
            self.box.proc_io(601, 1 * MB * t, 0)
            # du/find shape: few bytes, lots of waiting on the disk.
            self.box.proc_io(602, 10000 * t, 80 * t)
        self.run_until(g, 0, 50, before=before)
        self.assertEqual(self.box.signals, [(602, signal.SIGTERM)])
        # It stays alive in the fake /proc. The cooldown holds off the next
        # decision for 20 s; the stale victim is not killed twice.
        self.run_until(g, 52, 68, before=before)
        self.assertEqual([s for s in self.box.signals
                          if s[1] == signal.SIGTERM], [(602, signal.SIGTERM)])

    def test_sigkill_skips_a_recycled_pid(self):
        self.box.proc_add(701, ["ugrep", "x"], PANE_SCOPE, start=11)
        g = self.box.guard()
        self.box.pressure(0.9, 0.9)
        self.run_until(g, 0, 50, before=self.grow(701, 4 * MB, 50))
        self.assertEqual(self.box.signals, [(701, signal.SIGTERM)])
        # The scanner exits on SIGTERM and the pid is reused by something else.
        self.box.proc_del(701)
        self.box.proc_add(701, ["vim"], PANE_SCOPE, start=999)
        g.step(52)
        self.assertNotIn((701, signal.SIGKILL), self.box.signals)

    def test_a_pane_scope_is_never_killed_whole(self):
        self.box.proc_add(800, [CLAUDE], PANE_SCOPE, start=5)
        self.box.proc_add(801, ["ugrep", "x"], PANE_SCOPE, ppid=800, start=11)
        g = self.box.guard()
        self.box.pressure(0.9, 0.9)
        self.run_until(g, 0, 52, before=self.grow(801, 4 * MB, 50))
        pids = {pid for pid, _ in self.box.signals}
        self.assertEqual(pids, {801})
        kill_file = os.path.join(self.box.cg, PANE_SCOPE.lstrip("/"),
                                 "cgroup.kill")
        self.assertFalse(os.path.exists(kill_file))

    def test_a_scanner_inside_a_build_takes_only_itself(self):
        self.box.proc_add(900, ["zsh", "-c", "make test"], BASH_SCOPE, start=5)
        self.box.proc_add(901, ["make", "test"], BASH_SCOPE, ppid=900, start=6)
        self.box.proc_add(902, ["grep", "-r", "x", "."], BASH_SCOPE,
                          ppid=901, start=7)
        g = self.box.guard()
        self.box.pressure(0.9, 0.9)
        self.run_until(g, 0, 52, before=self.grow(902, 4 * MB, 50))
        self.assertEqual({pid for pid, _ in self.box.signals}, {902})

    def test_xargs_parent_goes_with_its_grep(self):
        self.box.proc_add(950, ["python3", "driver.py"], BASH_SCOPE, start=5)
        self.box.proc_add(951, ["xargs", "grep", "-l", "x"], BASH_SCOPE,
                          ppid=950, start=6)
        self.box.proc_add(952, ["grep", "-l", "x", "a", "b"], BASH_SCOPE,
                          ppid=951, start=7)
        g = self.box.guard()
        self.box.pressure(0.9, 0.9)
        self.run_until(g, 0, 50, before=self.grow(952, 4 * MB, 50))
        self.assertEqual({pid for pid, _ in self.box.signals}, {951, 952})

    def test_release_after_a_quiet_minute(self):
        g = self.box.guard()
        self.box.pressure(0.9, 0.9)
        rios = {"n": 0}

        def before(t):
            rios["n"] += 50
            self.box.slice(1000, rios=rios["n"])
        self.run_until(g, 0, 20, before=before)
        self.assertTrue(g.clamped)
        self.box.pressure(0.1, 0.3)    # avg60 still above the 0.2 release line
        self.run_until(g, 22, 120)
        self.assertTrue(g.clamped)
        self.box.pressure(0.05, 0.1)
        self.run_until(g, 122, 180)
        self.assertTrue(g.clamped)     # 58 s quiet
        g.step(182)
        self.assertFalse(g.clamped)
        self.assertFalse(os.path.exists(os.path.join(self.box.state, "clamp")))
        # Fairshare puts back whatever it wants, rather than the guard guessing.
        self.assertEqual(self.box.fairshare_runs, 1)
        self.assertEqual(len(self.box.logged("release")), 1)

    def test_dry_run_decides_everything_and_changes_nothing(self):
        self.box.proc_add(401, ["ugrep", "-r", "x", "/"], PANE_SCOPE,
                          start=11, stderr=self.out)
        g = self.box.guard(DRY_RUN=1)
        self.box.pressure(0.9, 0.9)
        rios = {"n": 0}

        def before(t):
            rios["n"] += 50
            self.box.slice(1000, rios=rios["n"])
            self.box.proc_io(401, 4 * MB * t, 50 * t)
        self.run_until(g, 0, 60, before=before)
        self.assertEqual(len(self.box.logged("would-clamp")), 1)
        self.assertEqual(len(self.box.logged("would-kill")), 1)
        self.assertEqual(self.box.signals, [])
        self.assertEqual(self.box.io_max(1000), "")
        self.assertFalse(os.path.exists(os.path.join(self.box.state, "clamp")))
        with open(self.out) as fh:
            self.assertEqual(fh.read(), "")
        self.box.pressure(0.0, 0.0)
        self.run_until(g, 62, 130)
        self.assertEqual(len(self.box.logged("would-release")), 1)
        self.assertEqual(self.box.fairshare_runs, 0)

    def test_a_stale_clamp_from_a_crash_is_cleared_at_start(self):
        os.makedirs(self.box.state)
        with open(os.path.join(self.box.state, "clamp"), "w") as fh:
            fh.write("50\n")
        self.box.guard()
        self.assertFalse(os.path.exists(os.path.join(self.box.state, "clamp")))
        self.assertEqual(self.box.fairshare_runs, 1)

    def test_a_broken_sweep_fails_open(self):
        g = self.box.guard()
        os.unlink(os.path.join(self.box.proc, "pressure", "io"))
        g.safe_step(0)   # logged, not raised
        self.assertTrue(self.box.logged("error"))
        self.assertFalse(g.clamped)


if __name__ == "__main__":
    unittest.main(verbosity=1)
