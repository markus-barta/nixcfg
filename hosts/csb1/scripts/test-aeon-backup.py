#!/usr/bin/env python3
"""AEON-73: exercise snapshot publication with fake Docker/PG, no host access."""

import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest


HOST = Path(__file__).resolve().parents[1]


class SnapshotTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="aeon-backup-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.snapshot = self.root / "aeon-postgres-backup-snapshot"
        self.snapshot.mkdir(mode=0o700)
        (self.snapshot / "aeon.dump").write_text("previous recovery point")
        (self.snapshot / "SNAPSHOT-CREATED-UTC").write_text("previous timestamp")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.helper("docker", """
case "$1" in
  inspect)
    case "$3" in
      *Health*) echo "${TEST_HEALTH:-healthy}" ;;
      *) echo "${TEST_RUNNING:-true}" ;;
    esac ;;
  exec)
    [ "$*" = 'exec --user postgres aeon-db pg_dump -U postgres -d aeon -Fc' ] || exit 90
    [ "${TEST_DUMP:-ok}" != empty ] || exit 0
    echo 'new recovery point'
    [ "${TEST_DUMP:-ok}" != fail ] ;;
  *) exit 91 ;;
esac
""")
        self.helper("pg_restore", """
[ "$1" = --list ] && [ -s "$2" ] || exit 92
[ "${TEST_RESTORE:-ok}" != fail ]
""")
        # macOS sync does not accept a path. This harness tests control flow,
        # rotation and permissions, not Linux fsync or PostgreSQL itself.
        self.helper("sync", "exit 0")
        for name in ("install", "date", "mv"):
            (self.bin / name).symlink_to(shutil.which(name))
        # Restrict fixture cleanup to the two disposable rotation directories.
        cleanup = self.root / "cleanup.py"
        cleanup.write_text(
            "import pathlib, shutil, sys\n"
            f"root = pathlib.Path({str(self.root)!r})\n"
            "target = pathlib.Path(sys.argv[2])\n"
            "assert sys.argv[1] == '-rf' and target.parent == root\n"
            "assert target.name in ('.aeon-postgres-backup-snapshot.staging', "
            "'.aeon-postgres-backup-snapshot.previous')\n"
            "if target.exists(): shutil.rmtree(target)\n"
        )
        self.helper("rm", f"exec python3 {shlex.quote(str(cleanup))} \"$@\"")
        source = (HOST / "configuration.nix").read_text()
        script = re.search(
            r'aeonPostgresBackupSnapshot = pkgs.writeShellScript "[^"]+" \'\'(.*?)\n  \'\';',
            source, re.S,
        ).group(1)
        script = re.sub(r"\$\{pkgs\.(?:docker|coreutils|postgresql_18)\}/bin", str(self.bin), script)
        script = script.replace("/var/lib/csb1-docker", str(self.root))
        self.script = self.root / "snapshot.sh"
        self.script.write_text(script)

    def helper(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
        path.chmod(0o755)

    def run_snapshot(self, **settings):
        return subprocess.run(
            ["sh", str(self.script)], capture_output=True, text=True,
            env={**os.environ, **settings},
        )

    def test_failures_preserve_published_dump_and_timestamp(self):
        for settings in (
            {"TEST_RUNNING": "false"}, {"TEST_HEALTH": "unhealthy"},
            {"TEST_HEALTH": "none"}, {"TEST_DUMP": "fail"},
            {"TEST_DUMP": "empty"}, {"TEST_RESTORE": "fail"},
        ):
            with self.subTest(settings=settings):
                self.assertNotEqual(self.run_snapshot(**settings).returncode, 0)
                self.assertEqual((self.snapshot / "aeon.dump").read_text(), "previous recovery point")
                self.assertEqual((self.snapshot / "SNAPSHOT-CREATED-UTC").read_text(), "previous timestamp")

    def test_success_replaces_old_snapshot_and_stale_staging(self):
        staging = self.root / ".aeon-postgres-backup-snapshot.staging"
        staging.mkdir()
        (staging / "stale.dump").write_text("stale")
        result = self.run_snapshot()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.snapshot / "aeon.dump").read_text(), "new recovery point\n")
        self.assertRegex((self.snapshot / "SNAPSHOT-CREATED-UTC").read_text(), r"^\d{4}-.*Z\n$")
        self.assertEqual(self.snapshot.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.snapshot / "aeon.dump").stat().st_mode & 0o777, 0o600)
        self.assertFalse((self.snapshot / "stale.dump").exists())
        self.assertFalse(staging.exists())
        self.assertFalse((self.root / ".aeon-postgres-backup-snapshot.previous").exists())


if __name__ == "__main__":
    unittest.main()
