"""Offline transactions and guard-removal mutants for OPS-705."""

import fcntl
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


REPO = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get("HAUSNETZ_CD_SOURCE", REPO / "modules/hausnetz-cd"))
sys.path.insert(0, str(SOURCE))
from common import Manual, gate_g1, gate_g2, parse_export, strict_json
from execute import health


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
                        "paimos", "alarm", "secondary-telegram", "switch-to-configuration"):
            target = self.bin / command
            target.write_text("#!" + sys.executable + "\n" + fake.read_text())
            target.chmod(0o700)
        self.scenario = {}
        (root / "scenario.json").write_text("{}")
        self.hnet = root / "hausnetz"
        self.init(self.hnet)
        self.write(self.hnet / "capabilities.json", '{"connections":[],"secrets":[],"writes":[]}\n')
        self.write(self.hnet / "app", "old\n")
        self.old_hnet = self.commit(self.hnet)
        self.write(self.hnet / "app", "new\n")
        self.new_hnet = self.commit(self.hnet)
        self.repo = root / "nixcfg"
        self.init(self.repo)
        self.pin(self.old_hnet, 1)
        self.old = self.commit(self.repo)
        self.pin(self.new_hnet, 2)
        self.new = self.commit(self.repo)
        self.old_system = root / "store/old-system"
        self.new_system = root / "store/new-system"
        for system in (self.old_system, self.new_system):
            (system / "bin").mkdir(parents=True)
            (system / "bin/switch-to-configuration").symlink_to(self.bin / "switch-to-configuration")
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
            "nixcfg_url": str(self.repo), "hausnetz_url": str(self.hnet),
            "manifest_path": "capabilities.json", "current_system": str(root / "current-system"),
            "system_profile": str(root / "profile"), "store_pattern": str(root / "store") + r"/[^/]+",
            "version_url": "http://127.0.0.1:8377/version", "version_field": "revision",
            "health_url": "http://127.0.0.1:8377/healthz", "health_timeout": 0.2,
            "backup_ack_timeout": 3, "telegram_file": str(self.credential),
        }
        self.orchestrator = {
            "enabled": True, "mode": "dry-run", "target": "mba@hsb0.lan",
            "release_ticket": "HNET-570", "nixcfg_url": str(self.repo), "hausnetz_url": str(self.hnet),
            "manifest_path": "capabilities.json", "state_file": str(root / "local/state.json"),
            "cache_dir": str(root / "cache"), "export_dir": str(root / "exports"),
            "alarm_file": str(root / "local/alarm.json"), "poll_timeout": 6, "poll_interval": 0.02,
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
        (self.root / "execute.json").write_text(json.dumps(self.executor))
        (self.root / "orchestrate.json").write_text(json.dumps(self.orchestrator))
        (self.root / "scenario.json").write_text(json.dumps(self.scenario))
        (self.root / "fixture.json").write_text(json.dumps({
            **self.executor, "old_system": str(self.old_system), "new_system": str(self.new_system),
            "old_rev": self.old, "new_rev": self.new, "old_hnet": self.old_hnet,
            "new_hnet": self.new_hnet, "executor": str(self.executor_path)}))

    def tick(self, mode=None, expect_ok=True):
        if mode:
            self.orchestrator["mode"] = mode
        self.save()
        result = subprocess.run([str(self.orchestrator_path)], env=self.env, capture_output=True,
                                text=True, timeout=12, check=False)
        if expect_ok and result.returncode:
            raise AssertionError(result.stderr)
        return result

    def execute(self, mode="dry-run", expect_ok=True):
        self.save()
        result = subprocess.run([str(self.executor_path), self.new, self.new_hnet, mode],
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
        return json.loads((Path(self.executor["state_dir"]) / "results" / (self.new + ".json")).read_text())

    def terminal(self):
        state = self.state()
        if state["pending"]:
            details = (self.root / "executor.log").read_text()
            raise AssertionError("Executor did not finish: " + details)
        return state["reports"][self.new]["result"]

    def advance(self, path, text):
        self.write(self.repo / path, text)
        self.new = self.commit(self.repo)
        self.save()

    def stop(self):
        # Normally all children have completed. Contain a broken mutant that
        # leaves the detached fixture executor waiting for an acknowledgement.
        result = Path(self.executor["state_dir"]) / "results" / (self.new + ".json")
        if result.exists() and json.loads(result.read_text()).get("status") in {
                "manual", "dry-run", "succeeded", "failed", "rollback_failed", "skipped"}:
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
        self.assertEqual(result["gates"], {"G1": "pass", "G2": "pass", "G3": "pass"})
        self.assertFalse(self.f.events("switch"))
        self.assertFalse(self.f.events("http"))
        self.assertFalse(self.f.events("telegram"))
        build = next(event for event in self.f.events("nix") if event["args"][0] == "build")["args"]
        self.assertEqual(build[build.index("--max-jobs") + 1], "1")
        self.assertEqual(build[build.index("--cores") + 1], "2")
        start = self.f.events("start")[0]["args"]
        for limit in ("--property=Nice=19", "--property=CPUQuota=200%", "--property=IOSchedulingClass=idle"):
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
        with open(self.f.executor["lock_file"], "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertNotEqual(self.f.execute(expect_ok=False).returncode, 0)
        self.assertEqual(self.f.result()["status"], "dry-run")

    def test_idempotency_same_revision_and_failed_revision(self):
        self.f.scenario["build_fail"] = True
        self.f.tick()
        self.assertIn(self.f.new, self.f.state()["failed"])
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

    def test_g2_manifest_unset(self):
        self.f.orchestrator["manifest_path"] = None
        self.manual()
        self.assertFalse(self.f.events("start"))
        with self.assertRaises(Manual):
            gate_g2(self.f.hnet, self.f.old_hnet, self.f.new_hnet, None)

    def test_g2_manifest_missing(self):
        self.f.orchestrator["manifest_path"] = self.f.executor["manifest_path"] = "missing.json"
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

    def test_endpoint_unset_prevents_live(self):
        self.f.executor["version_url"] = None
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "manual")
        self.assertFalse(self.f.events("switch"))

    def test_version_field_and_health_endpoint_unset_prevent_live(self):
        self.f.executor["version_field"] = None
        self.f.executor["health_url"] = None
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
        self.assertFalse(self.f.state()["reports"][self.f.new]["ticket"])
        self.f.scenario["ticket_fail"] = False
        self.f.tick()
        self.assertTrue(self.f.state()["reports"][self.f.new]["ticket"])
        self.assertEqual(len(self.f.events("start")), 1)

    def test_uncertain_start_is_never_restarted(self):
        self.f.scenario["ssh_fail"] = "start"
        self.f.tick()
        self.assertIsNotNone(self.f.state()["pending"])
        self.f.scenario["ssh_fail"] = None
        self.f.tick()
        self.assertEqual(len([e for e in self.f.events("ssh") if e["action"] == "start"]), 1)
        self.assertFalse(self.f.events("switch"))

    def test_lost_live_status_uses_independent_alarm(self):
        self.f.scenario["ssh_fail"] = "start"
        self.f.tick("live")
        self.assertIsNotNone(self.f.state()["pending"])
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


def mutants():
    # Run the same behavioral assertions against real source copies. A zero
    # exit means a guard-removal survived and this entire test must fail.
    cases = [
        ("G1 extra file", "common.py", [('require(len(parts) == 2 and parts[0] == "M" and parts[1] in allowed,', 'require(True,')], "test_g1_extra_file"),
        ("G1 flake lines", "common.py", [('require(mask_flake(blob(repo, old, "flake.nix"), a)',
                                            'require(True or mask_flake(blob(repo, old, "flake.nix"), a)')], "test_g1_same_file_extra_line"),
        ("G1 lock leaves", "common.py", [("require(mask_lock(a_text) == mask_lock(b_text)",
                                           "require(True or mask_lock(a_text) == mask_lock(b_text)")], "test_g1_lock_other_node"),
        ("G1 doc/test lines", "common.py", [('require(mask_doc(blob(repo, old, path), a)',
                                               'require(True or mask_doc(blob(repo, old, path), a)'),
                                              ('require(mask_test(blob(repo, old, path), a, a_lock)',
                                               'require(True or mask_test(blob(repo, old, path), a, a_lock)')], "test_g1_docs_and_tests_not_whole_file_allowlisted"),
        ("G1 running baseline", "common.py", [("revision(old)\n    revision(new)",
                                               'old = git(repo, "rev-parse", new + "^").strip()\n    revision(new)')], "test_g1_compares_running_not_merge_parent"),
        ("G2 manifest", "common.py", [("def gate_g2(repo, old, new, path):\n", "def gate_g2(repo, old, new, path):\n    return\n")], "test_g2_manifest_missing"),
        ("G2 manifest unset", "common.py", [("def gate_g2(repo, old, new, path):\n", "def gate_g2(repo, old, new, path):\n    return\n")], "test_g2_manifest_unset"),
        ("G2 byte identity", "common.py", [('return run(["git", "-C", repo, "show", rev + ":" + path], binary=True).decode("utf-8")', 'return git(repo, "show", rev + ":" + path)')], "test_g2_manifest_must_be_byte_identical"),
        ("G3 unit allowlist", "common.py", [("all(unit in allowed[action] for unit in units)", "True")], "test_g3_extra_unit_on_stderr"),
        ("G3 closure allowlist", "common.py", [('name in {"hausnetz", "etc", "etc-json", "etc-pharos-deployment-evidence.json",\n                         "pharos-deployment-evidence"}', "True")], "test_g3_extra_closure"),
        ("shared deploy lock", "execute.py", [("fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)", "pass")], "test_lock_busy_is_skip_and_can_retry"),
        ("orchestrator idempotency", "orchestrate.py", [('if new in state["attempted"] or new in state["failed"] or new == state["last_deployed"]:', "if False:")], "test_idempotency_same_revision_and_failed_revision"),
        ("executor idempotency", "execute.py", [('require(prior.get("status") == "skipped",', 'require(True,')], "test_idempotency_success_and_executor_duplicate"),
        ("dry-run isolation", "execute.py", [('if mode == "dry-run":', "if False:")], "test_dry_run_success_and_limits"),
        ("exact revision health", "execute.py", [("value = strict_json(body)", "value = {field: rev}")], "test_bare_200_is_not_revision_health"),
        ("version endpoint required", "execute.py", [('require(config.get("version_url") and config.get("version_field")', 'require(True or config.get("version_url") and config.get("version_field")'),
                                                     ('def health(config, rev):\n', 'def health(config, rev):\n    if not config.get("version_url"):\n        return True\n')], "test_endpoint_unset_prevents_live"),
        ("backup parsing", "common.py", [("def parse_export(data):\n", 'def parse_export(data):\n    return "json", hashlib.sha256(data).hexdigest()\n')], "test_bad_backup_prevents_switch"),
        ("offhost backup ack", "execute.py", [('require(ack.is_file() and ack.read_text().strip() == digest,', 'require(True,')], "test_export_copy_ack_required"),
        ("recorded rollback", "execute.py", [('run([result["old_system"] + "/bin/switch-to-configuration", "switch"]', 'run([result["new_system"] + "/bin/switch-to-configuration", "switch"]')], "test_health_fail_rolls_back_recorded_system"),
        ("rollback old revision health", "execute.py", [('require(health(config, result["old_hausnetz_rev"]),', 'require(True,')], "test_rollback_must_prove_old_revision"),
        ("wait for completed rollback", "orchestrate.py", [('or (result.get("phase") == "complete" and result.get("completed_at"))', 'or True')], "test_health_fail_rolls_back_recorded_system"),
        ("rollback Telegram", "execute.py", [('"auto-rollback" if result["rollback"]', '"wrong" if result["rollback"]')], "test_health_fail_rolls_back_recorded_system"),
        ("rollback failure alarms", "orchestrate.py", [("alarm(config, result)\n", "pass\n")], "test_rollback_failure_alarms_both_independent_paths"),
        ("host live enable gate", "execute.py", [('require(mode != "live" or config.get("allow_live") is True,', 'require(True,')], "test_live_disabled_on_host"),
        ("independent alert required", "orchestrate.py", [('require(config.get("secondary_telegram_command"),', 'require(True,')], "test_missing_independent_alert_refuses_live"),
        ("agent disabled default", "orchestrate.py", [('if config.get("enabled") is not True:', 'if False:')], "test_disabled_agent_has_no_effect"),
        ("build resource limit", "execute.py", [('"--max-jobs", "1", "--cores", "2"', '"--max-jobs", "4", "--cores", "8"')], "test_dry_run_success_and_limits"),
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
