#!/usr/bin/env python3
"""Build london-drop-probe_<version>_all.ipk from drop-probe.sh.

The Flint's API allows installing an uploaded package (LuCI -> System ->
Software -> Upload Package) but not writing arbitrary files, so the probe ships
as a package that shows up, and can be removed, in that UI.

Usage: build-ipk.py <version> <out-dir>
"""
import io
import sys
import tarfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
NAME = "london-drop-probe"


def add_bytes(tar: tarfile.TarFile, name: str, data: bytes, mode: int) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = mode
    info.mtime = int(time.time())
    info.uname = info.gname = "root"
    tar.addfile(info, io.BytesIO(data))


def add_dir(tar: tarfile.TarFile, name: str) -> None:
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE
    info.mode = 0o755
    info.mtime = int(time.time())
    tar.addfile(info)


def targz(build) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.GNU_FORMAT) as tar:
        build(tar)
    return buf.getvalue()


def main(version: str, out_dir: str) -> Path:
    script = (HERE / "drop-probe.sh").read_bytes()
    init = (HERE / "london-drop-probe.init").read_bytes()

    def data(tar):
        for d in ("./usr", "./usr/bin", "./etc", "./etc/init.d"):
            add_dir(tar, d)
        add_bytes(tar, "./usr/bin/london-drop-probe", script, 0o755)
        add_bytes(tar, f"./etc/init.d/{NAME}", init, 0o755)

    control_text = (
        f"Package: {NAME}\n"
        f"Version: {version}\n"
        "Architecture: all\n"
        "Maintainer: infra repo (scripts/london-flint)\n"
        "Section: utils\n"
        "Depends: curl\n"
        "Description: London internet-drop probe, a procd service (LuCI System -> Startup).\n"
    ).encode()

    # Enable and start on install, stop and disable on removal, the same
    # effect as the buttons in LuCI -> System -> Startup.
    postinst = (
        "#!/bin/sh\n"
        f'[ -n "$IPKG_INSTROOT" ] || {{ /etc/init.d/{NAME} enable; /etc/init.d/{NAME} restart; }}\n'
        "exit 0\n"
    ).encode()
    prerm = (
        "#!/bin/sh\n"
        f'[ -n "$IPKG_INSTROOT" ] || {{ /etc/init.d/{NAME} stop; /etc/init.d/{NAME} disable; }}\n'
        "exit 0\n"
    ).encode()

    def control(tar):
        add_bytes(tar, "./control", control_text, 0o644)
        add_bytes(tar, "./postinst", postinst, 0o755)
        add_bytes(tar, "./prerm", prerm, 0o755)

    data_gz = targz(data)
    control_gz = targz(control)

    def outer(tar):
        add_bytes(tar, "./debian-binary", b"2.0\n", 0o644)
        add_bytes(tar, "./data.tar.gz", data_gz, 0o644)
        add_bytes(tar, "./control.tar.gz", control_gz, 0o644)

    out = Path(out_dir) / f"{NAME}_{version}_all.ipk"
    out.write_bytes(targz(outer))
    return out


if __name__ == "__main__":
    print(main(sys.argv[1], sys.argv[2]))
