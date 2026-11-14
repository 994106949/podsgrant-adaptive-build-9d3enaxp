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
    if control.get("Version") != "0.5.7~adts3diag4":
        raise ValueError(f"unexpected Version: {control.get('Version')!r}")

    payload_name, archive = read_payload(members)
    files = {
        member.name.lstrip("./"): member
        for member in archive.getmembers()
        if member.isfile()
    }
    required = {
        "Library/MobileSubstrate/DynamicLibraries/PodsGrantAACPDiag.dylib",
        "Library/MobileSubstrate/DynamicLibraries/PodsGrantAACPDiag.plist",
        "Library/MobileSubstrate/DynamicLibraries/PodsGrantAACPDiagHelper.dylib",
        "Library/MobileSubstrate/DynamicLibraries/PodsGrantAACPDiagHelper.plist",
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
    if any(name.startswith("var/jb/") for name in files):
        raise ValueError("unexpected rootless var/jb payload")

    print(
        f"package={package} payload={payload_name} files={len(files)} "
        f"architectures=arm64,arm64e package_version={control['Version']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
