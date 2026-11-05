"""Tests for disk-read-sampler, run against a fake /proc and /sys tree.

    python3 -m pytest playbooks/files/k8s-node/test_disk_read_sampler.py
"""

import importlib.machinery
import importlib.util
import json
from pathlib import Path

import pytest

HERE = Path(__file__).parent
_loader = importlib.machinery.SourceFileLoader("sampler", str(HERE / "disk-read-sampler"))
_spec = importlib.util.spec_from_loader("sampler", _loader)
sampler = importlib.util.module_from_spec(_spec)
_loader.exec_module(sampler)

MB = 1_000_000


def write_diskstats(proc: Path, sectors_read: int, sectors_written: int = 0) -> None:
    # Fields: major minor name reads merged sectors_read ms writes merged sectors_written ...
    line = f"   8       0 sda 100 0 {sectors_read} 0 50 0 {sectors_written} 0 0 0 0 0 0 0 0 0 0\n"
    other = "   8      16 sdb 9 0 999999999 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n"
    (proc / "diskstats").write_text(line + other)


def write_proc(proc: Path, pid: int, comm: str, cmdline: str, read: int, written: int,
               cgroup: str = "0::/system.slice/ssh.service", start: int = 1000) -> None:
    d = proc / str(pid)
    d.mkdir(parents=True, exist_ok=True)
    (d / "comm").write_text(comm + "\n")
    (d / "cmdline").write_bytes(cmdline.replace(" ", "\0").encode() + b"\0")
    (d / "io").write_text(
        f"rchar: 0\nwchar: 0\nsyscr: 0\nsyscw: 0\nread_bytes: {read}\n"
        f"write_bytes: {written}\ncancelled_write_bytes: 0\n"
    )
    (d / "cgroup").write_text(cgroup + "\n")
    fields = ["x"] * 52
    fields[21] = str(start)
    (d / "stat").write_text(f"{pid} ({comm}) " + " ".join(fields[2:]) + "\n")


@pytest.fixture
def tree(tmp_path):
    proc = tmp_path / "proc"
    proc.mkdir()
    state = tmp_path / "state.json"
    return proc, state


def run(proc, state, now, threshold=40):
    return sampler.sample(proc_root=proc, disk="sda", state_path=state,
                          now=now, threshold_mbps=threshold)


def test_first_run_only_records_state(tree):
    proc, state = tree
    write_diskstats(proc, sectors_read=0)
    write_proc(proc, 10, "dd", "dd if=/dev/sda of=/dev/null", read=0, written=0)
    assert run(proc, state, now=100.0) == []
    assert json.loads(state.read_text())["sectors_read"] == 0


def test_quiet_disk_logs_nothing(tree):
    proc, state = tree
    write_diskstats(proc, 0)
    write_proc(proc, 10, "bash", "bash", 0, 0)
    run(proc, state, now=100.0)
    write_diskstats(proc, (10 * MB * 60) // 512)  # 10 MB/s over 60 s
    write_proc(proc, 10, "bash", "bash", 600 * MB, 0)
    assert run(proc, state, now=160.0) == []


def test_busy_disk_names_the_top_reader_with_its_cgroup(tree):
    proc, state = tree
    write_diskstats(proc, 0)
    write_proc(proc, 10, "dd", "dd if=/dev/sda of=/dev/null bs=1M", 0, 0)
    write_proc(proc, 11, "containerd", "/usr/bin/containerd", 0, 0,
               cgroup="0::/system.slice/containerd.service")
    run(proc, state, now=100.0)
    write_diskstats(proc, (90 * MB * 60) // 512)  # 90 MB/s
    write_proc(proc, 10, "dd", "dd if=/dev/sda of=/dev/null bs=1M", 5000 * MB, 0)
    write_proc(proc, 11, "containerd", "/usr/bin/containerd", 300 * MB, 50 * MB,
               cgroup="0::/system.slice/containerd.service")
    lines = run(proc, state, now=160.0)
    assert lines[0].startswith("sda read 90.0 MB/s")
    assert "pid=10" in lines[1] and "comm=dd" in lines[1]
    assert "cmd=dd if=/dev/sda of=/dev/null bs=1M" in lines[1]
    assert "cgroup=/system.slice/ssh.service" in lines[1]
    assert "read=5000.0MB" in lines[1]
    assert "pid=11" in lines[2]


def test_reused_pid_is_not_credited_with_the_old_process_bytes(tree):
    proc, state = tree
    write_diskstats(proc, 0)
    write_proc(proc, 10, "old", "old", 9000 * MB, 0, start=1000)
    run(proc, state, now=100.0)
    write_diskstats(proc, (90 * MB * 60) // 512)
    # Same pid, new process (different start time), which has read 100 MB so far.
    write_proc(proc, 10, "new", "new", 100 * MB, 0, start=2000)
    lines = run(proc, state, now=160.0)
    assert "read=100.0MB" in lines[1]


def test_process_that_vanished_is_skipped(tree):
    proc, state = tree
    write_diskstats(proc, 0)
    write_proc(proc, 10, "dd", "dd", 0, 0)
    run(proc, state, now=100.0)
    write_diskstats(proc, (90 * MB * 60) // 512)
    (proc / "10" / "io").unlink()
    lines = run(proc, state, now=160.0)
    assert lines[0].startswith("sda read 90.0 MB/s")
    assert len(lines) == 1


def test_counter_reset_after_reboot_logs_nothing(tree):
    proc, state = tree
    write_diskstats(proc, 10**9)
    run(proc, state, now=100.0)
    write_diskstats(proc, 5)
    assert run(proc, state, now=160.0) == []
