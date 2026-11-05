#!/usr/bin/env python3
"""Prepare an exclusive working copy from the repository's pinned verification ZIP.

This command is offline. It checks the trusted repository index's archive hash,
manifest hash and each runtime file. The release updater owns signature checking.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import zipfile

MAX_ARCHIVE = 32 * 1024 * 1024
MAX_UNPACKED = 64 * 1024 * 1024
MAX_ENTRIES = 2048
ROOT_FILES = {"Package-Candidate.py", "README.md", "README_KO.md", "Run-Checks.ps1", "VALIDATION_STATUS.json"}
SOURCE_DIRS = {"bundle", "host", "recovery", "tests"}
SUFFIXES = {".ps1", ".json", ".md", ".txt", ".py"}
REQUIRED = ROOT_FILES | {
    "bundle/release.json", "bundle/At58.Manager.ps1", "bundle/At58.Ops.ps1",
    "bundle/At58.Sheets.ps1", "bundle/At58.SheetWorker.ps1", "bundle/At58.Telegram.ps1",
    "bundle/payload/At58.Core.ps1", "bundle/payload/esbada_Merits_AT_v58.ps1",
    "host/At58.Host.ps1", "host/At58.Update.ps1", "host/At58.Ops.ps1",
}


class SourceError(ValueError):
    pass


def require(ok: bool, message: str) -> None:
    if not ok:
        raise SourceError(message)


def digest(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def relative_name(name: str) -> PurePosixPath:
    require(isinstance(name, str) and bool(name), "Empty archive path")
    require("\\" not in name and ":" not in name and "\x00" not in name, "Unsafe archive path")
    require(not name.startswith("/") and not name.endswith("/"), "Unsafe archive path")
    parts = name.split("/")
    require(all(p not in {"", ".", ".."} for p in parts), "Unsafe archive path")
    # Also reject Windows aliases, alternate streams and reserved device names.
    for part in parts:
        require(not part.endswith((" ", ".")) and not any(ord(c) < 32 or c in '<>:"|?*\\' for c in part), "Unsafe Windows filename")
        require(not re.fullmatch(r"(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?", part), "Reserved Windows filename")
    return PurePosixPath(*parts)


def no_links(path: Path) -> None:
    for part in (path, *path.parents):
        if part.exists() or part.is_symlink():
            info = part.lstat()
            require(not stat.S_ISLNK(info.st_mode), "Symbolic links are not accepted")
            require(not (getattr(info, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0)), "Reparse points are not accepted")


def descendant(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def checked_sha(value: object) -> str:
    require(isinstance(value, str) and re.fullmatch(r"[a-f0-9]{64}", value) is not None, "Index hash is missing or invalid")
    return value


def prepare(index_path: Path, destination: Path) -> dict:
    index_path = Path(os.path.abspath(index_path))
    destination = Path(os.path.abspath(destination))
    no_links(index_path)
    no_links(destination)
    require(index_path.is_file(), "Source index is missing")
    repository = index_path.parent
    require(not descendant(destination, repository), "Destination must be outside the indexed repository")
    require(not destination.exists() and not destination.is_symlink(), "Destination already exists; no files were overwritten")
    require(destination.parent.is_dir(), "Create the destination parent directory first")
    index = json.loads(index_path.read_text(encoding="utf-8-sig"))
    require(isinstance(index, dict), "Source index must be an object")
    require(index.get("Schema") == "AVATA-CURRENT-SOURCE-1", "Unsupported source index")
    version = index.get("BundleVersion", "")
    require(re.fullmatch(r"58\.[0-9]{1,4}\.[0-9]{1,4}", version) is not None, "Invalid bundle version")
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", index.get("ProductVersion", "")) is not None, "Invalid product version")
    archive_path = repository.joinpath(*relative_name(index.get("Archive", "")).parts)
    no_links(archive_path)
    require(archive_path.is_file() and archive_path.stat().st_size <= MAX_ARCHIVE, "Archive missing or too large")
    raw = archive_path.read_bytes()
    require(digest(raw) == checked_sha(index.get("ArchiveSha256")), "Archive SHA256 mismatch")
    require(re.fullmatch(r"bundle-[a-f0-9]{24}", index.get("BundleId", "")) is not None, "Invalid bundle ID")

    # Verify all entries before creating the destination, including case-folded
    # aliases and file/directory collisions that behave differently on Windows.
    import io
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        entries = archive.infolist()
        require(0 < len(entries) <= MAX_ENTRIES, "Archive entry count is invalid")
        require(sum(i.file_size for i in entries) <= MAX_UNPACKED, "Archive expands beyond the supported size")
        names: dict[str, str] = {}
        contents: dict[str, bytes] = {}
        for entry in entries:
            path = relative_name(entry.filename)
            mode = entry.external_attr >> 16
            require(not entry.is_dir() and stat.S_IFMT(mode) in (0, stat.S_IFREG), "Archive links or non-regular entries are not accepted")
            require(not (entry.flag_bits & 1), "Encrypted archives are not accepted")
            require(entry.file_size <= MAX_UNPACKED, "Archive entry too large")
            folded = entry.filename.casefold()
            require(folded not in names, "Duplicate archive path")
            names[folded] = entry.filename
            if len(path.parts) == 1:
                require(entry.filename in ROOT_FILES or re.fullmatch(r"Test-[A-Za-z0-9_-]+\.ps1", entry.filename) is not None, "Unexpected archive root file")
            else:
                require(path.parts[0] in SOURCE_DIRS, "Unexpected source directory")
            require(path.suffix.lower() in SUFFIXES, "Unexpected source file type")
            contents[entry.filename] = archive.read(entry)  # Also verifies CRC.
        for name in names:
            parts = name.split("/")
            require(not any("/".join(parts[:i]) in names for i in range(1, len(parts))), "Archive path collision")
        require(REQUIRED.issubset(contents), "Verification source layout is incomplete")
        require(any(n.startswith("tests/") for n in contents) and any(n.startswith("recovery/") for n in contents), "Verification fixtures or recovery source missing")
        manifest_raw = contents["bundle/release.json"]
        require(digest(manifest_raw) == checked_sha(index.get("ManifestSha256")), "Manifest SHA256 mismatch")
        manifest = json.loads(manifest_raw)
        require(isinstance(manifest, dict), "Bundle manifest must be an object")
        require(manifest.get("Schema") == "AT58-BUNDLE-1" and manifest.get("HostProtocol") == 2 and manifest.get("Mode") == "CONTROLLED_LIVE", "Unsupported bundle manifest")
        require(manifest.get("Version") == version and manifest.get("Id") == index["BundleId"], "Manifest identity mismatch")
        manifest_names = set()
        records = manifest.get("Files")
        require(isinstance(records, list) and bool(records), "Manifest files missing")
        for record in records:
            require(isinstance(record, dict), "Manifest file record must be an object")
            name = str(relative_name(record.get("Name", "")))
            require(name not in manifest_names, "Duplicate manifest file")
            manifest_names.add(name)
            stored = contents.get("bundle/" + name)
            require(stored is not None and isinstance(record.get("Size"), int) and not isinstance(record.get("Size"), bool) and len(stored) == record["Size"], "Manifest file missing or size mismatch")
            require(digest(stored) == checked_sha(record.get("Hash")), "Runtime file SHA256 mismatch")
        expected = {"bundle/release.json"} | {"bundle/" + n for n in manifest_names}
        require({n for n in contents if n.startswith("bundle/")} == expected, "Unlisted runtime file in source archive")

    # mkdir(exist_ok=False) is the final exclusive claim. Do not remove a
    # destination on failure: retain any partial output for explicit inspection.
    destination.mkdir(mode=0o700)
    for name, content in contents.items():
        target = destination.joinpath(*PurePosixPath(name).parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        no_links(target.parent)
        with target.open("xb") as stream:
            stream.write(content)
    return {"ProductVersion": index["ProductVersion"], "BundleVersion": version, "Files": len(contents), "Destination": str(destination), "ArchiveSha256": digest(raw)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", type=Path, default=Path(__file__).resolve().parents[1] / "CURRENT_SOURCE.json")
    parser.add_argument("--dest", type=Path, required=True, help="New directory outside the indexed repository; its parent must exist")
    args = parser.parse_args()
    try:
        result = prepare(args.index, args.dest)
    except (SourceError, OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as error:
        print("SOURCE_PREPARE_FAILED: " + str(error), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
