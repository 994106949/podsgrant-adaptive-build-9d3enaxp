from __future__ import annotations

import io
import pathlib
import plistlib
import tarfile


ROOT = pathlib.Path(__file__).resolve().parent
SOURCE = ROOT / "aacpdiag"
ARCHIVE = ROOT / "aacpdiag-source.tar.gz"
PACKAGE_VERSION = "0.5.8~adts3diag10"
DIAGNOSTIC_MARKER = "diag10_active_aacp_fd_reuse"


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
            arcname = path.relative_to(ROOT).as_posix()
            info = archive.gettarinfo(str(path), arcname=arcname)
            data = path.read_bytes().replace(b"\r\n", b"\n")
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))

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
        for name in names:
            member = archive.extractfile(name)
            if member is not None and b"\r" in member.read():
                raise SystemExit(f"packed file contains CR characters: {name}")
        control = archive.extractfile("aacpdiag/control")
        if control is None:
            raise SystemExit("packed control file is missing")
        control_data = control.read()
        if b"\r" in control_data:
            raise SystemExit("packed control file contains CR characters")
        version = [
            line
            for line in control_data.decode("utf-8").splitlines()
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
        "aacpdiag/daemon/Makefile",
        "aacpdiag/daemon/main.m",
        "aacpdiag/shared/AACPDiagCommon.m",
        "aacpdiag/shared/AACPDiagNative.m",
        "aacpdiag/shared/AACPDiagRuntimeHooks.m",
        "aacpdiag/shared/AACPDiagTransport.m",
        "aacpdiag/ui/Tweak.x",
    ):
            member = archive.extractfile(source_name)
            if member is None:
                raise SystemExit(f"packed source is missing: {source_name}")
            packed_sources[source_name] = member.read()
        helper_filter_member = archive.extractfile(
            "aacpdiag/helper/PodsGrantAACPDiagHelper.plist"
        )
        if helper_filter_member is None:
            raise SystemExit("packed helper filter is missing")
        helper_filter = plistlib.loads(helper_filter_member.read())

    missing = sorted(required - names)
    if missing:
        raise SystemExit(f"packed archive is missing files: {missing}")
    if version != [f"Version: {PACKAGE_VERSION}"]:
        raise SystemExit(f"unexpected packed version: {version}")
    script_markers = {
        "aacpdiag/layout/DEBIAN/postinst": (
            PACKAGE_VERSION.encode("ascii"),
            b"source_ready_file",
            b"claim-*",
            b"daemon_direct_fallback_begin",
            b"daemon_direct_fallback_status",
            b"/var/jb/Library/LaunchDaemons/com.lns.pogr.aacpdiagd.plist",
            b"/Library/LaunchDaemons/com.lns.pogr.aacpdiagd.plist",
            b"/var/jb/usr/bin/aacpdiagd",
            b"/usr/bin/aacpdiagd",
            b"plutil",
            b"PlistBuddy",
            b"ProgramArguments",
            b"daemon_plist_rewrite_begin",
            b"bootout",
            b"bootstrap",
            b"kickstart",
            b"${DPKG_ADMINDIR:-/var/lib/dpkg}/info/com.lns.pogr.aacpdiag.list",
        ),
        "aacpdiag/layout/DEBIAN/postrm": (
            b"claim-*",
            b"result-bluetoothd.plist",
            b"result-aacpdiagd.plist",
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
        if b"heard" in data.lower():
            raise SystemExit(
                f"packed script still contains legacy heard handling: {script_name}"
            )
    source_markers = {
        "aacpdiag/helper/Tweak.x": (
            b"helper_polling_started",
            b"helper_request_poll",
            b"helper_transport_start",
            b"AAPDiagClaimRequest",
            b"isBluetoothd",
        ),
        "aacpdiag/daemon/Makefile": (
            b"-DAACPDIAG_TRANSPORT_NO_ACTIVE_FD=1",
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
            PACKAGE_VERSION.encode("ascii"),
        ),
        "aacpdiag/shared/AACPDiagNative.m": (
            b"setListeningMode:error:",
            b"setListeningMode:",
            b"sendUpdateToAccessory",
            b"setAdaptiveTransparencyEnabled:",
            b"getter_before",
            b"getter_after",
            b"native_setter_invoked_unconfirmed",
            b"informational_only",
        ),
        "aacpdiag/shared/AACPDiagRuntimeHooks.m": (
            b"diag10_active_aacp_fd_reuse",
            b"AAP_DIAG_ACTIVE_FD_WINDOW_US",
            b"AAPDiagCopyActiveAACPDescriptorWithMatch",
            b"AAPDiagCopyAACPRXFramesForDescriptor",
            b"AAPDiagRecvFromHook",
            b"AAPDiagReadHook",
        ),
        "aacpdiag/shared/AACPDiagTransport.m": (
            b"AAPDiagRunActiveDescriptorTransport",
            b"active_aacp_fd_tx_unconfirmed",
            b"active_aacp_fd_tx_failed",
            b"active_fd_selected",
            b"AACPDIAG_TRANSPORT_NO_ACTIVE_FD",
        ),
        "aacpdiag/ui/Tweak.x": (
            b"Adaptive Transparency Mode",
            b"active_aacp_fd_tx_unconfirmed",
            b"active_aacp_fd_tx_failed",
            b"getter_before",
            b"getter_after",
            b"send_update_after_mode",
            b"send_update_after_adaptive",
            b"set_adaptive_transparency",
        ),
    }
    for source_name, markers in source_markers.items():
        data = packed_sources[source_name]
        missing_markers = [marker for marker in markers if marker not in data]
        if missing_markers:
            raise SystemExit(
                f"packed source is missing markers: {source_name} {missing_markers}"
            )

    combined_payload = b"\n".join(
        [*packed_scripts.values(), *packed_sources.values()]
    )
    if DIAGNOSTIC_MARKER.encode("ascii") not in combined_payload:
        raise SystemExit(
            f"packed payload is missing diagnostic marker: {DIAGNOSTIC_MARKER}"
        )

    executables = helper_filter.get("Filter", {}).get("Executables")
    if executables != ["bluetoothd"]:
        raise SystemExit(
            f"helper filter must target only bluetoothd: {executables!r}"
        )

    ui_source = packed_sources["aacpdiag/ui/Tweak.x"]
    if ui_source.count(b"Adaptive Transparency Mode") != 1:
        raise SystemExit(
            "UI must expose exactly one Adaptive Transparency Mode action"
        )
    for legacy_text in (
        b"Test ANC",
        b"Test Transparency",
        b"Enable Adaptive Transparency",
        b"No Confirmation",
    ):
        if legacy_text in ui_source:
            raise SystemExit(
                f"UI contains legacy action text: {legacy_text.decode('ascii')}"
            )

    print(f"archive={ARCHIVE}")
    print(f"files={len(files)}")
    print(f"version={version[0]}")
    print("control_scripts=postinst,postrm")
    print("helper_transport_markers=ok")
    print(f"diagnostic_marker={DIAGNOSTIC_MARKER}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
