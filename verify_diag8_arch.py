from __future__ import annotations

import gzip
import io
import lzma
import struct
import tarfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent
DEB = (
    ROOT
    / "_final_diag8"
    / "PodsGrant-AACP-Diagnostics-diag8-roothide.deb"
)
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
CPU_TYPE_ARM64 = 0x0100000C
EXPECTED_SUBTYPES = {0, 2}


def ar_members(blob: bytes) -> dict[str, bytes]:
    result: dict[str, bytes] = {}
    offset = 8
    while offset < len(blob):
        header = blob[offset : offset + 60]
        if len(header) != 60:
            raise ValueError("truncated ar member header")
        name = header[:16].decode("ascii").strip().rstrip("/")
        size_text = header[48:58].decode("ascii").strip()
        size = int(size_text)
        start = offset + 60
        result[name] = blob[start : start + size]
        offset = start + size + (size & 1)
    return result


def payload_bytes(members: dict[str, bytes]) -> bytes:
    name = next(name for name in members if name.startswith("data.tar"))
    data = members[name]
    if name.endswith(".gz"):
        return gzip.decompress(data)
    if name.endswith((".xz", ".lzma")):
        return lzma.decompress(data)
    return data


def fat_slices(blob: bytes) -> list[tuple[int, int, bytes]]:
    magic, count = struct.unpack_from(">II", blob, 0)
    if magic not in (FAT_MAGIC, FAT_MAGIC_64):
        raise ValueError(f"not a universal Mach-O: {magic:08x}")
    cursor = 8
    result = []
    for _ in range(count):
        if magic == FAT_MAGIC:
            cpu_type, cpu_subtype, offset, size, _align = struct.unpack_from(
                ">iiIII", blob, cursor
            )
            cursor += 20
        else:
            cpu_type, cpu_subtype, offset, size, _align, _reserved = (
                struct.unpack_from(">iiIIII", blob, cursor)
            )
            cursor += 32
        result.append(
            (
                cpu_type & 0xFFFFFFFF,
                cpu_subtype & 0x00FFFFFF,
                blob[offset : offset + size],
            )
        )
    return result


def verify_macho(name: str, blob: bytes) -> None:
    slices = fat_slices(blob)
    observed: set[int] = set()
    details = []
    for cpu_type, cpu_subtype, image in slices:
        if cpu_type != CPU_TYPE_ARM64:
            raise ValueError(f"{name} has a non-arm64 slice")
        magic, _cputype, _subtype, filetype, _ncmds, _sizeofcmds, _flags = (
            struct.unpack_from("<IiiIIII", image, 0)
        )
        if magic != 0xFEEDFACF:
            raise ValueError(f"{name} arm64 slice is not a thin Mach-O 64")
        observed.add(cpu_subtype)
        details.append(
            {
                "subtype": "arm64e"
                if cpu_subtype == 2
                else "arm64"
                if cpu_subtype == 0
                else f"0x{cpu_subtype:x}",
                "filetype": filetype,
                "macho_magic": f"0x{magic:08x}",
            }
        )
    if observed != EXPECTED_SUBTYPES:
        raise ValueError(
            f"{name} expected arm64 and arm64e slices, got {sorted(observed)}"
        )
    print(f"{name}: {details}")


def main() -> int:
    if not DEB.is_file():
        raise SystemExit(f"package is missing: {DEB}")
    members = ar_members(DEB.read_bytes())
    payload = payload_bytes(members)
    with tarfile.open(fileobj=io.BytesIO(payload)) as archive:
        payload_names = {item.name.lstrip("./") for item in archive.getmembers()}
        for name in (
            "Library/MobileSubstrate/DynamicLibraries/PodsGrantAACPDiag.dylib",
            "Library/MobileSubstrate/DynamicLibraries/"
            "PodsGrantAACPDiagHelper.dylib",
            "usr/bin/aacpdiagd",
        ):
            normalized = name.lstrip("./")
            if normalized not in payload_names:
                raise ValueError(f"payload is missing {normalized}")
            member = archive.getmember(normalized)
            extracted = archive.extractfile(member)
            if extracted is None:
                raise ValueError(f"cannot read {normalized}")
            verify_macho(normalized, extracted.read())
    print(f"verified={DEB}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
