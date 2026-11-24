"""The London Flint's BitTorrent WAN block: `scripts/london-flint/london-bittorrent.sh`.

GL's DPI agent netifyd marks flows it recognises as BitTorrent with connmark
0x1000000 (flow action london-bittorrent, set up by provision.sh). The script
keeps a chain, first in FORWARD, that lets such a flow into the tunnel to
Sofia or the LANs and rejects it on the WAN.

The test runs the real script under busybox sh with stand-ins for iptables and
ip6tables that record their arguments, so nothing touches the firewall.
"""

from __future__ import annotations

import shutil
import stat
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent / "london-bittorrent.sh"
BUSYBOX = shutil.which("busybox")


def _stub(bin_dir: Path, name: str, body: str) -> None:
    path = bin_dir / name
    path.write_text("#!" + str(BUSYBOX) + " sh\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


@pytest.fixture
def calls(tmp_path: Path):
    if BUSYBOX is None:
        pytest.skip("busybox is not installed")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    log = tmp_path / "calls.log"
    for tool in ("iptables", "ip6tables"):
        # -C (check) finds nothing, so the hook gets inserted.
        _stub(bin_dir, tool, f'echo "{tool} $*" >> "{log}"\nfor a in "$@"; do [ "$a" = -C ] && exit 1; done\nexit 0\n')

    def run(*args: str) -> dict[str, list[str]]:
        subprocess.run([BUSYBOX, "sh", str(SCRIPT), *args], env={"PATH": str(bin_dir)}, check=True, timeout=20)
        out: dict[str, list[str]] = {"iptables": [], "ip6tables": []}
        for line in log.read_text().splitlines():
            tool, rest = line.split(" ", 1)
            out[tool].append(rest)
        return out

    return run


@pytest.mark.parametrize("tool", ["iptables", "ip6tables"])
def test_marked_flows_never_leave_through_the_wan(calls, tool: str) -> None:
    got = calls("apply")[tool]
    rules = [c for c in got if c.startswith("-A london_bittorrent")]
    assert rules[:3] == [f"-A london_bittorrent -o {dev} -j RETURN" for dev in ("wgclient1", "br-lan", "br-guest")]
    assert rules[-1] == "-A london_bittorrent -j REJECT"
    # First in FORWARD, before the ESTABLISHED accept: a flow is recognised
    # only a few packets in, when it is already established.
    assert "-I FORWARD 1 -m connmark --mark 0x1000000/0x1000000 -j london_bittorrent" in got


def test_unknown_command_fails(calls) -> None:
    with pytest.raises(subprocess.CalledProcessError):
        calls("nope")
