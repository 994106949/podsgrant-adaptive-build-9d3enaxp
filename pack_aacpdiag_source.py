from __future__ import annotations

import pathlib
import tarfile


ROOT = pathlib.Path(__file__).resolve().parent
SOURCE = ROOT / "aacpdiag"
ARCHIVE = ROOT / "aacpdiag-source.tar.gz"


def is_source_file(path: pathlib.Path) -> bool:
    relative = path.relative_to(ROOT)
    return (
        path.is_file()
        and "__pycache__" not in relative.parts
        and path.suffix != ".pyc"
    )


def main() -> int:
    files = sorted(
        (path for path in SOURCE.rglob("*") if is_source_file(path)),
        key=lambda path: path.relative_to(ROOT).as_posix(),
    )
    with tarfile.open(ARCHIVE, "w:gz") as archive:
        for path in files:
            archive.add(path, arcname=path.relative_to(ROOT).as_posix())

    required = {
        "aacpdiag/control",
        "aacpdiag/daemon/main.m",
        "aacpdiag/daemon/Makefile",
        "aacpdiag/daemon/com.lns.pogr.aacpdiagd.plist",
        "aacpdiag/helper/Makefile",
        "aacpdiag/helper/PodsGrantAACPDiagHelper.plist",
        "aacpdiag/helper/Tweak.x",
        "aacpdiag/layout/Library/LaunchDaemons/com.lns.pogr.aacpdiagd.plist",
        "aacpdiag/layout/DEBIAN/postinst",
        "aacpdiag/layout/DEBIAN/postrm",
        "aacpdiag/shared/AACPDiag.h",
        "aacpdiag/shared/AACPDiagCommon.m",
        "aacpdiag/shared/AACPDiagNative.m",
        "aacpdiag/shared/AACPDiagRuntimeHooks.m",
        "aacpdiag/shared/AACPDiagTransport.m",
        "aacpdiag/ui/Makefile",
        "aacpdiag/ui/PodsGrantAACPDiag.plist",
        "aacpdiag/ui/Tweak.x",
        "aacpdiag/tools/verify_package.py",
    }
    with tarfile.open(ARCHIVE, "r:gz") as archive:
        names = set(archive.getnames())
        control = archive.extractfile("aacpdiag/control")
        if control is None:
            raise SystemExit("packed control file is missing")
        version = [
            line
            for line in control.read().decode("utf-8").splitlines()
            if line.startswith("Version: ")
        ]
        packed_scripts = {}
        for script_name in (
            "aacpdiag/layout/DEBIAN/postinst",
            "aacpdiag/layout/DEBIAN/postrm",
        ):
            member = archive.extractfile(script_name)
            if member is None:
                raise SystemExit(f"packed script is missing: {script_name}")
            packed_scripts[script_name] = member.read()
        packed_sources = {}
        for source_name in (
            "aacpdiag/helper/Tweak.x",
            "aacpdiag/daemon/main.m",
            "aacpdiag/shared/AACPDiagCommon.m",
        ):
            member = archive.extractfile(source_name)
            if member is None:
                raise SystemExit(f"packed source is missing: {source_name}")
            packed_sources[source_name] = member.read()

    missing = sorted(required - names)
    if missing:
        raise SystemExit(f"packed archive is missing files: {missing}")
    if version != ["Version: 0.5.8~adts3diag8"]:
        raise SystemExit(f"unexpected packed version: {version}")
    script_markers = {
        "aacpdiag/layout/DEBIAN/postinst": (
            b"0.5.8~adts3diag8",
            b"source_ready_file",
            b"claim-*",
            b"daemon_direct_fallback_begin",
            b"daemon_direct_fallback_status",
            b"/var/jb/usr/bin/aacpdiagd",
        ),
        "aacpdiag/layout/DEBIAN/postrm": (
            b"claim-*",
            b"result-heard.plist",
            b"bootout",
            b"killall",
        ),
    }
    for script_name, markers in script_markers.items():
        data = packed_scripts[script_name]
        if b"\r" in data:
            raise SystemExit(f"packed script contains CR characters: {script_name}")
        if not data.startswith(b"#!/bin/sh\n"):
            raise SystemExit(
                f"packed script has no POSIX shell shebang: {script_name}"
            )
        missing_markers = [marker for marker in markers if marker not in data]
        if missing_markers:
            raise SystemExit(
                f"packed script is missing markers: {script_name} {missing_markers}"
            )
    source_markers = {
        "aacpdiag/helper/Tweak.x": (
            b"helper_polling_started",
            b"helper_request_poll",
            b"helper_transport_start",
            b"AAPDiagClaimRequest",
        ),
        "aacpdiag/daemon/main.m": (
            b"750ULL * NSEC_PER_MSEC",
            b"fallback_skipped reason=helper_claimed",
            b"fallback_claimed",
            b"request_claimed",
        ),
        "aacpdiag/shared/AACPDiagCommon.m": (
            b"claim-%llu",
            b"result_written",
            b"result-%@.plist",
        ),
    }
    for source_name, markers in source_markers.items():
        data = packed_sources[source_name]
        missing_markers = [marker for marker in markers if marker not in data]
        if missing_markers:
            raise SystemExit(
                f"packed source is missing markers: {source_name} {missing_markers}"
            )

    print(f"archive={ARCHIVE}")
    print(f"files={len(files)}")
    print(f"version={version[0]}")
    print("control_scripts=postinst,postrm")
    print("helper_transport_markers=ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
