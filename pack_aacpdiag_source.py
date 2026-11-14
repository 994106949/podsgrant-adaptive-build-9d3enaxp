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
        "aacpdiag/shared/AACPDiagNative.m",
        "aacpdiag/shared/AACPDiagRuntimeHooks.m",
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

    missing = sorted(required - names)
    if missing:
        raise SystemExit(f"packed archive is missing files: {missing}")
    if version != ["Version: 0.5.7~adts3diag3"]:
        raise SystemExit(f"unexpected packed version: {version}")

    print(f"archive={ARCHIVE}")
    print(f"files={len(files)}")
    print(f"version={version[0]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
