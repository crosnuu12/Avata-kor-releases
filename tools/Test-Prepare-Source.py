#!/usr/bin/env python3
"""Offline extraction regressions using synthetic source and no account data."""
import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("prepare_source", Path(__file__).with_name("Prepare-Source.py"))
prepare_source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare_source)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


class PrepareSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / "repo"
        self.repo.mkdir()
        self.destination = self.base / "working"
        self.index_path = self.repo / "CURRENT_SOURCE.json"
        self.archive = self.repo / "releases/1.1.6/assets/Avata_58.17.12_Verification.zip"
        self.archive.parent.mkdir(parents=True)
        self.files = {name: ("# Synthetic fixture: " + name + "\n").encode() for name in prepare_source.REQUIRED if name != "bundle/release.json"}
        self.files["tests/Fixture.ps1"] = b"# Historical fixture\n"
        self.files["recovery/Repair.ps1"] = b"# Recovery fixture\n"
        self.files["Test-Synthetic.ps1"] = b"# Test fixture\n"
        self.manifest = {
            "Schema": "AT58-BUNDLE-1", "HostProtocol": 2, "Mode": "CONTROLLED_LIVE",
            "Version": "58.17.12", "Id": "bundle-" + "a" * 24,
            "Files": [
                {"Name": name.removeprefix("bundle/"), "Size": len(raw), "Hash": sha(raw)}
                for name, raw in sorted(self.files.items()) if name.startswith("bundle/")
            ],
        }
        self.files["bundle/release.json"] = json.dumps(self.manifest).encode()
        self.index = {
            "Schema": "AVATA-CURRENT-SOURCE-1", "ProductVersion": "1.1.6",
            "BundleVersion": "58.17.12", "BundleId": self.manifest["Id"],
            "Archive": self.archive.relative_to(self.repo).as_posix(),
            "ManifestSha256": sha(self.files["bundle/release.json"]),
        }
        self.pack()

    def pack(self, extras=()):
        with zipfile.ZipFile(self.archive, "w", zipfile.ZIP_DEFLATED) as archive:
            for name, raw in sorted(self.files.items()):
                archive.writestr(name, raw)
            for name, raw in extras:
                archive.writestr(name, raw)
        self.index["ArchiveSha256"] = sha(self.archive.read_bytes())
        self.write_index()

    def write_index(self):
        self.index_path.write_text(json.dumps(self.index), encoding="utf-8")

    def rejected(self, match):
        with self.assertRaisesRegex(prepare_source.SourceError, match):
            prepare_source.prepare(self.index_path, self.destination)
        self.assertFalse(self.destination.exists())

    def test_success_restores_full_source(self):
        archive_before = self.archive.read_bytes()
        result = prepare_source.prepare(self.index_path, self.destination)
        self.assertEqual(result["BundleVersion"], "58.17.12")
        self.assertEqual(result["Files"], len(self.files))
        actual = {p.relative_to(self.destination).as_posix(): p.read_bytes() for p in self.destination.rglob("*") if p.is_file()}
        self.assertEqual(actual, self.files)
        self.assertEqual(self.archive.read_bytes(), archive_before)

    def test_archive_hash_mismatch_creates_nothing(self):
        self.index["ArchiveSha256"] = "0" * 64
        self.write_index()
        self.rejected("Archive SHA256 mismatch")

    def test_traversal_creates_nothing(self):
        self.pack([("tests/../../escape.ps1", b"escape")])
        self.rejected("Unsafe archive path")
        self.assertFalse((self.base / "escape.ps1").exists())
        self.assertFalse((self.repo / "escape.ps1").exists())

    def test_archive_symlink_rejected(self):
        link = zipfile.ZipInfo("tests/link.ps1")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        self.pack([(link, b"../../outside.ps1")])
        self.rejected("links or non-regular")

    def test_existing_destination_is_unchanged(self):
        self.destination.mkdir()
        sentinel = self.destination / "keep.txt"
        sentinel.write_bytes(b"keep")
        with self.assertRaisesRegex(prepare_source.SourceError, "already exists"):
            prepare_source.prepare(self.index_path, self.destination)
        self.assertEqual(list(self.destination.iterdir()), [sentinel])
        self.assertEqual(sentinel.read_bytes(), b"keep")

    def test_destination_inside_repository_rejected(self):
        with self.assertRaisesRegex(prepare_source.SourceError, "outside the indexed repository"):
            prepare_source.prepare(self.index_path, self.repo / "working")
        self.assertFalse((self.repo / "working").exists())

    def test_manifest_and_runtime_hashes_are_checked(self):
        self.index["ManifestSha256"] = "0" * 64
        self.write_index()
        self.rejected("Manifest SHA256 mismatch")
        self.index["ManifestSha256"] = sha(self.files["bundle/release.json"])
        name = "bundle/At58.Manager.ps1"
        original = self.files[name]
        self.files[name] = bytes([original[0] ^ 1]) + original[1:]
        self.pack()
        self.rejected("Runtime file SHA256 mismatch")

    def test_case_alias_and_windows_names_rejected(self):
        self.pack([("tests/fixture.ps1", b"alias")])
        self.rejected("Duplicate archive path")
        self.pack([("tests/CON.ps1", b"reserved")])
        self.rejected("Reserved Windows filename")
        self.pack([("tests/bad?.ps1", b"invalid")])
        self.rejected("Unsafe Windows filename")

    def test_incomplete_full_source_is_rejected(self):
        del self.files["host/At58.Host.ps1"]
        self.pack()
        self.rejected("source layout is incomplete")

    def test_filesystem_symlink_is_rejected(self):
        alias = self.base / "alias"
        try:
            alias.symlink_to(self.repo, target_is_directory=True)
        except (OSError, NotImplementedError):
            self.skipTest("Filesystem symlink creation is unavailable")
        with self.assertRaisesRegex(prepare_source.SourceError, "Symbolic links|Reparse points"):
            prepare_source.prepare(alias / "CURRENT_SOURCE.json", self.destination)
        self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
