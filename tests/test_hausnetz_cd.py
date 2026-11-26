"""Offline transactions and guard-removal mutants for OPS-705."""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


REPO = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get("HAUSNETZ_CD_SOURCE", REPO / "modules/hausnetz-cd"))
sys.path.insert(0, str(SOURCE))
from common import (Manual, EXECUTOR_BUDGET, POLL_BUDGET, POLL_INTERVAL, SSH_RETRY_TIMEOUT,
                    UNIT_RUNTIME_MAX, coordinate, gate_g1, gate_g2, gate_g4,
                    parse_export, prepare_result, strict_json)
from orchestrate import REMOTE, save_state, validate_result
from execute import execute as execute_transaction


class Fixture:
    def __init__(self, root):
        root = root.resolve()
        self.root = root
        self.env = dict(os.environ, CD_FIXTURE=str(root), PYTHONDONTWRITEBYTECODE="1")
        self.bin = root / "bin"
        self.bin.mkdir()
        self.env["PATH"] = str(self.bin) + os.pathsep + os.environ["PATH"]
        fake = REPO / "tests/fixtures/hausnetz-cd-command.py"
        # Use this test interpreter rather than relying on an executable bit
        # or a Python selected by the developer's global PATH.
        for command in ("nix", "nix-env", "systemctl", "systemd-run", "curl", "ssh", "sudo",
                        "paimos", "alarm", "secondary-telegram", "switch-to-configuration", "readlink"):
            target = self.bin / command
            target.write_text("#!" + sys.executable + "\n" + fake.read_text())
            target.chmod(0o700)
        self.scenario = {}
        (root / "scenario.json").write_text("{}")
        self.hnet = root / "hausnetz"
        self.init(self.hnet)
        self.write(self.hnet / "capabilities.json", '{"connections":[],"secrets":[],"writes":[]}\n')
        self.write(self.hnet / "app", "old\n")
        self.write(self.hnet / "nix/module.nix", "{}\n")
        self.write(self.hnet / "flake.nix", "{}\n")
        self.write(self.hnet / "flake.lock", "{}\n")
        self.old_hnet = self.commit(self.hnet)
        self.write(self.hnet / "app", "new\n")
        self.new_hnet = self.commit(self.hnet)
        self.repo = root / "nixcfg"
        self.init(self.repo)
        self.pin(self.old_hnet, 1)
        self.write(self.repo / "extra.nix", "initial fixture content\n")
        self.old = self.commit(self.repo)
        self.pin(self.new_hnet, 2)
        self.new = self.commit(self.repo)
        self.old_system = root / "store/old-system"
        self.new_system = root / "store/new-system"
        self.old_version = "261123075451.0.0"
        self.new_version = "261126120508.0.0"
        self.manifest_sha = hashlib.sha256((self.hnet / "capabilities.json").read_bytes()).hexdigest()
        self.executables = []
        for system, version in ((self.old_system, self.old_version), (self.new_system, self.new_version)):
            (system / "bin").mkdir(parents=True)
            (system / "bin/switch-to-configuration").symlink_to(self.bin / "switch-to-configuration")
            exe = root / "store" / ("a" * 32 + "-hausnetz-" + version) / "bin/hausnetz"
            self.write(exe, "fixture binary\n")
            self.executables.append(str(exe))
            self.write(system / "etc/systemd/system/hausnetz.service", '[Service]\nExecStart="' + str(exe) + '"\n')
        (root / "current-system").symlink_to(self.old_system)
        (root / "system-1-link").symlink_to(self.old_system)
        (root / "profile").symlink_to(root / "system-1-link")
        self.write(root / "evidence.json", json.dumps({
            "schema": "inspr.pharos.nix-deployment-evidence.v1", "source_revision": self.old}))
        self.credential = root / "fixture-credential"
        self.credential.write_text("123:fixture_token\n123\n")
        self.credential.chmod(0o600)
        self.executor = {
            "allow_live": True, "fixture_root": True, "state_dir": str(root / "remote-state"),
            "lock_file": str(root / "deploy.lock"), "evidence_file": str(root / "evidence.json"),
            "nixcfg_url": str(self.repo), "current_system": str(root / "current-system"),
            "system_profile": str(root / "profile"), "store_pattern": str(root / "store") + r"/[^/]+",
            "package_pattern": str(root / "store") + r"/[0-9a-z]{32}-hausnetz-([^/]+)/bin/hausnetz",
            "require_readyz": True, "health_timeout": 1.25,
            "backup_ack_timeout": 3, "telegram_file": str(self.credential),
        }
        self.orchestrator = {
            "enabled": True, "mode": "dry-run", "target": "mba@hsb0.lan",
            "release_ticket": "HNET-570", "nixcfg_url": str(self.repo), "hausnetz_url": str(self.hnet),
            "state_file": str(root / "local/state.json"), "fixture_root": True,
            "cache_dir": str(root / "cache"), "export_dir": str(root / "exports"),
            "alarm_file": str(root / "local/alarm.json"), "poll_timeout": 12, "poll_interval": 0.02,
            "ssh_retry_timeout": 0.4,
            "alarm_command": [str(self.bin / "alarm")],
            "secondary_telegram_command": [str(self.bin / "secondary-telegram")],
        }
        self.executor_path = root / "execute"
        template = (SOURCE / "execute.sh").read_text()
        self.executor_path.write_text(template.replace("@SOURCE@", shlex.quote(str(SOURCE)))
                                      .replace("@CONFIG@", shlex.quote(str(root / "execute.json"))))
        self.executor_path.chmod(0o700)
        self.orchestrator_path = root / "orchestrate"
        template = (REPO / "hosts/mbp2607/hausnetz-cd.sh").read_text()
        self.orchestrator_path.write_text(template.replace("@SOURCE@", shlex.quote(str(SOURCE)))
                                          .replace("@CONFIG@", shlex.quote(str(root / "orchestrate.json"))))
        self.orchestrator_path.chmod(0o700)
        self.save()

    @staticmethod
    def write(path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def git(self, repo, *args):
        result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True,
                                text=True, timeout=10, check=False)
        if result.returncode:
            raise AssertionError(result.stderr)
        return result.stdout.strip()

    def init(self, repo):
        repo.mkdir()
        self.git(repo, "init", "--quiet", "--initial-branch=main")
        # These identities belong solely to synthetic, unshared fixture repos.
        self.git(repo, "config", "user.name", "test")
        self.git(repo, "config", "user.email", "")
        self.git(repo, "config", "commit.gpgsign", "false")
        self.git(repo, "config", "core.filemode", "true")

    def commit(self, repo):
        paths = self.git(repo, "ls-files", "--modified", "--others", "--exclude-standard").splitlines()
        self.git(repo, "add", "--", *paths)
        self.git(repo, "commit", "--quiet", "-m", "fixture")
        return self.git(repo, "rev-parse", "HEAD")

    def pin(self, rev, number):
        self.write(self.repo / "flake.nix", ' {\n  inputs = {\n    # HNET pin ' + str(number)
                   + '\n    hausnetz = {\n      url = "git+ssh://git@github.com/inspr-at/hausnetz?rev='
                   + rev + '";\n      inputs.nixpkgs.follows = "nixpkgs";\n    };\n  };\n}\n')
        node = {"inputs": {"nixpkgs": ["nixpkgs"]},
                "locked": {"type": "git", "url": "ssh://git@github.com/inspr-at/hausnetz",
                           "rev": rev, "narHash": "sha256-" + str(number) * 43 + "=",
                           "lastModified": number, "revCount": number},
                "original": {"type": "git", "url": "ssh://git@github.com/inspr-at/hausnetz", "rev": rev}}
        lock = {"nodes": {"hausnetz": node, "root": {"inputs": {"hausnetz": "hausnetz"}},
                          "nixpkgs": {"locked": {"rev": "0" * 40}}}, "root": "root", "version": 7}
        self.write(self.repo / "flake.lock", json.dumps(lock, indent=2) + "\n")
        self.write(self.repo / "hosts/hsb0/docs/RUNBOOK.md",
                   "Before\nThe private flake input is pinned to `" + rev + "`\n(`v1."
                   + str(number) + ".0`, HNET pin " + str(number) + ", release sequence " + str(number)
                   + "; OPS-705).\nAfter\n")
        self.write(self.repo / "tests/T99-hausnetz-hsb0.sh",
                   "pin = '" + rev + "'  # HNET pin " + str(number) + " (v1." + str(number)
                   + ".0); repo in inspr-at\nassert node['locked']['narHash'] == '" + node["locked"]["narHash"]
                   + "'\nassert node['locked']['lastModified'] == " + str(number)
                   + "\nassert node['locked']['revCount'] == " + str(number) + "  # release\n")

    def save(self):
        try:
            nar_hash = json.loads((self.repo / "flake.lock").read_text())["nodes"]["hausnetz"]["locked"]["narHash"]
        except (ValueError, KeyError, TypeError):
            nar_hash = "invalid"
        (self.root / "execute.json").write_text(json.dumps(self.executor))
        (self.root / "orchestrate.json").write_text(json.dumps(self.orchestrator))
        (self.root / "scenario.json").write_text(json.dumps(self.scenario))
        (self.root / "fixture.json").write_text(json.dumps({
            **self.executor, "old_system": str(self.old_system), "new_system": str(self.new_system),
            "old_rev": self.old, "new_rev": self.new, "old_hnet": self.old_hnet,
            "new_hnet": self.new_hnet, "executor": str(self.executor_path),
            "old_version": self.old_version, "new_version": self.new_version,
            "old_exe": self.executables[0], "new_exe": self.executables[1],
            "nar_hash": nar_hash}))

    @property
    def key(self):
        return self.old_hnet + "-" + self.new_hnet

    def tick(self, mode=None, expect_ok=True):
        if mode:
            self.orchestrator["mode"] = mode
        self.save()
        result = subprocess.run([str(self.orchestrator_path)], env=self.env, capture_output=True,
                                text=True, timeout=18, check=False)
        if expect_ok and result.returncode:
            raise AssertionError(result.stderr)
        return result

    def execute(self, mode="dry-run", expect_ok=True, expected=None, version=None, manifest=None):
        self.save()
        self.run_id = "f" * 32
        result = subprocess.run([str(self.executor_path), self.new, expected or self.new_hnet, mode,
                                 version or self.new_version, manifest or self.manifest_sha, self.run_id],
                                env=self.env, capture_output=True, text=True, timeout=10, check=False)
        if expect_ok and result.returncode:
            raise AssertionError(result.stderr)
        return result

    def events(self, kind=None):
        path = self.root / "events"
        events = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [event for event in events if kind is None or event["kind"] == kind]

    def state(self):
        return json.loads(Path(self.orchestrator["state_file"]).read_text())

    def result(self):
        return json.loads((Path(self.executor["state_dir"]) / "results" / (self.run_id + ".json")).read_text())

    def terminal(self):
        state = self.state()
        if state["pending"]:
            details = (self.root / "executor.log").read_text()
            raise AssertionError("Executor did not finish: " + details)
        if not state["reports"]:
            raise AssertionError("No completed report for the requested deployment")
        return list(state["reports"].values())[-1]["result"]

    def advance(self, path, text):
        self.write(self.repo / path, text)
        self.new = self.commit(self.repo)
        self.save()

    def stop(self):
        # Normally all children have completed. Contain a broken mutant that
        # leaves the detached fixture executor waiting for an acknowledgement.
        results = list((Path(self.executor["state_dir"]) / "results").glob("*.json"))
        if any(json.loads(path.read_text()).get("phase") == "complete" for path in results):
            return
        path = self.root / "executor.pid"
        if path.exists():
            pid = int(path.read_text())
            try:
                os.kill(pid, 15)
            except ProcessLookupError:
                pass
            for _ in range(100):
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.01)


class TestCD(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="t125-")
        self.f = Fixture(Path(self.temporary.name))

    def tearDown(self):
        self.f.stop()
        self.temporary.cleanup()

    def manual(self):
        self.f.tick()
        self.assertEqual(self.f.terminal()["status"], "manual")
        self.assertFalse(self.f.events("switch"))

    def test_dry_run_success_and_limits(self):
        self.f.tick()
        result = self.f.terminal()
        self.assertEqual(result["status"], "dry-run")
        self.assertEqual(result["gates"], {"G1": "pass", "G2": "pass", "G3": "pass", "G4": "pass"})
        self.assertFalse(self.f.events("switch"))
        self.assertFalse(self.f.events("http"))
        self.assertFalse(self.f.events("telegram"))
        build = next(event for event in self.f.events("nix") if event["args"][0] == "build")["args"]
        self.assertEqual(build[build.index("--max-jobs") + 1], "1")
        self.assertEqual(build[build.index("--cores") + 1], "2")
        start = self.f.events("start")[0]["args"]
        for limit in ("--property=Nice=19", "--property=CPUQuota=200%", "--property=IOSchedulingClass=idle",
                      "--property=MemoryHigh=1G", "--property=MemoryMax=1500M",
                      "--property=RuntimeMaxSec=" + str(UNIT_RUNTIME_MAX),
                      "--property=KillMode=process", "--property=SendSIGKILL=no"):
            self.assertIn(limit, start)
        self.assertEqual(len(self.f.events("ticket")), 1)

    def test_live_success(self):
        self.f.tick("live")
        result = self.f.terminal()
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(self.f.state()["last_deployed"], self.f.new)
        self.assertEqual(result["health"], "pass")
        self.assertEqual(result["backup"], "copied")
        self.assertEqual(Path(self.f.executor["current_system"]).resolve(), self.f.new_system)
        self.assertEqual(len(list(Path(self.f.orchestrator["export_dir"]).glob("export-*"))), 1)
        self.assertEqual(Path(self.f.executor["state_dir"]).stat().st_mode & 0o777, 0o700)
        for path in Path(self.f.executor["state_dir"]).glob("results/*.json"):
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        events = self.f.events()
        ack = next(i for i, event in enumerate(events) if event.get("action") == "ack")
        switch = next(i for i, event in enumerate(events) if event["kind"] == "switch")
        self.assertLess(ack, switch)

    def test_health_fail_rolls_back_recorded_system(self):
        self.f.scenario.update(health_fail=True, rollback_delay=0.2)
        self.f.tick("live")
        result = self.f.terminal()
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["rollback"], "succeeded")
        self.assertEqual(result["rollback_health"], "pass")
        self.assertEqual(Path(self.f.executor["current_system"]).resolve(), self.f.old_system)
        self.assertEqual([event["target"] for event in self.f.events("switch")],
                         [str(self.f.new_system), str(self.f.old_system)])
        self.assertIn("auto-rollback", self.f.events("telegram")[0]["text"])
        # Only value-free messages cross the process/log boundary.
        self.assertNotIn("fixture_token", (self.f.root / "events").read_text())
        self.assertNotIn("fixture_token", (self.f.root / "executor.log").read_text())

    def test_rollback_failure_alarms_both_independent_paths(self):
        self.f.scenario.update(health_fail=True, rollback_fail=True, telegram_fail=True)
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "rollback_failed")
        self.assertTrue(Path(self.f.orchestrator["alarm_file"]).exists())
        self.assertIn("ROLLBACK FAILED", self.f.events("telegram")[0]["text"])
        self.assertIn("ROLLBACK FAILED", self.f.events("alarm")[0]["text"])
        self.assertIn("ROLLBACK FAILED", self.f.events("secondary-telegram")[0]["text"])

    def test_rollback_must_prove_old_revision(self):
        self.f.scenario.update(health_fail=True, rollback_health_fail=True)
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "rollback_failed")
        self.assertEqual(self.f.terminal()["rollback_health"], "fail")
        self.assertTrue(self.f.events("secondary-telegram"))

    def test_lock_busy_is_skip_and_can_retry(self):
        with open(self.f.executor["lock_file"], "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.f.tick()
            self.assertIsNone(self.f.state()["pending"])
            self.assertNotIn(self.f.new, self.f.state()["attempted"])
            self.assertFalse(self.f.events("nix"))
        self.f.tick()
        self.assertEqual(self.f.terminal()["status"], "dry-run")

    def test_lock_busy_preserves_completed_revision(self):
        self.f.tick()
        before = self.f.terminal()
        with open(self.f.executor["lock_file"], "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertNotEqual(self.f.execute(expect_ok=False).returncode, 0)
        self.assertEqual(self.f.terminal(), before)

    def test_idempotency_same_revision_and_failed_revision(self):
        self.f.scenario["build_fail"] = True
        self.f.tick()
        self.assertIn(self.f.new_hnet, self.f.state()["failed"])
        self.f.scenario["build_fail"] = False
        self.f.tick()
        self.assertEqual(len(self.f.events("start")), 1)
        self.assertEqual(len(self.f.events("ticket")), 1)

    def test_idempotency_success_and_executor_duplicate(self):
        self.f.tick()
        self.f.tick()
        self.assertEqual(len(self.f.events("start")), 1)
        result = self.f.execute(expect_ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len([e for e in self.f.events("nix") if e["args"][0] == "build"]), 1)

    def test_g1_compares_running_not_merge_parent(self):
        # The last commit is an eligible pin bump; an intervening unrelated
        # commit since RUNNING must nevertheless keep this deployment manual.
        self.f.git(self.f.repo, "branch", "pin", self.f.new)
        self.f.git(self.f.repo, "switch", "--quiet", "-c", "with-unrelated", self.f.old)
        self.f.write(self.f.repo / "other.nix", "{}\n")
        self.f.commit(self.f.repo)
        self.f.git(self.f.repo, "cherry-pick", "pin")
        # Point the synthetic origin's main at this new history.
        self.f.git(self.f.repo, "update-ref", "refs/heads/main", "HEAD")
        self.f.new = self.f.git(self.f.repo, "rev-parse", "HEAD")
        self.manual()
        self.assertFalse(self.f.events("start"))

    def test_g1_extra_file(self):
        self.f.advance("extra.nix", "{}\n")
        self.manual()

    def test_g1_same_file_extra_line(self):
        path = self.f.repo / "flake.nix"
        self.f.advance("flake.nix", path.read_text().replace('follows = "nixpkgs"', 'follows = "evil"'))
        self.manual()

    def test_g1_lock_other_node(self):
        text = (self.f.repo / "flake.lock").read_text().replace('"0' + "0" * 39 + '"', '"1' + "0" * 39 + '"')
        self.f.advance("flake.lock", text)
        self.manual()

    def test_g1_docs_and_tests_not_whole_file_allowlisted(self):
        for path in ("hosts/hsb0/docs/RUNBOOK.md", "tests/T99-hausnetz-hsb0.sh"):
            with self.subTest(path=path):
                original = (self.f.repo / path).read_text()
                self.f.advance(path, original + "extra operation\n")
                with self.assertRaises(Manual):
                    gate_g1(self.f.repo, self.f.old, self.f.new)

    def test_g1_mode_change_rejected(self):
        (self.f.repo / "flake.nix").chmod(0o755)
        self.f.new = self.f.commit(self.f.repo)
        self.manual()

    def test_g2_app_unavailable(self):
        self.f.scenario["prepare_missing"] = True
        self.manual()
        self.assertFalse(self.f.events("start"))

    def test_g2_manifest_missing(self):
        self.f.scenario["prepare"] = {"problems": ["manifest_missing"]}
        self.manual()

    def test_g2_changed_manifest(self):
        self.f.write(self.f.hnet / "capabilities.json", '{"writes":["new"]}\n')
        self.f.new_hnet = self.f.commit(self.f.hnet)
        self.f.pin(self.f.new_hnet, 3)
        self.f.new = self.f.commit(self.f.repo)
        self.manual()

    def test_g2_manifest_must_be_byte_identical(self):
        path = self.f.hnet / "capabilities.json"
        path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))
        self.f.new_hnet = self.f.commit(self.f.hnet)
        self.f.pin(self.f.new_hnet, 3)
        self.f.new = self.f.commit(self.f.repo)
        self.manual()

    def test_executor_rechecks_gates(self):
        self.f.advance("extra.nix", "{}\n")
        self.f.execute()
        self.assertEqual(self.f.result()["status"], "manual")
        self.assertFalse(self.f.events("nix"))

    def test_g3_extra_unit_on_stderr(self):
        self.f.scenario["extra_unit"] = True
        self.manual()
        self.assertEqual(self.f.terminal()["gates"]["G3"], "manual")

    def test_g3_extra_closure(self):
        self.f.scenario["extra_closure"] = True
        self.manual()

    def test_g3_unknown_output_and_hausnetz_required(self):
        self.f.scenario["activation"] = "activation succeeded; unknown semantics"
        self.manual()

    def test_readyz_flag_false_prevents_live(self):
        self.f.executor["require_readyz"] = False
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "manual")
        self.assertFalse(self.f.events("switch"))

    def test_unit_unreadable_prevents_live(self):
        (self.f.old_system / "etc/systemd/system/hausnetz.service").write_text("[Service]\n")
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "manual")
        self.assertFalse(self.f.events("switch"))

    def test_bare_200_is_not_revision_health(self):
        self.f.scenario["bare_200"] = True
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["rollback"], "succeeded")
        self.assertEqual(Path(self.f.executor["current_system"]).resolve(), self.f.old_system)

    def test_http_redirect_is_manual(self):
        self.f.scenario["http_status"] = 302
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "manual")
        self.assertFalse(self.f.events("switch"))

    def test_missing_runtime_credential_is_manual(self):
        self.f.executor["telegram_file"] = str(self.f.root / "not-provisioned")
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "manual")
        self.assertFalse(self.f.events("switch"))

    def test_bad_backup_prevents_switch(self):
        self.f.scenario["bad_export"] = True
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "manual")
        self.assertFalse(self.f.events("switch"))

    def test_zip_backup_live_success_and_retention(self):
        directory = Path(self.f.orchestrator["export_dir"])
        directory.mkdir()
        for index in range(23):
            path = directory / ("export-" + format(index, "040x") + ".json")
            path.write_text("{}")
            os.utime(path, (index, index))
        (directory / "unowned").write_text("retain")
        self.f.scenario["zip_export"] = True
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "succeeded")
        self.assertEqual(len(list(directory.glob("export-*"))), 20)
        self.assertTrue((directory / "unowned").exists())
        self.assertEqual(len(list(directory.glob("*.zip"))), 1)

    def test_export_copy_ack_required(self):
        self.f.executor["backup_ack_timeout"] = 0.01
        self.f.execute("live")
        self.assertEqual(self.f.result()["status"], "manual")
        self.assertFalse(self.f.events("switch"))

    def test_live_disabled_on_host(self):
        self.f.executor["allow_live"] = False
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "manual")
        self.assertFalse(self.f.events("nix"))
        self.assertFalse(self.f.events("switch"))

    def test_missing_independent_alert_refuses_live(self):
        self.f.orchestrator["secondary_telegram_command"] = []
        self.assertNotEqual(self.f.tick("live", expect_ok=False).returncode, 0)
        self.assertFalse(self.f.events("ssh"))

    def test_disabled_agent_has_no_effect(self):
        self.f.orchestrator["enabled"] = False
        self.f.tick()
        self.assertFalse(self.f.events())
        self.assertFalse(Path(self.f.orchestrator["state_file"]).exists())

    def test_ticket_outbox_does_not_repeat_executor(self):
        self.f.scenario["ticket_fail"] = True
        self.f.tick()
        self.assertFalse(self.f.state()["reports"][self.f.key]["ticket"])
        self.f.scenario["ticket_fail"] = False
        self.f.tick()
        self.assertTrue(self.f.state()["reports"][self.f.key]["ticket"])
        self.assertEqual(len(self.f.events("start")), 1)

    def test_uncertain_start_is_never_restarted(self):
        self.f.scenario["ssh_fail"] = "start"
        self.f.tick()
        self.assertIsNone(self.f.state()["pending"])
        self.assertIn(self.f.new_hnet, self.f.state()["failed"])
        self.assertTrue(Path(self.f.orchestrator["alarm_file"]).exists())
        self.f.scenario["ssh_fail"] = None
        self.f.tick()
        self.assertEqual(len([e for e in self.f.events("ssh") if e["action"] == "start"]), 1)
        self.assertFalse(self.f.events("switch"))

    def test_lost_live_status_uses_independent_alarm(self):
        self.f.scenario["ssh_fail"] = "start"
        self.f.tick("live")
        self.assertIsNone(self.f.state()["pending"])
        self.assertTrue(self.f.events("alarm"))
        self.assertIn("ROLLBACK STATUS UNKNOWN", self.f.events("secondary-telegram")[0]["text"])
        self.assertFalse(self.f.events("switch"))
        self.f.tick("live")
        self.assertEqual(len(self.f.events("secondary-telegram")), 1)

    def test_missing_running_evidence_is_manual(self):
        Path(self.f.executor["evidence_file"]).write_text('{}')
        self.manual()
        self.assertFalse(self.f.events("start"))

    def test_partial_switch_failure_recovers(self):
        self.f.scenario["partial_switch_fail"] = True
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["rollback"], "succeeded")
        self.assertEqual(Path(self.f.executor["current_system"]).resolve(), self.f.old_system)

    def test_stale_system_evidence_recovers(self):
        self.f.scenario["stale_evidence"] = True
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["rollback"], "succeeded")

    def test_invalid_json_and_archive_fail_closed(self):
        for data in (b"", b"null", b"{}", b"{broken", b"PKbroken"):
            with self.subTest(data=data), self.assertRaises(Manual):
                parse_export(data)
        with self.assertRaises(Manual):
            strict_json('{"a":1,"a":2}')

    def test_g1_real_worktree_shape_executable_test(self):
        # Copy the real four inputs AND their modes, rather than reducing the
        # executable T99 to a non-executable synthetic file again.
        paths = ("flake.nix", "flake.lock", "hosts/hsb0/docs/RUNBOOK.md", "tests/T99-hausnetz-hsb0.sh")
        for path in paths:
            shutil.copy2(REPO / path, self.f.repo / path)
        old = self.f.commit(self.f.repo)
        lock = json.loads((self.f.repo / "flake.lock").read_text())
        node = lock["nodes"]["hausnetz"]["locked"]
        replacements = [(node["rev"], "a" * 40), (node["narHash"], "sha256-" + "B" * 43 + "=")]
        replacements += [(str(node[k]), str(node[k] + 1)) for k in ("lastModified", "revCount")]
        for path in paths:
            text = (self.f.repo / path).read_text()
            for before, after in replacements:
                text = text.replace(before, after)
            (self.f.repo / path).write_text(text)
        new = self.f.commit(self.f.repo)
        self.assertEqual(self.f.git(self.f.repo, "ls-tree", new, "--", paths[-1]).split()[0], "100755")
        self.assertEqual(gate_g1(self.f.repo, old, new), (node["rev"], "a" * 40))

    def test_g1_real_pin66_merge(self):
        merge = self.f.git(REPO, "rev-parse", "5332600d1")
        parent = self.f.git(REPO, "rev-parse", merge + "^1")
        before, after = gate_g1(REPO, parent, merge)
        self.assertNotEqual(before, after)

    def test_unchanged_running_pin_is_silent(self):
        self.f.pin(self.f.old_hnet, 3)
        self.f.advance("unrelated.nix", "{}\n")
        self.f.tick()
        self.f.tick()
        self.assertFalse(self.f.events("ticket"))
        self.assertFalse(self.f.events("start"))
        self.assertFalse(Path(self.f.orchestrator["state_file"]).exists())

    def test_attempted_pair_not_nixcfg_revision(self):
        self.f.tick()
        self.f.pin(self.f.new_hnet, 3)
        self.f.new = self.f.commit(self.f.repo)
        self.f.tick()
        self.assertEqual(len(self.f.events("start")), 1)
        self.assertEqual(len(self.f.events("ticket")), 1)

    def test_failed_target_survives_bounded_history(self):
        self.f.scenario["build_fail"] = True
        self.f.tick()
        state = self.f.state()
        state["attempted"] = {}
        state["reports"] = {}
        state["failed"] = []
        Path(self.f.orchestrator["state_file"]).write_text(json.dumps(state))
        self.f.scenario["build_fail"] = False
        self.f.pin(self.f.new_hnet, 3)
        self.f.new = self.f.commit(self.f.repo)
        self.f.tick()
        self.assertEqual(len(self.f.events("start")), 1)
        self.assertEqual(len(self.f.events("ticket")), 1)

    def test_state_lists_keep_newest_200_across_reload(self):
        state = {"failed": [str(i) for i in range(210)],
                 "attempted": {str(210 - i): {"order": i} for i in range(210)},
                 "reports": {str(210 - i): {"order": i} for i in range(210)}}
        save_state(self.f.orchestrator, state)
        saved = self.f.state()
        for name in ("failed", "attempted", "reports"):
            self.assertEqual(len(saved[name]), 200)
        self.assertEqual(saved["failed"], [str(i) for i in range(10, 210)])
        self.assertNotIn("210", saved["attempted"])
        self.assertIn("1", saved["reports"])
        save_state(self.f.orchestrator, saved)
        self.assertEqual(self.f.state(), saved)

    def test_crashed_running_unit_is_failed_once_dry_run(self):
        self.f.scenario["crash"] = True
        self.f.tick()
        result = self.f.terminal()
        self.assertEqual(result["status"], "unknown")
        self.assertEqual(result["reason"], "executor_crashed_or_missing")
        self.assertIn(self.f.new_hnet, self.f.state()["failed"])
        self.assertIsNone(self.f.state()["pending"])
        self.assertTrue(Path(self.f.orchestrator["alarm_file"]).exists())
        self.assertFalse(self.f.events("alarm"))
        self.f.tick()
        self.assertEqual(len(self.f.events("ticket")), 1)
        self.assertEqual(len(self.f.events("start")), 1)

    def test_crashed_running_unit_live_alarms_once(self):
        self.f.scenario.update(crash=True, unit_state="unknown")
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "unknown")
        self.assertIn("ROLLBACK STATUS UNKNOWN", self.f.events("secondary-telegram")[0]["text"])
        self.f.tick("live")
        self.assertEqual(len(self.f.events("secondary-telegram")), 1)

    def test_stale_skipped_status_is_ignored(self):
        self.f.scenario["stale_status"] = True
        self.f.tick()
        self.assertEqual(self.f.terminal()["status"], "dry-run")
        self.assertEqual(len(self.f.events("start")), 1)

    def test_starting_status_precedes_lock(self):
        self.f.run_id = "f" * 32
        path = Path(self.f.executor["state_dir"]) / "results" / (self.f.run_id + ".json")
        def busy(*_args):
            self.assertTrue(path.is_file(), "starting status must precede flock")
            self.assertEqual(json.loads(path.read_text())["phase"], "starting")
            raise BlockingIOError
        with mock.patch("execute.fcntl.flock", side_effect=busy):
            execute_transaction(self.f.executor, self.f.new, self.f.new_hnet, "dry-run",
                                self.f.new_version, self.f.manifest_sha, self.f.run_id)
        result = self.f.result()
        self.assertEqual(result["status"], "skipped")
        self.assertEqual(result["run_id"], self.f.run_id)
        self.assertIsNotNone(result["started_at"])

    def test_short_ssh_drop_does_not_alarm(self):
        self.f.scenario["ssh_status_failures"] = 2
        self.f.orchestrator["ssh_retry_timeout"] = 2
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "succeeded")
        self.assertFalse(self.f.events("alarm"))
        self.assertFalse(Path(self.f.orchestrator["alarm_file"]).exists())

    def test_start_response_loss_reconciles_without_alarm(self):
        self.f.scenario["drop_start_response"] = True
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "succeeded")
        self.assertFalse(self.f.events("alarm"))
        self.assertFalse(Path(self.f.orchestrator["alarm_file"]).exists())

    def test_persistent_status_loss_fails_once(self):
        self.f.scenario["ssh_fail"] = "status"
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "unknown")
        self.assertIn(self.f.new_hnet, self.f.state()["failed"])
        self.assertIsNone(self.f.state()["pending"])
        self.f.tick("live")
        self.assertEqual(len(self.f.events("secondary-telegram")), 1)

    def test_poll_and_runtime_budgets(self):
        self.assertEqual(POLL_INTERVAL, 15)
        self.assertEqual(SSH_RETRY_TIMEOUT, 300)
        self.assertGreater(POLL_BUDGET, EXECUTOR_BUDGET + SSH_RETRY_TIMEOUT)
        self.assertGreater(UNIT_RUNTIME_MAX, POLL_BUDGET)
        text = (SOURCE / "execute.py").read_text()
        self.assertEqual(text.count('"switch"], timeout=None)'), 2)

    def test_running_system_changed_at_g3(self):
        self.f.scenario["change_during_g3"] = True
        self.manual()
        self.assertEqual(self.f.terminal()["reason"], "running_system_changed")

    def test_running_system_changed_after_ack(self):
        self.f.scenario["change_at_ack"] = True
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "manual")
        self.assertEqual(self.f.terminal()["reason"], "running_system_changed_before_switch")
        self.assertFalse(self.f.events("switch"))

    def test_expected_rev_must_match_lock(self):
        self.f.execute(expected=self.f.old_hnet)
        self.assertEqual(self.f.result()["status"], "manual")
        self.assertEqual(self.f.result()["reason"], "expected_revision_disagrees_with_lock")
        self.assertFalse(self.f.events("nix"))

    def test_profile_must_match_running_system(self):
        Path(self.f.executor["system_profile"]).unlink()
        Path(self.f.executor["system_profile"]).symlink_to(self.f.new_system)
        self.f.execute()
        self.assertEqual(self.f.result()["status"], "manual")
        self.assertEqual(self.f.result()["reason"], "profile_disagrees_with_running_system")
        self.assertFalse(self.f.events("nix"))

    def test_meta_version_mismatch_rolls_back(self):
        self.f.scenario["health_fail"] = True
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["rollback"], "succeeded")

    def test_exe_mismatch_rolls_back(self):
        self.f.scenario["exe_mismatch"] = True
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["rollback"], "succeeded")

    def test_exe_unreadable_rolls_back(self):
        self.f.scenario["exe_unreadable"] = True
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["rollback"], "succeeded")

    def test_readyz_missing_rolls_back(self):
        self.f.scenario["readyz_missing"] = True
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["rollback"], "succeeded")

    def test_readyz_503_rolls_back(self):
        self.f.scenario["readyz_503"] = True
        self.f.tick("live")
        result = self.f.terminal()
        self.assertEqual(result["rollback"], "succeeded", result)

    def test_readyz_false_rolls_back(self):
        self.f.scenario["readyz_false"] = True
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["rollback"], "succeeded")

    def test_rollback_requires_old_executable(self):
        self.f.scenario.update(health_fail=True, rollback_exe_mismatch=True)
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "rollback_failed")

    def test_telegram_token_never_in_argv(self):
        self.f.scenario["health_fail"] = True
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["telegram"], "sent")
        self.assertTrue(self.f.events("curl-argv"))
        self.assertFalse(self.f.events("credential-in-argv"))
        for event in self.f.events("curl-argv"):
            self.assertNotIn("fixture_token", " ".join(event["args"]))

    def test_prepare_nonzero_is_manual(self):
        self.f.scenario["prepare_exit"] = 1
        self.manual()

    def test_prepare_manifest_changed_is_manual(self):
        self.f.scenario["prepare"] = {"manifest_changed": True}
        self.manual()

    def test_prepare_persisted_false_is_manual(self):
        self.f.scenario["prepare"] = {"persisted_ok": False}
        self.manual()

    def test_prepare_narhash_mismatch_is_manual(self):
        self.f.scenario["prepare"] = {"narHash": "sha256-" + "A" * 43 + "="}
        self.manual()

    def test_prepare_rev_mismatch_is_manual(self):
        self.f.scenario["prepare"] = {"rev": "0" * 40}
        self.manual()

    def test_prepare_bad_json_is_manual(self):
        self.f.scenario["prepare_json"] = "{broken"
        self.manual()

    def test_prepare_extra_stdout_is_manual(self):
        self.f.scenario["prepare_extra_output"] = True
        self.manual()

    def test_prepare_schema_and_coordinates_fail_closed(self):
        value = {"rev": self.f.new_hnet, "narHash": "hash", "version": self.f.new_version,
                 "persisted_ok": True, "manifest_changed": False,
                 "manifest_sha256": "a" * 64, "running_manifest_sha256": "a" * 64, "problems": []}
        self.assertEqual(prepare_result(json.dumps(value), 0, self.f.new_hnet, "hash"), value)
        for field, bad in (("version", "26.13.99"), ("manifest_sha256", "z" * 64),
                           ("running_manifest_sha256", "b" * 64), ("persisted_ok", 1),
                           ("manifest_changed", 0), ("problems", "")):
            with self.subTest(field=field), self.assertRaises(Manual):
                prepare_result(json.dumps({**value, field: bad}), 0, self.f.new_hnet, "hash")
        with self.assertRaises(Manual):
            prepare_result(json.dumps({**value, "extra": True}), 0, self.f.new_hnet, "hash")
        with self.assertRaises(Manual):
            prepare_result(json.dumps({**value, "manifest_sha256": "z" * 64,
                                       "running_manifest_sha256": "z" * 64}), 0, self.f.new_hnet, "hash")
        for version in ("260229000000.0.0", "261131000000.0.0", "261126240000.0.0", "261126120508.0.0x"):
            with self.subTest(version=version), self.assertRaises(Manual):
                coordinate(version)

    def test_prepare_timeout_is_manual(self):
        with mock.patch("common.git", return_value=""), mock.patch("common.subprocess.run", side_effect=subprocess.TimeoutExpired("nix", 600)) as call:
            with self.assertRaises(Manual):
                gate_g2(self.f.hnet, self.f.old_hnet, self.f.new_hnet, "hash")
            self.assertEqual(call.call_args.kwargs["timeout"], 600)

    def test_full_history_clone_is_maintained(self):
        clone = Path(self.f.orchestrator["cache_dir"]) / "hausnetz"
        clone.parent.mkdir()
        self.f.git(self.f.hnet, "clone", "--quiet", "--depth=1", self.f.hnet.as_uri(), str(clone))
        self.f.git(clone, "config", "remote.origin.url", str(self.f.hnet))
        self.f.tick()
        self.assertEqual(self.f.terminal()["status"], "dry-run")
        self.assertEqual(self.f.git(clone, "rev-parse", "--is-shallow-repository"), "false")

    def test_g4_nix_directory_change_is_manual(self):
        self.f.write(self.f.hnet / "nix/module.nix", '{ newCapability = true; }\n')
        self.f.new_hnet = self.f.commit(self.f.hnet)
        self.f.pin(self.f.new_hnet, 3)
        self.f.new = self.f.commit(self.f.repo)
        self.manual()
        self.assertEqual(self.f.terminal()["gates"]["G4"], "manual")
        self.assertFalse(self.f.events("prepare"))

    def test_g4_flake_and_lock_changes_are_manual(self):
        for path in ("flake.nix", "flake.lock"):
            self.f.write(self.f.hnet / path, "changed\n")
            new = self.f.commit(self.f.hnet)
            with self.subTest(path=path), self.assertRaises(Manual):
                gate_g4(self.f.hnet, self.f.old_hnet, new)

    def test_lock_parse_errors_are_one_manual_outcome(self):
        for text in ("{broken", "{}", '{"nodes":[],"root":"root"}'):
            self.f.advance("flake.lock", text)
            before = len(self.f.events("ticket"))
            self.f.tick()
            self.f.tick()
            self.assertEqual(len(self.f.events("ticket")), before + 1)
            self.assertFalse(self.f.events("start"))
            self.assertEqual(self.f.terminal()["status"], "manual")

    def test_remote_rev_and_digest_regexes(self):
        Path(self.f.executor["state_dir"]).mkdir()
        def remote_script(action, rev, digest, *, expected=None, token=None, version=None, manifest=None):
            self.f.save()
            script = REMOTE.replace("/var/lib/hausnetz-cd", self.f.executor["state_dir"])
            script = script.replace("/run/current-system/sw/bin/hausnetz-cd-execute", str(self.f.executor_path))
            args = ["bash", "-s", "--", action, rev,
                    self.f.new_hnet if expected is None else expected, "dry-run", digest,
                    "a" * 32 if token is None else token,
                    self.f.new_version if version is None else version,
                    self.f.manifest_sha if manifest is None else manifest]
            return subprocess.run(args, input=script, env=self.f.env, capture_output=True, text=True, check=False)
        for bad in ("a" * 39, "A" * 40, "a" * 40 + ";true", "../bad"):
            self.assertNotEqual(remote_script("start", bad, "").returncode, 0)
            self.assertNotEqual(remote_script("start", self.f.new, "", expected=bad).returncode, 0)
        for bad in ("a" * 31, "A" * 32, "a" * 32 + ";true", "../bad"):
            self.assertNotEqual(remote_script("start", self.f.new, "", token=bad).returncode, 0)
        for bad in ("", "261126120508.0.0x", "../bad", "261126120508.0.0\n"):
            self.assertNotEqual(remote_script("start", self.f.new, "", version=bad).returncode, 0)
        for bad in ("a" * 63, "A" * 64, "a" * 64 + "\n", "../bad"):
            self.assertNotEqual(remote_script("ack", self.f.new, bad).returncode, 0)
            self.assertNotEqual(remote_script("start", self.f.new, "", manifest=bad).returncode, 0)
        self.assertFalse(self.f.events("start"))
        self.assertFalse((Path(self.f.executor["state_dir"]) / ("ack-" + "a" * 32)).exists())

    def test_result_identity_requires_run_id(self):
        result = {"schema": "inspr.pharos.guarded-deploy-result.v1", "nixcfg_rev": self.f.new,
                  "hausnetz_rev": self.f.new_hnet, "mode": "dry-run", "status": "running", "run_id": "a" * 32}
        pending = {**result, "run_id": "b" * 32}
        with self.assertRaises(Manual):
            validate_result(result, pending)

    def test_executor_rejects_invalid_version(self):
        self.f.execute(version="261131120508.0.0")
        self.assertEqual(self.f.result()["reason"], "invalid_calendar_version")
        self.assertFalse(self.f.events("nix"))

    def test_executor_rejects_invalid_manifest_digest(self):
        self.f.execute(manifest="z" * 64)
        self.assertEqual(self.f.result()["reason"], "invalid_manifest_digest")
        self.assertFalse(self.f.events("nix"))

    def test_built_version_must_match_prepare(self):
        self.f.scenario["prepare"] = {"version": self.f.old_version}
        self.manual()
        self.assertEqual(self.f.terminal()["reason"], "built_version_disagrees_with_prepare")

    def test_missing_mainpid_rolls_back(self):
        self.f.scenario["pid_missing"] = True
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["rollback"], "succeeded")

    def test_rollback_requires_old_readiness(self):
        self.f.scenario.update(health_fail=True, rollback_readyz_false=True)
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "rollback_failed")


def mutants():
    # Run the same behavioral assertions against real source copies. A zero
    # exit means a guard-removal survived and this entire test must fail.
    cases = [
        ("G1 extra file", "common.py", [('require(len(parts) == 2 and parts[0] == "M" and parts[1] in allowed,', 'require(True,')], "test_g1_extra_file"),
        ("G1 executable mode change", "common.py", [('require(tree_mode(repo, old, parts[1]) == tree_mode(repo, new, parts[1]),', 'require(True,')], "test_g1_mode_change_rejected"),
        ("G1 flake lines", "common.py", [('require(mask_flake(blob(repo, old, "flake.nix"), a)', 'require(True or mask_flake(blob(repo, old, "flake.nix"), a)')], "test_g1_same_file_extra_line"),
        ("G1 lock leaves", "common.py", [("require(mask_lock(a_text) == mask_lock(b_text)", "require(True or mask_lock(a_text) == mask_lock(b_text)")], "test_g1_lock_other_node"),
        ("G1 doc/test lines", "common.py", [('require(mask_doc(blob(repo, old, path), a)', 'require(True or mask_doc(blob(repo, old, path), a)'), ('require(mask_test(blob(repo, old, path), a, a_lock)', 'require(True or mask_test(blob(repo, old, path), a, a_lock)')], "test_g1_docs_and_tests_not_whole_file_allowlisted"),
        ("G1 running baseline", "common.py", [('revision(old)\n    revision(new)', 'old = git(repo, "rev-parse", new + "^").strip()\n    revision(new)')], "test_g1_compares_running_not_merge_parent"),
        ("unchanged pin is silent", "orchestrate.py", [('if expected == running:', 'if False:')], "test_unchanged_running_pin_is_silent"),
        ("bounded state summaries", "orchestrate.py", [('state["failed"][-200:]', 'state["failed"][:]'), ('item[1]["order"])[-200:]', 'item[1]["order"])[:]')], "test_state_lists_keep_newest_200_across_reload"),
        ("G2 exit status", "common.py", [('returncode == 0 and value["persisted_ok"] is True', 'True and value["persisted_ok"] is True')], "test_prepare_nonzero_is_manual"),
        ("G2 manifest changed", "common.py", [('value["manifest_changed"] is False and not value["problems"]', 'True and not value["problems"]')], "test_prepare_manifest_changed_is_manual"),
        ("G2 persisted data", "common.py", [('returncode == 0 and value["persisted_ok"] is True', 'returncode == 0 and True')], "test_prepare_persisted_false_is_manual"),
        ("G2 narHash", "common.py", [('value["narHash"] == nar_hash', 'True')], "test_prepare_narhash_mismatch_is_manual"),
        ("G2 expected revision", "common.py", [('value["rev"] == expected and value["narHash"]', 'True and value["narHash"]')], "test_prepare_rev_mismatch_is_manual"),
        ("G2 manifest byte identity", "common.py", [('value["manifest_changed"] is False', 'True'), ('value["manifest_sha256"] == value["running_manifest_sha256"]', 'True')], "test_g2_manifest_must_be_byte_identical"),
        ("G2 problems", "common.py", [('not value["problems"]', 'True')], "test_g2_manifest_missing"),
        ("G2 schema", "common.py", [('isinstance(value, dict) and set(value) == fields', 'isinstance(value, dict)')], "test_prepare_schema_and_coordinates_fail_closed"),
        ("G2 calendar version", "common.py", [('    coordinate(value["version"])', '    pass')], "test_prepare_schema_and_coordinates_fail_closed"),
        ("G2 digest format", "common.py", [('    digest(value["manifest_sha256"])', '    pass'), ('    digest(value["running_manifest_sha256"])', '    pass')], "test_prepare_schema_and_coordinates_fail_closed"),
        ("G2 full-history clone", "common.py", [('git(path, "fetch", "--quiet", "--unshallow", "origin")', 'pass')], "test_full_history_clone_is_maintained"),
        ("G4 nix directory", "common.py", [('def gate_g4(repo, old, new):\n', 'def gate_g4(repo, old, new):\n    return\n')], "test_g4_nix_directory_change_is_manual"),
        ("G4 flake and lock", "common.py", [('"--", "nix/", "flake.nix", "flake.lock")', '"--", "nix/")')], "test_g4_flake_and_lock_changes_are_manual"),
        ("G3 unit allowlist", "common.py", [('all(unit in allowed[action] for unit in units)', 'True')], "test_g3_extra_unit_on_stderr"),
        ("G3 closure allowlist", "common.py", [('name in {"hausnetz", "etc", "etc-json", "etc-pharos-deployment-evidence.json",\n                         "pharos-deployment-evidence"}', 'True')], "test_g3_extra_closure"),
        ("shared deploy lock", "execute.py", [('fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)', 'pass')], "test_lock_busy_is_skip_and_can_retry"),
        ("pair idempotency", "orchestrate.py", [('key in state["attempted"] or expected in state["failed"]', 'False or expected in state["failed"]'), ('or ledger(config, "attempted", key).exists()', 'or False')], "test_attempted_pair_not_nixcfg_revision"),
        ("failed target tombstone", "orchestrate.py", [('or ledger(config, "failed", expected).exists()', 'or False'), ('or ledger(config, "attempted", key).exists()', 'or False')], "test_failed_target_survives_bounded_history"),
        ("executor idempotency", "execute.py", [('\n    require(not attempt.exists(), "revision_already_attempted")', '\n    pass'), ('\n        require(not attempt.exists(), "revision_already_attempted")', '\n        pass')], "test_idempotency_success_and_executor_duplicate"),
        ("crashed executor detection", "orchestrate.py", [('if response["unit_state"] not in {"active", "activating", "deactivating"}:', 'if False:')], "test_crashed_running_unit_is_failed_once_dry_run"),
        ("run-scoped status identity", "orchestrate.py", [('            and result.get("run_id") == pending["run_id"]', '            and True'), ('isinstance(result, dict) and result.get("run_id") == pending["run_id"]', 'isinstance(result, dict)')], "test_stale_skipped_status_is_ignored"),
        ("result identity run ID", "orchestrate.py", [('            and result.get("run_id") == pending["run_id"]', '            and True')], "test_result_identity_requires_run_id"),
        ("SSH retry grace", "orchestrate.py", [('retry = fixture_limit(config, "ssh_retry_timeout", SSH_RETRY_TIMEOUT)', 'retry = 0')], "test_short_ssh_drop_does_not_alarm"),
        ("executor observation budget", "common.py", [('POLL_BUDGET = EXECUTOR_BUDGET + SSH_RETRY_TIMEOUT + 120', 'POLL_BUDGET = 720')], "test_poll_and_runtime_budgets"),
        ("transient memory limit", "orchestrate.py", [('--property=MemoryMax=1500M', '--property=MemoryMax=4G')], "test_dry_run_success_and_limits"),
        ("dry-run isolation", "execute.py", [('if mode == "dry-run":', 'if False:')], "test_dry_run_success_and_limits"),
        ("binary store-path proof", "execute.py", [('require(executable == proof["exe"],', 'require(True,')], "test_exe_mismatch_rolls_back"),
        ("metadata version proof", "execute.py", [('isinstance(value, dict) and value.get("version") == proof["version"]', 'True')], "test_meta_version_mismatch_rolls_back"),
        ("bare HTTP 200 rejected", "execute.py", [('isinstance(value, dict) and value.get("version") == proof["version"]', 'True')], "test_bare_200_is_not_revision_health"),
        ("readyz HTTP status", "common.py", [('separator and code == b"200"', 'separator')], "test_readyz_503_rolls_back"),
        ("readyz missing path", "common.py", [('separator and code == b"200"', 'separator')], "test_readyz_missing_rolls_back"),
        ("readyz JSON readiness", "execute.py", [('isinstance(ready, dict) and ready.get("ok") is True', 'True')], "test_readyz_false_rolls_back"),
        ("readiness live gate", "execute.py", [('require(mode != "live" or config.get("require_readyz", True) is True,', 'require(True,'), ('require(config.get("require_readyz", True) is True,', 'require(True,')], "test_readyz_flag_false_prevents_live"),
        ("running system after G3", "execute.py", [('require(evidence(Path(config["evidence_file"]).read_bytes()) == old_rev\n                    and str(Path(config["current_system"]).resolve(strict=True)) == old_system,', 'require(True,')], "test_running_system_changed_at_g3"),
        ("running system after ack", "execute.py", [('require(evidence(Path(config["evidence_file"]).read_bytes()) == old_rev\n                        and str(Path(config["current_system"]).resolve(strict=True)) == old_system\n                        and str(Path(config["system_profile"]).resolve(strict=True)) == old_system,', 'require(True,')], "test_running_system_changed_after_ack"),
        ("expected revision versus lock", "execute.py", [('require(b == expected,', 'require(True,')], "test_expected_rev_must_match_lock"),
        ("profile versus running system", "execute.py", [('require(str(Path(config["system_profile"]).resolve(strict=True)) == old_system,', 'require(True,')], "test_profile_must_match_running_system"),
        ("remote revision regex", "orchestrate.py", [('[[ "$rev" =~ ^[0-9a-f]{40}$ ]]', 'true')], "test_remote_rev_and_digest_regexes"),
        ("remote digest regex", "orchestrate.py", [('[[ "$digest" =~ ^[0-9a-f]{64}$ ]]', 'true')], "test_remote_rev_and_digest_regexes"),
        ("Telegram token outside argv", "execute.py", [('"--max-time", "10", "--config", "-"', '"--max-time", "10", "https://api.telegram.org/bot" + lines[0] + "/sendMessage"')], "test_telegram_token_never_in_argv"),
        ("backup parsing", "common.py", [('def parse_export(data):\n', 'def parse_export(data):\n    return "json", hashlib.sha256(data).hexdigest()\n')], "test_bad_backup_prevents_switch"),
        ("offhost backup ack", "execute.py", [('require(ack.is_file() and ack.read_text().strip() == digest,', 'require(True,')], "test_export_copy_ack_required"),
        ("recorded rollback", "execute.py", [('run([result["old_system"] + "/bin/switch-to-configuration", "switch"]', 'run([result["new_system"] + "/bin/switch-to-configuration", "switch"]')], "test_health_fail_rolls_back_recorded_system"),
        ("rollback old proof", "execute.py", [('require(health(config, result["old_proof"]), "rollback_health_failed")', 'require(True, "rollback_health_failed")')], "test_rollback_must_prove_old_revision"),
        ("wait for completed rollback", "orchestrate.py", [('or (result.get("phase") == "complete" and result.get("completed_at"))', 'or True')], "test_health_fail_rolls_back_recorded_system"),
        ("rollback Telegram", "execute.py", [('"auto-rollback" if result["rollback"]', '"wrong" if result["rollback"]')], "test_health_fail_rolls_back_recorded_system"),
        ("rollback failure alarms", "orchestrate.py", [('alarm(config, result, "ROLLBACK STATUS UNKNOWN" if result["status"] == "unknown" else "ROLLBACK FAILED")', 'pass')], "test_rollback_failure_alarms_both_independent_paths"),
        ("host live enable gate", "execute.py", [('require(mode != "live" or config.get("allow_live") is True,', 'require(True,')], "test_live_disabled_on_host"),
        ("independent alert required", "orchestrate.py", [('require(config.get("secondary_telegram_command"),', 'require(True,')], "test_missing_independent_alert_refuses_live"),
        ("agent disabled default", "orchestrate.py", [('if config.get("enabled") is not True:', 'if False:')], "test_disabled_agent_has_no_effect"),
        ("build resource limit", "execute.py", [('"--max-jobs", "1", "--cores", "2"', '"--max-jobs", "4", "--cores", "8"')], "test_dry_run_success_and_limits"),
        ("G2 extra stdout", "common.py", [('value = strict_json(stdout)', 'value = json.JSONDecoder().raw_decode(stdout.decode())[0]')], "test_prepare_extra_stdout_is_manual"),
        ("G2 app timeout", "common.py", [('capture_output=True, timeout=600, check=False)', 'capture_output=True, timeout=None, check=False)')], "test_prepare_timeout_is_manual"),
        ("fresh starting status", "execute.py", [('    save()\n    attempt = state', '    attempt = state')], "test_starting_status_precedes_lock"),
        ("lock parse errors per tick", "orchestrate.py", [('except (Manual, OSError, KeyError, TypeError, ValueError) as exc:', 'except OSError as exc:')], "test_lock_parse_errors_are_one_manual_outcome"),
        ("built package versus prepared version", "execute.py", [('require(result["new_proof"]["version"] == expected_version,', 'require(True,')], "test_built_version_must_match_prepare"),
        ("activation never killed by timeout", "execute.py", [('run([new_system + "/bin/switch-to-configuration", "switch"], timeout=None)', 'run([new_system + "/bin/switch-to-configuration", "switch"], timeout=120)')], "test_poll_and_runtime_budgets"),
        ("remote expected revision regex", "orchestrate.py", [('[[ "$expected" =~ ^[0-9a-f]{40}$ ]]', 'true')], "test_remote_rev_and_digest_regexes"),
        ("remote run ID regex", "orchestrate.py", [('[[ "$run_id" =~ ^[0-9a-f]{32}$ ]]', 'true')], "test_remote_rev_and_digest_regexes"),
        ("remote version regex", "orchestrate.py", [('[[ "$version" =~ ^[0-9]{12}\\.0\\.0$ ]]', 'true')], "test_remote_rev_and_digest_regexes"),
        ("remote manifest digest regex", "orchestrate.py", [('[[ "$manifest_sha" =~ ^[0-9a-f]{64}$ ]]', 'true')], "test_remote_rev_and_digest_regexes"),
    ]
    for label, file, edits, test in cases:
        with tempfile.TemporaryDirectory(prefix="t125-mutant-") as temporary:
            source = Path(temporary)
            for path in SOURCE.glob("*"):
                if path.suffix in {".py", ".sh"}:
                    shutil.copyfile(path, source / path.name)
            text = (source / file).read_text()
            for before, after in edits:
                if text.count(before) != 1:
                    raise AssertionError("Mutant no longer matches exactly once: " + label)
                text = text.replace(before, after, 1)
            (source / file).write_text(text)
            result = subprocess.run([sys.executable, "-B", str(Path(__file__).resolve()), "TestCD." + test],
                                    env=dict(os.environ, HAUSNETZ_CD_SOURCE=str(source)),
                                    capture_output=True, text=True, timeout=25, check=False)
            if result.returncode == 0:
                raise AssertionError("SURVIVED guard-removal mutant: " + label)
            # Do not count a syntax/import/fixture setup failure as a killed
            # mutant. The selected behavior assertion itself must fail.
            if "FAIL: " not in result.stderr:
                raise AssertionError("Invalid mutant run: " + label + "\n" + result.stderr)
            print("must-fail mutant killed: " + label, flush=True)
    print("T125: " + str(len(cases)) + " guard-removal mutants killed", flush=True)


if __name__ == "__main__":
    if sys.argv[1:] == ["--mutants"]:
        mutants()
    else:
        unittest.main(verbosity=2)
