from __future__ import annotations

import gzip
import io
import lzma
import pathlib
import plistlib
import struct
import sys
import tarfile


CPU_TYPE_ARM64 = 0x0100000C
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF


def read_ar(path: pathlib.Path) -> dict[str, bytes]:
    raw = path.read_bytes()
    if not raw.startswith(b"!<arch>\n"):
        raise ValueError("not a Debian ar archive")
    members: dict[str, bytes] = {}
    offset = 8
    while offset < len(raw):
        if offset + 60 > len(raw):
            raise ValueError("truncated ar member header")
        name = raw[offset : offset + 16].decode("ascii").strip().rstrip("/")
        size = int(raw[offset + 48 : offset + 58].decode("ascii").strip())
        start = offset + 60
        members[name] = raw[start : start + size]
        offset = start + size + (size & 1)
    return members


def read_payload(members: dict[str, bytes]) -> tuple[str, tarfile.TarFile]:
    payload_name = next(
        name for name in members if name.startswith("data.tar")
    )
    data = members[payload_name]
    if payload_name.endswith(".gz"):
        data = gzip.decompress(data)
    elif payload_name.endswith(".xz"):
        data = lzma.decompress(data)
    elif payload_name.endswith(".lzma"):
        data = lzma.decompress(data)
    return payload_name, tarfile.open(fileobj=io.BytesIO(data))


def normalize_payload_name(name: str) -> str:
    normalized = name.lstrip("./")
    if normalized.startswith("var/jb/"):
        normalized = normalized[len("var/jb/") :]
    return normalized


def read_control(members: dict[str, bytes]) -> dict[str, str]:
    control_name = next(
        name for name in members if name.startswith("control.tar")
    )
    data = members[control_name]
    if control_name.endswith(".gz"):
        data = gzip.decompress(data)
    elif control_name.endswith(".xz"):
        data = lzma.decompress(data)
    elif control_name.endswith(".lzma"):
        data = lzma.decompress(data)
    values: dict[str, str] = {}
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        member_name = next(
            item.name
            for item in archive.getmembers()
            if item.name.lstrip("./") == "control"
        )
        extracted = archive.extractfile(member_name)
        if extracted is None:
            raise ValueError("control member is empty")
        for line in extracted.read().decode("utf-8").splitlines():
            if ": " in line:
                key, value = line.split(": ", 1)
                values[key] = value
    return values


def macho_architectures(data: bytes) -> set[tuple[int, int]]:
    if len(data) < 8:
        return set()
    magic, count = struct.unpack_from(">II", data, 0)
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        result: set[tuple[int, int]] = set()
        cursor = 8
        for _ in range(count):
            if magic == FAT_MAGIC:
                cpu_type, cpu_subtype, _offset, _size, _align = (
                    struct.unpack_from(">iiIII", data, cursor)
                )
                cursor += 20
            else:
                (
                    cpu_type,
                    cpu_subtype,
                    _offset,
                    _size,
                    _align,
                    _reserved,
                ) = struct.unpack_from(">iiIIII", data, cursor)
                cursor += 32
            result.add(
                (
                    cpu_type & 0xFFFFFFFF,
                    cpu_subtype & 0x00FFFFFF,
                )
            )
        return result

    if len(data) < 12:
        return set()
    little_magic, cpu_type, cpu_subtype = struct.unpack_from("<Iii", data, 0)
    if little_magic == MH_MAGIC_64:
        return {(cpu_type & 0xFFFFFFFF, cpu_subtype & 0x00FFFFFF)}
    return set()


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <package.deb>", file=sys.stderr)
        return 2
    package = pathlib.Path(sys.argv[1]).resolve()
    members = read_ar(package)
    control = read_control(members)
    if control.get("Package") != "com.lns.pogr.aacpdiag":
        raise ValueError(f"unexpected Package: {control.get('Package')!r}")
    if control.get("Version") != "0.5.7~adts3diag6":
        raise ValueError(f"unexpected Version: {control.get('Version')!r}")

    payload_name, archive = read_payload(members)
    files: dict[str, tarfile.TarInfo] = {}
    for member in archive.getmembers():
        if not member.isfile():
            continue
        normalized = normalize_payload_name(member.name)
        if normalized in files:
            raise ValueError(f"duplicate normalized payload path: {normalized}")
        files[normalized] = member

    required = {
        "Library/MobileSubstrate/DynamicLibraries/PodsGrantAACPDiag.dylib",
        "Library/MobileSubstrate/DynamicLibraries/PodsGrantAACPDiag.plist",
        "Library/MobileSubstrate/DynamicLibraries/PodsGrantAACPDiagHelper.dylib",
        "Library/MobileSubstrate/DynamicLibraries/PodsGrantAACPDiagHelper.plist",
        "Library/LaunchDaemons/com.lns.pogr.aacpdiagd.plist",
        "usr/bin/aacpdiagd",
    }
    missing = sorted(required - set(files))
    if missing:
        raise ValueError(f"missing payload files: {missing}")

    expected_architectures = {
        (CPU_TYPE_ARM64, 0),
        (CPU_TYPE_ARM64, 2),
    }
    for dylib_name in (
        "Library/MobileSubstrate/DynamicLibraries/PodsGrantAACPDiag.dylib",
        "Library/MobileSubstrate/DynamicLibraries/PodsGrantAACPDiagHelper.dylib",
        "usr/bin/aacpdiagd",
    ):
        extracted = archive.extractfile(files[dylib_name])
        if extracted is None:
            raise ValueError(f"cannot read {dylib_name}")
        architectures = macho_architectures(extracted.read())
        if not expected_architectures.issubset(architectures):
            raise ValueError(
                f"{dylib_name} architectures {architectures} do not contain "
                f"{expected_architectures}"
            )

    if files["usr/bin/aacpdiagd"].mode & 0o111 == 0:
        raise ValueError("usr/bin/aacpdiagd is not executable")
    expected_plist_path = (
        pathlib.Path(__file__).resolve().parent.parent
        / "daemon"
        / "com.lns.pogr.aacpdiagd.plist"
    )
    if not expected_plist_path.is_file():
        raise ValueError(f"source daemon plist is missing: {expected_plist_path}")
    expected_plist = expected_plist_path.read_bytes()
    daemon_plist_name = "Library/LaunchDaemons/com.lns.pogr.aacpdiagd.plist"
    daemon_plist_extracted = archive.extractfile(files[daemon_plist_name])
    if daemon_plist_extracted is None:
        raise ValueError("cannot read packaged LaunchDaemon plist")
    daemon_plist_bytes = daemon_plist_extracted.read()
    if daemon_plist_bytes != expected_plist:
        raise ValueError("packaged LaunchDaemon plist differs from source")

    daemon_plist = plistlib.loads(daemon_plist_bytes)
    if daemon_plist.get("Label") != "com.lns.pogr.aacpdiagd":
        raise ValueError("LaunchDaemon has an unexpected Label")
    if daemon_plist.get("ProgramArguments") != [
        "/var/jb/usr/bin/aacpdiagd"
    ]:
        raise ValueError("LaunchDaemon has an unexpected ProgramArguments")
    for key in ("RunAtLoad", "KeepAlive"):
        if daemon_plist.get(key) is not True:
            raise ValueError(f"LaunchDaemon {key} must be true")
    if daemon_plist.get("ThrottleInterval") != 2:
        raise ValueError("LaunchDaemon has an unexpected ThrottleInterval")
    if daemon_plist.get("ProcessType") != "Background":
        raise ValueError("LaunchDaemon has an unexpected ProcessType")
    if daemon_plist.get("StandardOutPath") != (
        "/var/tmp/com.lns.pogr.aacpdiag/daemon-stdout.log"
    ):
        raise ValueError("LaunchDaemon has an unexpected StandardOutPath")
    if daemon_plist.get("StandardErrorPath") != (
        "/var/tmp/com.lns.pogr.aacpdiag/daemon-stderr.log"
    ):
        raise ValueError("LaunchDaemon has an unexpected StandardErrorPath")

    ui_filter_name = (
        "Library/MobileSubstrate/DynamicLibraries/PodsGrantAACPDiag.plist"
    )
    helper_filter_name = (
        "Library/MobileSubstrate/DynamicLibraries/"
        "PodsGrantAACPDiagHelper.plist"
    )
    ui_extracted = archive.extractfile(files[ui_filter_name])
    helper_extracted = archive.extractfile(files[helper_filter_name])
    if ui_extracted is None or helper_extracted is None:
        raise ValueError("cannot read filter plists")
    ui_filter = plistlib.loads(ui_extracted.read())
    helper_filter = plistlib.loads(helper_extracted.read())
    if "com.apple.Preferences" not in (
        ui_filter.get("Filter", {}).get("Bundles", [])
    ):
        raise ValueError("UI filter is missing com.apple.Preferences")
    if "bluetoothd" not in (
        helper_filter.get("Filter", {}).get("Executables", [])
    ):
        raise ValueError("helper filter is missing bluetoothd")
    if "heard" not in (
        helper_filter.get("Filter", {}).get("Executables", [])
    ):
        raise ValueError("helper filter is missing heard")

    binary_markers = {
        "Library/MobileSubstrate/DynamicLibraries/PodsGrantAACPDiag.dylib": (
            b"source=aacp_ui",
            b"0.5.7~adts3diag6",
        ),
        "Library/MobileSubstrate/DynamicLibraries/PodsGrantAACPDiagHelper.dylib": (
            b"source=helper",
            b"0.5.7~adts3diag6",
        ),
        "usr/bin/aacpdiagd": (
            b"source=aacpdiagd",
            b"0.5.7~adts3diag6",
        ),
    }
    for binary_name, markers in binary_markers.items():
        extracted = archive.extractfile(files[binary_name])
        if extracted is None:
            raise ValueError(f"cannot read {binary_name}")
        data = extracted.read()
        missing_markers = [marker for marker in markers if marker not in data]
        if missing_markers:
            raise ValueError(
                f"{binary_name} is missing markers: {missing_markers}"
            )

    print(
        f"package={package} payload={payload_name} files={len(files)} "
        f"architectures=arm64,arm64e package_version={control['Version']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
