"""OPS-158: real local Git + Gitleaks against synthetic service directories."""

import contextlib
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "hosts/hsb1/home-config-snapshot.py"
SCANNER_CONFIG = REPO / "hosts/hsb1/home-config-gitleaks.toml"
GITLEAKS = shutil.which("gitleaks")
GIT = shutil.which("git")
spec = importlib.util.spec_from_file_location("home_config", SCRIPT)
implementation = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = implementation
spec.loader.exec_module(implementation)


def put(root, name, content):
    target = root / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content)


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(GITLEAKS, "Gitleaks is required; no mock scanner substitutes for the secret gate")
        self.temporary = tempfile.TemporaryDirectory(prefix="ops158-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / "history"
        self.repo.mkdir(mode=0o750)
        self.runtime = self.root / "runtime"
        self.runtime.mkdir(mode=0o700)
        self.nr = self.root / "nodered"
        self.ha = self.root / "homeassistant"
        self.setting_value = "fixture-" + "credential-" + "fortytwo"
        self.planted_value = "fixture" + "Q7tX4aK2vR9pL6zN8bC5wH3sJ1dF0yE"
        put(self.nr, "flows.json", '[{"id":"tab","type":"tab","label":"fixture"}]\n')
        put(self.nr, "settings.js", '// settings fixture\nmodule.exports = {\n    credentialSecret: "' + self.setting_value + '",\n    flowFile: "flows.json",\n};\n')
        put(self.nr, "package.json", '{"name":"fixture","dependencies":{"node-red-node-test":"1.0.0"}}\n')
        for name in ("configuration", "automations", "scripts", "scenes", "customize"):
            put(self.ha, name + ".yaml", "# fixture\n{}\n")
        put(self.ha, "themes/sample.yaml", "sample: {}\n")
        put(self.ha, "blueprints/automation/sample.yaml", "blueprint: {}\n")
        put(self.ha, "packages/sample.yaml", "input_boolean: {}\n")
        for name in ("core.area_registry", "core.floor_registry", "core.device_registry", "core.entity_registry", "core.label_registry",
                     "lovelace", "lovelace.dashboard_main", "lovelace.map", "lovelace_resources", "lovelace_dashboards"):
            put(self.ha, ".storage/" + name, '{"data":{}}\n')
        self.expected = {"nodered/" + name for name in ("flows.json", "settings.js", "package.json")}
        self.expected.update("homeassistant/" + str(path.relative_to(self.ha)) for path in self.ha.rglob("*") if path.is_file())
        for name in ("flows_cred.json", ".flows_cred.json", "flows.json.bak", "flows.json.bak-old", ".config.users.json", "context/state.json", "unknown.json"):
            put(self.nr, name, "{}\n")
        for name in ("secrets.yaml", ".storage/auth", ".storage/auth_provider.homeassistant", ".storage/core.config_entries", ".storage/onboarding",
                     ".storage/core.category_registry", ".storage/lovelace.dashboard_main.bak.20260101", ".storage/lovelace.dashboard_main.bak",
                     ".storage/lovelace.bak", ".storage/lovelace.bak-20260101", ".storage/lovelace.BAK",
                     ".storage/lovelace_backup", "home-assistant_v2.db", "home-assistant.log", ".cloud/data", "tts/voice.mp3",
                     "configuration.yaml.bak", "!archiv/automation.yaml", "themes/!archiv/old.yaml", "themes/sample.bak.yaml", "blueprints/test.yaml.bak",
                     "packages/.hidden.yaml", "unknown.yaml", "themes/README.txt"):
            put(self.ha, name, "{}\n")

    def run_snapshot(self, *, ok=True, git=None, gitleaks=None, verify_only=False):
        configuration = implementation.Settings(repo=self.repo, runtime=self.runtime, nodered=self.nr,
                                                homeassistant=self.ha, git=git or GIT, gitleaks=gitleaks or GITLEAKS,
                                                scanner_config=SCANNER_CONFIG)
        output = io.StringIO()
        previous_mask = os.umask(0o027)
        try:
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                result = implementation.run(configuration, verify_only=verify_only, debounce_seconds=0)
        finally:
            os.umask(previous_mask)
        self.assertEqual(result, 0 if ok else 1, output.getvalue())
        self.assertNotIn(self.setting_value, output.getvalue())
        self.assertNotIn(self.planted_value, output.getvalue())
        return output.getvalue()

    def git(self, *arguments, check=True):
        result = subprocess.run([GIT, "-C", str(self.repo), *arguments], capture_output=True,
                                env=implementation.private_environment(self.runtime), timeout=10)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr.decode())
        return result.stdout

    def head(self):
        return self.git("rev-parse", "--verify", "HEAD", check=False)

    def tree(self):
        return set(filter(None, self.git("ls-tree", "-rz", "--name-only", "HEAD").decode().split("\0")))

    def source_state(self):
        return {str(path.relative_to(self.root)): (path.stat().st_mode, path.read_bytes())
                for root in (self.nr, self.ha) for path in root.rglob("*") if path.is_file()}

    def test_allowlist_redaction_author_and_read_only_sources(self):
        before = self.source_state()
        self.run_snapshot()
        self.assertEqual(self.tree(), self.expected)
        filtered = self.git("show", "HEAD:nodered/settings.js").decode()
        self.assertIn('credentialSecret: "[REDACTED]"', filtered)
        self.assertNotIn(self.setting_value, filtered)
        # Search every object, including unreachable blobs: the real credential never entered Git.
        objects = self.git("cat-file", "--batch-all-objects", "--batch")
        self.assertNotIn(self.setting_value.encode(), objects)
        self.assertEqual(self.git("log", "-1", "--format=%an <%ae>|%cn <%ce>").decode().strip(),
                         "hsb1-home-config <root@hsb1>|hsb1-home-config <root@hsb1>")
        message = self.git("log", "-1", "--format=%B").decode()
        self.assertIn("snapshot homeassistant,nodered:", message)
        for name in self.expected:
            self.assertIn(name, message)
        self.assertEqual(self.source_state(), before)
        self.assertFalse(self.git("remote"))
        for path in self.repo.rglob("*"):
            self.assertFalse(path.stat().st_mode & 0o007, str(path))
            if path.is_file():
                self.assertTrue(path.stat().st_mode & 0o040, str(path))

    def test_no_commit_when_unchanged_and_single_source_message(self):
        self.run_snapshot()
        first = self.head()
        self.assertIn("unchanged; no commit", self.run_snapshot())
        self.assertEqual(self.head(), first)
        put(self.ha, "automations.yaml", "# changed fixture\n[]\n")
        self.run_snapshot()
        self.assertNotEqual(self.head(), first)
        self.assertEqual(self.git("rev-list", "--count", "HEAD").strip(), b"2")
        self.assertEqual(self.git("log", "-1", "--format=%B").decode().strip(),
                         "snapshot homeassistant: homeassistant/automations.yaml")

    def test_planted_secret_aborts_before_any_git_blob_or_source_write(self):
        self.run_snapshot()
        first = self.head()
        put(self.ha, "automations.yaml", 'api_key: "' + self.planted_value + '" # gitleaks:allow\n')
        before = self.source_state()
        output = self.run_snapshot(ok=False)
        self.assertRegex(output, r"rule=[a-z0-9-]+ file=homeassistant/automations.yaml line=1")
        self.assertEqual(self.head(), first)
        self.assertNotIn(self.planted_value.encode(), self.git("cat-file", "--batch-all-objects", "--batch"))
        self.assertFalse(self.git("status", "--porcelain"))
        self.assertEqual(self.source_state(), before)

    def test_remote_guard_also_runs_when_sources_unchanged(self):
        self.run_snapshot()
        first = self.head()
        self.git("remote", "add", "forbidden", "https://example.invalid/never-contacted")
        self.assertIn("remote configured", self.run_snapshot(ok=False))
        put(self.ha, "scripts.yaml", "# changed\n[]\n")
        self.run_snapshot(ok=False)
        self.assertEqual(self.head(), first)

    def test_large_flows_and_hidden_registry_are_scanned(self):
        for root, name in ((self.nr, "flows.json"), (self.ha, ".storage/core.device_registry")):
            with self.subTest(name=name):
                previous = (root / name).read_text()
                # Larger than the live 4.2 MB flows file: no scanner size skip.
                content = {"padding": " " * 4_300_000, "api_key": self.planted_value}
                put(root, name, json.dumps(content))
                output = self.run_snapshot(ok=False)
                self.assertIn("file=" + ("nodered/" if root == self.nr else "homeassistant/") + name, output)
                self.assertFalse(self.head())
                put(root, name, previous)

    def test_candidate_and_exact_index_export_are_both_scanned(self):
        wrapper = self.root / "scanner-wrapper"
        record = self.root / "scanner-targets"
        wrapper.write_text("#!" + sys.executable + "\nimport os, sys\n"
                           + "with open(" + repr(str(record)) + ", 'a') as log:\n    log.write(sys.argv[2] + '\\n')\n"
                           + "os.execv(" + repr(GITLEAKS) + ", [" + repr(GITLEAKS) + "] + sys.argv[1:])\n")
        wrapper.chmod(0o700)
        self.run_snapshot(gitleaks=str(wrapper))
        targets = [Path(name) for name in record.read_text().splitlines()]
        self.assertEqual(len(targets), 2)
        self.assertTrue(targets[0].name.startswith("snapshot-"))
        self.assertTrue(targets[1].name.startswith("index-"))

    def test_optional_deletion_is_versioned_required_absence_fails_closed(self):
        self.run_snapshot()
        (self.ha / "scripts.yaml").unlink()
        self.run_snapshot()
        self.assertNotIn("homeassistant/scripts.yaml", self.tree())
        first = self.head()
        (self.nr / "flows.json").unlink()
        self.assertIn("required source file missing", self.run_snapshot(ok=False))
        self.assertEqual(self.head(), first)

    def test_symlinks_and_hardlinks_fail_without_reading_their_target(self):
        for kind in ("symlink", "hardlink"):
            with self.subTest(kind=kind):
                selected = self.ha / "automations.yaml"
                selected.unlink()
                target = self.root / "outside-file"
                target.write_text(self.planted_value)
                if kind == "symlink":
                    selected.symlink_to(target)
                else:
                    os.link(target, selected)
                self.run_snapshot(ok=False)
                self.assertFalse(self.head())
                selected.unlink()
                selected.write_text("[]\n")

    def test_unknown_files_are_not_even_opened(self):
        forbidden = self.nr / "unknown.json"
        forbidden.unlink()
        forbidden.symlink_to(self.root / "does-not-exist")
        self.run_snapshot()
        self.assertEqual(self.tree(), self.expected)

    def test_pending_operator_work_is_preserved(self):
        self.run_snapshot()
        first = self.head()
        put(self.repo, "operator-note.txt", "leave this alone\n")
        self.assertIn("pending changes", self.run_snapshot(ok=False))
        self.assertEqual((self.repo / "operator-note.txt").read_text(), "leave this alone\n")
        self.assertEqual(self.head(), first)

    def test_tracked_unknown_path_is_rejected(self):
        self.run_snapshot()
        put(self.repo, "unknown.txt", "fixture\n")
        self.git("add", "unknown.txt")
        self.git("commit", "-m", "fixture operator change")
        first = self.head()
        self.assertIn("non-allowlisted", self.run_snapshot(ok=False))
        self.assertEqual(self.head(), first)

    def test_scanner_failure_never_echoes_output(self):
        scanner = self.root / "broken-scanner"
        scanner.write_text("#!/bin/sh\nprintf '%s\\n' '" + self.planted_value + "' >&2\nexit 2\n")
        scanner.chmod(0o700)
        self.assertIn("secret scanner failed", self.run_snapshot(gitleaks=str(scanner), ok=False))
        self.assertFalse(self.head())

    def test_exact_staged_tree_cannot_differ_from_scanned_candidate(self):
        # Simulate a Git filter/index writer changing the staged bytes after pre-scan.
        wrapper = self.root / "git-wrapper"
        wrapper.write_text("#!" + sys.executable + "\nimport os, subprocess, sys\n"
                           + "command = [" + repr(GIT) + "] + sys.argv[1:]\n"
                           + "result = subprocess.run(command)\n"
                           + "if 'add' in sys.argv and result.returncode == 0:\n"
                           + "    from pathlib import Path\n"
                           + "    target = Path(" + repr(str(self.repo / "homeassistant/automations.yaml")) + ")\n"
                           + "    target.write_text(" + repr('api_key: "' + self.planted_value + '"\n') + ")\n"
                           + "    subprocess.run([" + repr(GIT) + ", '-C', " + repr(str(self.repo)) + ", 'add', '--', str(target)], check=True)\n"
                           + "sys.exit(result.returncode)\n")
        wrapper.chmod(0o700)
        self.assertIn("staged tree differs", self.run_snapshot(git=str(wrapper), ok=False))
        self.assertFalse(self.head())

    def test_verify_only_scans_head_and_hash_checks_live_credential(self):
        self.run_snapshot()
        first = self.head()
        before = self.source_state()
        self.assertIn("verified HEAD", self.run_snapshot(verify_only=True))
        self.assertEqual(self.head(), first)
        self.assertEqual(self.source_state(), before)

    def test_burst_waits_for_one_quiet_interval_and_uses_latest_bytes(self):
        changes = ["# first burst\n[]\n", "# second burst\n[]\n"]
        sleeps = []

        def change_during_wait(seconds):
            sleeps.append(seconds)
            if changes:
                put(self.ha, "automations.yaml", changes.pop(0))

        with mock.patch.object(implementation.time, "sleep", side_effect=change_during_wait):
            contents, _ = implementation.candidate({"nodered": self.nr, "homeassistant": self.ha}, 20)
        self.assertEqual(sleeps, [20, 20, 20])
        self.assertEqual(contents["homeassistant/automations.yaml"], b"# second burst\n[]\n")

    def test_invalid_json_is_not_committed(self):
        put(self.nr, "flows.json", '[{"incomplete":')
        self.assertIn("invalid JSON in nodered/flows.json", self.run_snapshot(ok=False))
        self.assertFalse(self.head())

    def test_lock_serializes_timer_path_and_manual_runs(self):
        with (self.runtime / "snapshot.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertIn("already running", self.run_snapshot())
            self.assertIn("verification busy", self.run_snapshot(verify_only=True, ok=False))
            self.assertFalse((self.repo / ".git").exists())


class SettingsTests(unittest.TestCase):
    def test_literal_quoting_escapes_and_comments(self):
        for literal in ('"fixture-credential-long"', "'fixture-credential-long'", r'"fixture\x2dcredential\u002dlong"'):
            with self.subTest(literal=literal):
                content = ('// credentialSecret: "comment",\nmodule.exports = {\n"credentialSecret": '
                           + literal + ', // retained comment\n};\n').encode()
                filtered, guard = implementation.redact_settings(content)
                self.assertIn(b'"credentialSecret": "[REDACTED]"', filtered)
                implementation.check_settings(filtered, guard)

    def test_unknown_expression_duplicate_and_absence_fail_closed(self):
        for declaration in ('credentialSecret: process.env.SECRET,', 'credentialSecret: `template`,',
                            'credentialSecret: "first-string", credentialSecret: "second-string",', 'flowFile: "flows.json",'):
            with self.subTest(declaration=declaration), self.assertRaises(implementation.Refused):
                implementation.redact_settings(('module.exports = {' + declaration + '};').encode())

    def test_hash_gate_detects_other_copy_and_escaped_source_spelling(self):
        for value in ('"fixture-credential-long"', r'"fixture\x2dcredential-long"'):
            with self.subTest(value=value), self.assertRaises(implementation.Refused):
                implementation.redact_settings(('module.exports = {credentialSecret: ' + value + ', another: ' + value + '};').encode())

    def test_hash_gate_also_decodes_differently_escaped_duplicate(self):
        with self.assertRaises(implementation.Refused):
            implementation.redact_settings(b'module.exports = {credentialSecret: "fixture-credential-long", another: "fixture\\x2dcredential-long"};')


def mutation_checks():
    source = (REPO / "hosts/hsb1/home-config-snapshot.py").read_text()
    mutations = {
        "drop-redaction": ('filtered = text[:literal.start()] + json.dumps(PLACEHOLDER) + text[literal.end():]', 'filtered = text'),
        "switch-to-blocklist": ('parts = PurePosixPath(name).parts\n    if len(parts) == 2:',
                                'return name not in {"nodered/flows_cred.json", "homeassistant/secrets.yaml"}\n    parts = PurePosixPath(name).parts\n    if len(parts) == 2:'),
        "drop-scanner": ('def scan_tree(args, tree):\n', 'def scan_tree(args, tree):\n    return\n'),
        "drop-remote-guard": ('if git(args, "remote").stdout.strip():', 'if False:'),
    }
    checks = ["SnapshotTests.test_allowlist_redaction_author_and_read_only_sources", "SnapshotTests.test_planted_secret_aborts_before_any_git_blob_or_source_write",
              "SnapshotTests.test_remote_guard_also_runs_when_sources_unchanged"]
    with tempfile.TemporaryDirectory(prefix="ops158-mutants-") as temporary:
        for name, (old, new) in mutations.items():
            if source.count(old) != 1:
                raise SystemExit("mutation did not apply exactly once: " + name)
            mutant_root = Path(temporary) / name
            mutant = mutant_root / "hosts/hsb1/home-config-snapshot.py"
            mutant.parent.mkdir(parents=True)
            mutated_source = source.replace(old, new, 1)
            compile(mutated_source, str(mutant), "exec")
            mutant.write_text(mutated_source)
            mutant_test = mutant_root / "tests/test_home_config.py"
            mutant_test.parent.mkdir()
            shutil.copyfile(__file__, mutant_test)
            shutil.copyfile(SCANNER_CONFIG, mutant.parent / SCANNER_CONFIG.name)
            result = subprocess.run([sys.executable, str(mutant_test), *checks], capture_output=True, timeout=60)
            if result.returncode == 0:
                raise SystemExit("must-fail mutant survived: " + name)
            if b"FAILED (" not in result.stderr:
                raise SystemExit("mutant failed outside the acceptance assertions: " + name)
            print("T121: must-fail mutant rejected: " + name, flush=True)


if __name__ == "__main__":
    if sys.argv[1:] == ["--mutants"]:
        mutation_checks()
    else:
        unittest.main(verbosity=2)
