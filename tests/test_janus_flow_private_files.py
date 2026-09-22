"""Non-secret fixtures for the exact publisher used by Nix activation."""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HELPER = Path(__file__).resolve().parents[1] / "modules/janus-flow-host/private_files.py"
SPEC = importlib.util.spec_from_file_location("private_files", HELPER)
FILES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FILES)


class PrivateFilesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="janus-synthetic-")
        self.root = Path(self.temp.name)
        self.uid, self.gid = os.geteuid(), os.getegid()
        self.source = self.root / "synthetic-source"
        self.destination = self.root / "runtime" / "api-key"
        self.write_source(b"A" * 64)

    def tearDown(self):
        self.temp.cleanup()

    def write_source(self, data):
        temporary = self.root / "synthetic-next"
        temporary.write_bytes(data)
        os.chown(temporary, self.uid, self.gid)
        temporary.chmod(0o400)
        os.replace(temporary, self.source)

    def publish(self):
        return FILES.credential(self.source, self.destination, self.uid, self.gid)

    def test_same_bytes_keep_mounted_inode_across_source_replacement(self):
        self.assertTrue(self.publish())
        inode = self.destination.stat().st_ino
        with self.destination.open("rb") as mounted:
            self.write_source(b"A" * 64)
            self.assertFalse(self.publish())
            self.assertEqual(self.destination.stat().st_ino, inode)
            self.assertEqual(os.fstat(mounted.fileno()).st_nlink, 1)

    def test_rotation_is_atomic_and_old_mount_needs_recreation(self):
        self.publish()
        with self.destination.open("rb") as mounted:
            self.write_source(b"B" * 64)
            self.assertTrue(self.publish())
            self.assertEqual(os.fstat(mounted.fileno()).st_nlink, 0)
            self.assertEqual(mounted.read(), b"A" * 64)
            self.assertEqual(self.destination.read_bytes(), b"B" * 64)
        self.assertEqual(self.destination.stat().st_nlink, 1)
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o400)
        self.assertEqual(self.destination.parent.stat().st_mode & 0o777, 0o700)

    def test_placeholder_is_empty_private_and_stable(self):
        FILES.placeholder(self.destination, self.uid, self.gid)
        before = self.destination.stat()
        FILES.placeholder(self.destination, self.uid, self.gid)
        after = self.destination.stat()
        self.assertEqual(before.st_ino, after.st_ino)
        self.assertEqual((after.st_size, after.st_nlink, after.st_mode & 0o777), (0, 1, 0o400))
        with self.assertRaises(ValueError):
            FILES.checked_file(self.destination, self.uid, self.gid)

    def test_first_boot_creates_missing_private_ancestors(self):
        target = self.root / "new-run-janus" / "flow-host" / "api-key"
        FILES.placeholder(target, self.uid, self.gid)
        self.assertEqual(target.parent.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(target.stat().st_size, 0)

    def test_placeholder_does_not_truncate_unexpected_file(self):
        self.publish()
        with self.assertRaises(ValueError):
            FILES.placeholder(self.destination, self.uid, self.gid)
        self.assertEqual(self.destination.read_bytes(), b"A" * 64)

    def test_symlink_target_is_rejected(self):
        self.destination.parent.mkdir(mode=0o700)
        self.destination.symlink_to(self.source)
        with self.assertRaises(ValueError):
            self.publish()
        with self.assertRaises(ValueError):
            FILES.placeholder(self.destination, self.uid, self.gid)
        self.assertTrue(self.destination.is_symlink())

    def test_symlink_directory_is_rejected_without_changing_referent(self):
        target = self.root / "other"
        target.mkdir(mode=0o755)
        self.destination.parent.symlink_to(target)
        with self.assertRaises(ValueError):
            self.publish()
        self.assertEqual(target.stat().st_mode & 0o777, 0o755)

    def test_source_permissions_fail_before_runtime_creation(self):
        self.source.chmod(0o644)
        with self.assertRaises(ValueError):
            self.publish()
        self.assertFalse(self.destination.parent.exists())

    def test_hardlinks_are_rejected(self):
        self.publish()
        os.link(self.destination, self.root / "unexpected-link")
        self.write_source(b"B" * 64)
        with self.assertRaises(ValueError):
            self.publish()
        self.assertEqual(self.destination.read_bytes(), b"A" * 64)

    def test_private_metadata_is_not_silently_repaired(self):
        self.publish()
        self.destination.chmod(0o600)
        with self.assertRaises(ValueError):
            self.publish()
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o600)

    def test_invalid_source_never_replaces_current_key(self):
        self.publish()
        inode = self.destination.stat().st_ino
        for invalid in (b"", b"short", b"X" * 513, b"A" * 63 + b"\n", b"\0" * 64):
            with self.subTest(length=len(invalid)):
                self.write_source(invalid)
                with self.assertRaises(ValueError):
                    self.publish()
                self.assertEqual(self.destination.stat().st_ino, inode)
                self.assertEqual(self.destination.read_bytes(), b"A" * 64)

    def test_source_symlink_rejected(self):
        link = self.root / "linked-source"
        link.symlink_to(self.source)
        with self.assertRaises(ValueError):
            FILES.credential(link, self.destination, self.uid, self.gid)

    def test_cli_never_prints_fixture_bytes_on_refusal(self):
        result = subprocess.run(
            [sys.executable, str(HELPER), "credential", str(self.destination),
             "--source", str(self.root / "absent"), "--uid", str(self.uid), "--gid", str(self.gid)],
            capture_output=True, text=True, check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertNotIn("A" * 64, result.stderr)


if __name__ == "__main__":
    unittest.main()
