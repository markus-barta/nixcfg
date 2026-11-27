"""Offline transactions and guard-removal mutants for OPS-705."""

import fcntl
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


REPO = Path(__file__).resolve().parents[1]
TEMP_ROOT = os.path.realpath("/tmp")


def mutant_source(name):
    if not re.fullmatch(r"t125-mutant-[A-Za-z0-9_-]+", name):
        raise ValueError("invalid mutant source")
    resolved = os.path.realpath(Path("/tmp") / name)
    if not resolved.startswith(TEMP_ROOT + os.sep):
        raise ValueError("unsafe mutant source")
    return Path(resolved)


SOURCE = REPO / "modules/hausnetz-cd"
# Mutants are selected only by a strict basename below a fixed temporary root.
mutant = os.environ.get("HAUSNETZ_CD_SOURCE")
if mutant is not None:
    SOURCE = mutant_source(mutant)
sys.path.insert(0, str(SOURCE))
from common import (Manual, EXECUTOR_BUDGET, POLL_BUDGET, POLL_INTERVAL, SSH_RETRY_TIMEOUT,
                    UNIT_RUNTIME_MAX, coordinate, gate_closures, gate_g1, gate_g2, gate_g4,
                    parse_export, prepare_result, strict_json)
from orchestrate import REMOTE, ledger, save_state, tick, validate_result
from execute import execute as execute_transaction, health


class Fixture:
    def __init__(self, root):
        root = root.resolve()
        self.root = root
        import common
        common.STATE_ROOT = str(root / "remote-state")
        self.env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        self.bin = root / "bin"
        self.bin.mkdir()
        self.env["PATH"] = str(self.bin) + os.pathsep + os.environ["PATH"]
        fake = SOURCE / "hausnetz-cd-command.py"
        if not fake.exists():
            fake = REPO / "tests/fixtures/hausnetz-cd-command.py"
        # Use this test interpreter rather than relying on an executable bit
        # or a Python selected by the developer's global PATH.
        for command in ("nix", "nix-store", "nix-env", "systemctl", "systemd-run", "curl", "ssh", "sudo",
                        "paimos", "acceptance", "bootctl", "alarm", "secondary-telegram", "switch-to-configuration", "readlink", "gh", "mbx"):
            target = self.bin / command
            target.write_text("#!" + sys.executable + "\n" + fake.read_text())
            target.chmod(0o700)
        self.auto_ack = True
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
        self.new_version = "261126165633.0.0"  # hsb0 r67 readiness capture
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
        self.write(root / "boot/grub/grub.cfg", 'set default="saved"\nmenuentry fixture {}\n')
        self.write(root / "boot/grub/grubenv", "saved_entry=fixture\n")
        self.credential = root / "fixture-credential"
        self.credential.write_text("123:fixture_token\n123\n")
        self.credential.chmod(0o600)
        (root / "deploy.lock").touch(mode=0o644)
        self.executor = {
            "allow_live": True, "fixture_root": True, "state_dir": str(root / "remote-state"),
            "lock_file": str(root / "deploy.lock"), "evidence_file": str(root / "evidence.json"),
            "nixcfg_url": str(self.repo), "current_system": str(root / "current-system"),
            "system_profile": str(root / "profile"), "store_pattern": str(root / "store") + r"/[^/]+",
            "package_pattern": str(root / "store") + r"/[0-9a-z]{32}-hausnetz-([^/]+)/bin/hausnetz",
            # OPS-705: generous windows so a loaded CI runner cannot turn the
            # expected outcome into an early 'manual' (#1326 flake: the ack
            # missed a 3 s window). Failure cases still end at the deadline;
            # the dedicated timeout tests set their own tiny values.
            "require_readyz": True, "health_timeout": 4, "boot_dir": str(root / "boot"),
            "backup_ack_timeout": 30, "telegram_file": str(self.credential),
        }
        self.orchestrator = {
            "enabled": True, "mode": "dry-run", "target": "mba@hsb0.lan",
            "release_ticket": "HNET-570", "nixcfg_url": str(self.repo), "hausnetz_url": str(self.hnet),
            "state_file": str(root / "local/state.json"), "fixture_root": True,
            "cache_dir": str(root / "cache"), "export_dir": str(root / "exports"),
            # OPS-705: passing runs return as soon as the executor finishes; 12 s no longer covered two 4 s health
            # timeouts (rollback-readiness cases) on loaded CI runners. Crash cases wait for this deadline, so it
            # must stay well below tick()'s subprocess timeout (36 s).
            "alarm_file": str(root / "local/alarm.json"), "poll_timeout": 24, "poll_interval": 0.02,
            "ssh_retry_timeout": 0.4,
            "acceptance_command": [str(self.bin / "acceptance"), "{trusted_rev}", "just", "acceptance",
                                   "{url}", "{version}", "{caps_sha256}"],
            "acceptance_url": "http://fixture.invalid", "acceptance_timeout": 2,
            "alarm_command": [str(self.bin / "alarm")],
            "secondary_telegram_command": [str(self.bin / "secondary-telegram")],
            "mailbox_remote_file": str(root / "mbx-remote"),
            "local_mailbox_command": str(self.bin / "mbx"),
        }
        self.write(root / "mbx-remote", "host=fixture-agents\nport=2222\nuser=agents\n")
        self.executor_path = root / "execute"
        # A separate test entrypoint supplies fixture settings; production
        # entrypoints have no config override via argv or environment.
        for target, module, settings in ((self.executor_path, "execute", "execute.json"),
                                         (root / "orchestrate", "orchestrate", "orchestrate.json")):
            target.write_text("#!" + sys.executable + "\n"
                              + "import sys\n"
                              + "sys.path.insert(0, " + repr(str(SOURCE)) + ")\n"
                              + "import common\ncommon.STATE_ROOT = " + repr(str(root / "remote-state")) + "\n"
                              + "import " + module + "\n"
                              + module + ".CONFIG_FILE = " + repr(str(root / settings)) + "\n"
                              + module + ".main()\n")
            target.chmod(0o700)
        self.orchestrator_path = root / "orchestrate"
        self.live_state = {
            "schema": "inspr.hausnetz-cd-state.v1", "last_deployed": None,
            "failed": [], "attempted": {}, "pending": None, "reports": {}, "sequence": 0,
            "attended_remaining": 0}
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
            "nar_hash": nar_hash, "manifest_sha": self.manifest_sha}))

    @property
    def key(self):
        return self.old_hnet + "-" + self.new_hnet

    def tick(self, mode=None, expect_ok=True, args=()):
        if mode:
            self.orchestrator["mode"] = mode
            if mode == "live" and not Path(self.orchestrator["state_file"]).exists():
                self.write(Path(self.orchestrator["state_file"]), json.dumps(self.live_state))
        self.save()
        result = subprocess.run([str(self.orchestrator_path), *args], env=self.env, capture_output=True,
                                text=True, timeout=36, check=False)
        if expect_ok and result.returncode:
            raise AssertionError(result.stderr)
        if self.auto_ack and self.orchestrator["mode"] == "live" and not args:
            state_path = Path(self.orchestrator["state_file"])
            pending = self.state().get("pending") if state_path.exists() else None
            if pending and pending.get("phase") == "awaiting_ack":
                self.write(state_path.parent / ("ack-live-" + pending["run_id"]), pending["run_id"])
                return self.tick(expect_ok=expect_ok)
        return result

    def execute(self, mode="dry-run", expect_ok=True, expected=None, version=None, manifest=None,
                running=None, token=None):
        self.save()
        self.run_id = token or "f" * 32
        result = subprocess.run([str(self.executor_path), self.new, expected or self.new_hnet, mode,
                                 version or self.new_version, manifest or self.manifest_sha,
                                 running or self.old, self.run_id],
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
        return max(state["reports"].values(), key=lambda entry: entry["order"])["result"]

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

    def test_production_entrypoints_reject_config_override(self):
        positional = [self.f.new, self.f.new_hnet, "dry-run", self.f.new_version,
                      self.f.manifest_sha, self.f.old, "f" * 32]
        for module, args in (("execute.py", positional), ("orchestrate.py", [])):
            with self.subTest(module=module):
                result = subprocess.run(
                    [sys.executable, "-B", str(SOURCE / module), *args,
                     "--config", str(self.f.root / "execute.json")],
                    capture_output=True, text=True, timeout=10, check=False)
                self.assertEqual(result.returncode, 2)
                self.assertTrue("unrecognized arguments: --config" in result.stderr
                                or "invalid choice:" in result.stderr, result.stderr)
        self.assertFalse(self.f.events())
        self.assertFalse(Path(self.f.executor["state_dir"]).exists())

    def test_state_path_refuses_traversal_prefix_siblings_and_symlinks(self):
        from common import state_path
        state = Path(self.f.executor["state_dir"])
        state.mkdir()
        (state / "escape").symlink_to(self.f.root)
        for path in (state / "../outside", Path(str(state) + "-other/file"),
                     state / "escape/outside"):
            with self.subTest(path=path), self.assertRaises(Manual) as caught:
                state_path(path)
            self.assertEqual(str(caught.exception), "unsafe_state_path")
        self.assertEqual(state_path(state / "results" / ("f" * 32 + ".json")),
                         state / "results" / ("f" * 32 + ".json"))

    def manual(self):
        self.f.tick()
        self.assertEqual(self.f.terminal()["status"], "manual")
        self.assertFalse(self.f.events("switch"))

    def test_dry_run_success_and_limits(self):
        self.f.tick()
        result = self.f.terminal()
        self.assertEqual(result["status"], "dry-run")
        self.assertEqual(result["gates"], {"G1": "pass", "G2": "controller_evidence",
                                          "G3": "pass", "G4": "controller_evidence", "G5": "pass"})
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
        self.assertEqual([e["recipient"] for e in self.f.events("mailbox")], ["mac-lead", "lead"])
        self.assertFalse(self.f.events("local-mailbox"))
        self.assertEqual(len(self.f.events("secondary-telegram")), 1)

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
        state = Path(self.f.executor["state_dir"])
        self.f.write(state / ("ack-live-" + "f" * 32), "f" * 32)
        self.f.write(state / ("acceptance-" + "f" * 32), "pass")
        self.f.execute("live")
        self.assertEqual(self.f.result()["status"], "manual")
        self.assertFalse(self.f.events("switch"))
        self.assertEqual(self.f.result()["reason"], "backup_copy_not_acknowledged")

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
        self.assertFalse(Path(self.f.orchestrator["alarm_file"]).exists())
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

    def test_missing_running_evidence_retries_silently(self):
        Path(self.f.executor["evidence_file"]).write_text('{}')
        self.f.tick()
        self.assertFalse(self.f.events("ticket"))
        self.assertFalse(self.f.events("start"))
        self.assertIn("pre_pair_failure", self.f.state())
        self.assert_no_delivery()

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
            if path == "flake.lock":
                # OPS-710: short values such as revCount 1789 also occur inside other
                # nodes' timestamps, so bump them only inside the hausnetz node.
                start = text.index('"hausnetz": {', text.index('"nodes": {'))
                depth, end = 0, start
                for end in range(text.index("{", start), len(text)):
                    depth += {"{": 1, "}": -1}.get(text[end], 0)
                    if depth == 0:
                        break
                block = text[start:end + 1]
                for before, after in replacements:
                    block = block.replace(before, after)
                text = text[:start] + block + text[end + 1:]
            else:
                # OPS-711: never replace a bare number across a whole document
                # (revCount 1800 also occurs in an unrelated RUNBOOK image tag).
                # The 40-hex rev and the narHash are unique; the integers only
                # change on T99's own assertion lines.
                for before, after in replacements[:2]:
                    text = text.replace(before, after)
                for key, (before, after) in zip(("lastModified", "revCount"), replacements[2:]):
                    text = re.sub(r"(\['" + key + r"'\] == )" + before + r"\b", r"\g<1>" + after, text)
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
        self.assertIn("evaluated", self.f.state())
        self.assert_no_delivery()

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
        self.assertFalse(Path(self.f.orchestrator["alarm_file"]).exists())
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
                                self.f.new_version, self.f.manifest_sha, self.f.old, self.f.run_id)
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

    def test_meta_manifest_mismatch_rolls_back(self):
        self.f.scenario["meta_manifest_mismatch"] = True
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["rollback"], "succeeded")

    def test_meta_manifest_missing_rolls_back(self):
        self.f.scenario["meta_manifest_missing"] = True
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["rollback"], "succeeded")

    def test_capabilities_body_mismatch_rolls_back(self):
        self.f.scenario["capabilities_mismatch"] = True
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["rollback"], "succeeded")

    def test_capabilities_endpoint_missing_rolls_back(self):
        self.f.scenario["capabilities_missing"] = True
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["rollback"], "succeeded")

    def test_rollback_capabilities_body_must_match_old_proof(self):
        self.f.scenario.update(health_fail=True, rollback_capabilities_mismatch=True)
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "rollback_failed")

    def test_captured_readyz_and_synthetic_capabilities_proof(self):
        # Readiness is captured; the capabilities body is synthetic fixture data.
        self.f.tick("live")
        result = self.f.terminal()
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(result["expected_version"], "261126165633.0.0")
        self.assertTrue(self.f.events("http"))
        urls = [event["url"] for event in self.f.events("http")]
        self.assertIn("http://127.0.0.1:8377/api/host-capabilities", urls)
        self.assertIn("http://127.0.0.1:8377/readyz", urls)
        self.assertEqual(result["changed_paths"], [])
        self.assertEqual(result["problems"], [])
        self.assertIn("changed_paths=[] problems=[]", self.f.events("ticket")[0]["text"])

    def test_rollback_manifest_must_match_old_proof(self):
        self.f.scenario.update(health_fail=True, rollback_manifest_mismatch=True)
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "rollback_failed")

    def test_readyz_version_mismatch_rolls_back(self):
        self.f.scenario["readyz"] = {"version": self.f.old_version}
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["rollback"], "succeeded")

    def test_readyz_check_false_rolls_back(self):
        self.f.scenario["readyz"] = {"checks": {"instance": True, "engine": True, "site": False, "ui": True}}
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["rollback"], "succeeded")

    def test_readyz_checks_fail_closed(self):
        # Exercise each required check plus missing, malformed, empty and extra checks.
        good = {"instance": True, "engine": True, "site": True, "ui": True}
        invalid = [{**good, key: False} for key in good]
        invalid += [{key: True for key in good if key != missing} for missing in good]
        invalid += [{}, [], None, {**good, "other": True}]
        for checks in invalid:
            with self.subTest(checks=checks), tempfile.TemporaryDirectory(prefix="t125-readyz-") as tmp:
                fixture = Fixture(Path(tmp))
                try:
                    fixture.scenario["readyz"] = {"checks": checks}
                    fixture.tick("live")
                    self.assertEqual(fixture.terminal()["rollback"], "succeeded")
                finally:
                    fixture.stop()

    def test_three_check_readyz_rolls_back(self):
        self.f.scenario["readyz"] = {"checks": {"engine": True, "site": True, "ui": True}}
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

    def test_prepare_usage_exit_is_manual(self):
        self.f.scenario["prepare_exit"] = 2
        self.manual()

    def test_prepare_other_exit_is_manual(self):
        self.f.scenario["prepare_exit"] = 17
        self.manual()

    def test_prepare_nonzero_records_problems(self):
        self.f.scenario.update(prepare_exit=2, prepare={"problems": ["bad_usage"], "version": "",
                                                      "changed_paths": ["state.json"]})
        self.manual()
        self.assertEqual(self.f.terminal()["problems"], ["bad_usage"])
        self.assertEqual(self.f.terminal()["reason"], "G2_prepare_exit_2")
        self.assertEqual(self.f.terminal()["changed_paths"], ["state.json"])
        self.assertIn('changed_paths=["state.json"] problems=["bad_usage"]', self.f.events("ticket")[0]["text"])

    def test_prepare_exact_command(self):
        self.f.tick()
        self.assertEqual(self.f.terminal()["status"], "dry-run")
        clone = str(Path(self.f.orchestrator["cache_dir"]) / "hausnetz")
        self.assertEqual(self.f.events("prepare")[0]["args"],
                         ["run", "--offline", "--no-write-lock-file", "git+file://" + clone + "?rev=" + self.f.old_hnet + "#cd-prepare", "--", "--repo", clone,
                          "--rev", self.f.new_hnet, "--running", self.f.old_hnet])
        self.assertEqual(self.f.events("prepare")[0]["checker_rev"], self.f.old_hnet)

    def test_executor_preserves_readable_lock_mode(self):
        lock = Path(self.f.executor["lock_file"])
        lock.chmod(0o444)
        self.f.execute()
        self.assertEqual(self.f.result()["status"], "dry-run")
        self.assertEqual(lock.stat().st_mode & 0o777, 0o444)
        self.assertEqual(lock.read_bytes(), b"")

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

    def test_prepare_missing_checker_rev_is_manual(self):
        self.f.scenario["prepare_omit"] = ["checker_rev"]
        self.manual()
        self.assertEqual(self.f.terminal()["reason"], "G2_prepare_schema")

    def test_prepare_unknown_field_is_manual(self):
        self.f.scenario["prepare"] = {"extra": True}
        self.manual()
        self.assertEqual(self.f.terminal()["reason"], "G2_prepare_schema")

    def test_prepare_no_diff_is_manual(self):
        self.f.scenario["prepare"] = {"changed_paths_total": -1}
        self.manual()

    def test_prepare_changed_paths_total_is_manual(self):
        self.f.scenario["prepare"] = {"changed_paths_total": 1}
        self.manual()

    def test_prepare_checker_rev_mismatch_is_manual(self):
        self.f.scenario["prepare"] = {"checker_rev": self.f.new_hnet}
        self.manual()

    def test_prepare_unsafe_diagnostics_are_retained(self):
        self.f.scenario["prepare"] = {"changed_paths": ["devices.json"], "changed_paths_total": 1,
                                      "problems": ["persisted_changed"]}
        self.manual()
        result = self.f.terminal()
        self.assertEqual(result["changed_paths"], ["devices.json"])
        self.assertEqual(result["problems"], ["persisted_changed"])
        self.assertIn('changed_paths=["devices.json"] problems=["persisted_changed"]', self.f.events("ticket")[0]["text"])

    def test_prepare_schema_and_coordinates_fail_closed(self):
        value = {"rev": self.f.new_hnet, "narHash": "hash", "version": self.f.new_version,
                 "persisted_ok": True, "manifest_changed": False,
                 "manifest_sha256": "a" * 64, "running_manifest_sha256": "a" * 64, "problems": [],
                 "checker_rev": self.f.old_hnet, "changed_paths": [], "changed_paths_total": 0}
        def check(candidate):
            return prepare_result(json.dumps(candidate), 0, self.f.new_hnet, "hash", self.f.old_hnet)
        self.assertEqual(check(value), value)
        for field, bad in (("version", "26.13.99"), ("manifest_sha256", "z" * 64),
                           ("running_manifest_sha256", "b" * 64), ("persisted_ok", 1),
                           ("manifest_changed", 0), ("problems", ""),
                           ("changed_paths_total", False), ("changed_paths_total", 0.0),
                           ("changed_paths_total", -2), ("changed_paths_total", "0"),
                           ("changed_paths", ""), ("changed_paths", [1]),
                           ("changed_paths", ["z", "a"]), ("changed_paths", ["a"] * 101)):
            with self.subTest(field=field), self.assertRaises(Manual):
                check({**value, field: bad})
        for field in value:
            with self.subTest(missing=field), self.assertRaises(Manual):
                check({key: item for key, item in value.items() if key != field})
        with self.assertRaises(Manual):
            check({**value, "extra": True})
        with self.assertRaises(Manual):
            check({**value, "manifest_sha256": "z" * 64, "running_manifest_sha256": "z" * 64})
        # The brief supplies only this captured prefix, not a complete digest.
        with self.assertRaises(Manual):
            check({**value, "manifest_sha256": "782631fc5c0bb9e9"})
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

    def test_lock_parse_errors_retry_silently(self):
        for text in ("{broken", "{}", '{"nodes":[],"root":"root"}'):
            self.f.advance("flake.lock", text)
            self.f.tick()
            self.f.tick()
            self.assertFalse(self.f.events("ticket"))
            self.assertFalse(self.f.events("start"))
            self.assertIn("pre_pair_failure", self.f.state())
            self.assert_no_delivery()

    def test_remote_rev_and_digest_regexes(self):
        Path(self.f.executor["state_dir"]).mkdir()
        def remote_script(action, rev, digest, *, expected=None, token=None, version=None, manifest=None, running=None):
            self.f.save()
            script = REMOTE.replace("/var/lib/hausnetz-cd", self.f.executor["state_dir"])
            script = script.replace("/run/current-system/sw/bin/hausnetz-cd-execute", str(self.f.executor_path))
            args = ["bash", "-s", "--", action, rev,
                    self.f.new_hnet if expected is None else expected, "dry-run", digest,
                    "a" * 32 if token is None else token,
                    self.f.new_version if version is None else version,
                    self.f.manifest_sha if manifest is None else manifest,
                    self.f.old if running is None else running]
            return subprocess.run(args, input=script, env=self.f.env, capture_output=True, text=True, check=False)
        for bad in ("a" * 39, "A" * 40, "a" * 40 + ";true", "../bad"):
            self.assertNotEqual(remote_script("start", bad, "").returncode, 0)
            self.assertNotEqual(remote_script("start", self.f.new, "", expected=bad).returncode, 0)
            self.assertNotEqual(remote_script("start", self.f.new, "", running=bad).returncode, 0)
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

    def test_g3_captured_pin_only_and_sgr_pass(self):
        fixtures = REPO / "tests/fixtures"
        raw = (fixtures / "hausnetz-diffclosures-r65-r66.bin").read_bytes()
        self.assertEqual(raw, "hausnetz: 261126120508.0.0 → 261126125422.0.0, 11.4 KiB\n".encode())
        colored = (fixtures / "hausnetz-diffclosures-r65-r66-sgr.bin").read_bytes()
        self.assertEqual(colored, raw.replace(b"11.4 KiB", b"\x1b[31;1m11.4 KiB\x1b[0m"))
        for data in (raw, colored):
            with self.subTest(data=data):
                try:
                    gate_closures(data.decode(), "old", "new")
                except Manual as exc:
                    self.fail("Captured pin-only output must pass: " + str(exc))
        # Empty/reset and multi-parameter SGR are permitted, too.
        gate_closures("\x1b[m\x1b[1;31m" + raw.decode() + "\x1b[0m", "old", "new")

    def test_g3_captured_secret_addition_fails(self):
        raw = (REPO / "tests/fixtures/hausnetz-diffclosures-r64-r65.bin").read_bytes()
        self.assertEqual(raw, ("hausnetz: 261123075451.0.0 → 261126120508.0.0, 453.0 KiB\n"
                               "hsb0-hausnetz-ha-token.age: ∅ → ε\n").encode())
        with self.assertRaises(Manual):
            gate_closures(raw.decode(), "old", "new")

    def test_g3_other_escapes_and_controls_fail(self):
        raw = (REPO / "tests/fixtures/hausnetz-diffclosures-r65-r66.bin").read_text()
        for control in ("\x1b[2K", "\x1b[1G", "\x1b[?25m", "\x1b]0;title\x07", "\x1b7",
                        "\x00", "\x07", "\t", "\r", "\x7f", "\x85", "\x9b31m"):
            with self.subTest(control=control), self.assertRaises(Manual):
                gate_closures(raw + control, "old", "new")

    def test_g3_control_bytes_are_not_normalized_away(self):
        raw = (REPO / "tests/fixtures/hausnetz-diffclosures-r65-r66.bin").read_bytes()
        self.f.scenario["closures"] = raw.decode() + "\r"
        self.manual()
        self.assertEqual(self.f.terminal()["reason"], "G3_escaped_closure_output")

    def assert_no_delivery(self):
        self.assertFalse(self.f.events("ticket"))
        self.assertFalse(self.f.events("start"))
        path = Path(self.f.orchestrator["state_file"])
        if path.exists():
            state = self.f.state()
            self.assertEqual(state["failed"], [])
            self.assertEqual(state["attempted"], {})
            self.assertEqual(state["reports"], {})
            self.assertIsNone(state["pending"])
        self.assertFalse(list((path.parent / "hausnetz-cd-ledger").rglob("*.json")))

    def test_unchanged_pin_and_evidence_ssh_failure_across_two_commits(self):
        self.f.pin(self.f.old_hnet, 3)
        self.f.scenario["ssh_fail"] = "evidence"
        for index in range(2):
            self.f.advance("unrelated.nix", str(index) + "\n")
            output = self.f.tick()
            self.assertIn("tick skipped", output.stdout)
            self.assert_no_delivery()
        self.f.scenario.pop("ssh_fail")
        self.f.tick()
        self.assert_no_delivery()

    def test_missing_old_source_retries_without_tombstone(self):
        path = Path(self.f.executor["evidence_file"])
        path.write_text(json.dumps({"schema": "inspr.pharos.nix-deployment-evidence.v1",
                                    "source_revision": "f" * 40}))
        for number in (3, 4):
            self.f.pin(self.f.new_hnet, number)
            self.f.new = self.f.commit(self.f.repo)
            self.f.tick()
            self.assert_no_delivery()
        path.write_text(json.dumps({"schema": "inspr.pharos.nix-deployment-evidence.v1",
                                    "source_revision": self.f.old}))
        self.f.tick()
        self.assertEqual(self.f.terminal()["status"], "dry-run")

    def test_source_cache_failure_is_local_only(self):
        with mock.patch("orchestrate.cache_repo", side_effect=Manual("command_failed")), \
                mock.patch("builtins.print") as log:
            tick(self.f.orchestrator)
            tick(self.f.orchestrator)
        self.assertEqual(log.call_count, 2)
        self.assert_no_delivery()

    def test_executor_rejects_changed_gated_baseline(self):
        # Both revs exist and G1 would pass against the actual old revision;
        # accepting it would change the baseline approved by the controller.
        self.f.execute(running=self.f.new)
        result = self.f.result()
        self.assertEqual(result["status"], "manual")
        self.assertEqual(result["reason"], "running_baseline_changed")
        self.assertFalse(self.f.events("nix"))

    def test_prepare_rejects_non_descendant_before_app(self):
        with mock.patch.dict(os.environ, self.f.env), self.assertRaises(Manual) as caught:
            gate_g2(self.f.hnet, self.f.new_hnet, self.f.old_hnet, "hash")
        self.assertEqual(str(caught.exception), "G2_non_descendant")
        self.assertFalse(self.f.events("prepare"))

    def test_duplicate_run_has_terminal_refusal_without_overwriting_original(self):
        self.f.run_id = "f" * 32
        path = Path(self.f.executor["state_dir"]) / "results" / (self.f.run_id + ".json")
        self.f.write(path, '{"status":"running","phase":"switch"}\n')
        original = path.read_bytes()
        self.assertNotEqual(self.f.execute(expect_ok=False).returncode, 0)
        refusal = json.loads((path.parent.parent / "refusals" / path.name).read_text())
        self.assertEqual(refusal["status"], "manual")
        self.assertEqual(refusal["reason"], "run_already_started")
        self.assertEqual(refusal["phase"], "complete")
        self.assertIsNotNone(refusal["completed_at"])
        self.assertEqual(path.read_bytes(), original)
        self.assertFalse(self.f.events("nix"))

    def test_revision_refusal_is_terminal_before_lock(self):
        attempt = Path(self.f.executor["state_dir"]) / "attempted" / (self.f.new + ".json")
        self.f.write(attempt, "{}\n")
        self.assertNotEqual(self.f.execute(expect_ok=False).returncode, 0)
        result = self.f.result()
        self.assertEqual((result["status"], result["phase"], result["reason"]),
                         ("manual", "complete", "revision_already_attempted"))
        self.assertIsNotNone(result["completed_at"])
        self.assertFalse(self.f.events("nix"))

    def test_revision_refusal_under_lock_is_terminal(self):
        self.f.run_id = "f" * 32
        attempt = Path(self.f.executor["state_dir"]) / "attempted" / (self.f.new + ".json")
        def raced(*_args):
            self.f.write(attempt, "{}\n")
        with mock.patch("execute.fcntl.flock", side_effect=raced), self.assertRaises(Manual):
            execute_transaction(self.f.executor, self.f.new, self.f.new_hnet, "dry-run",
                                self.f.new_version, self.f.manifest_sha, self.f.old, self.f.run_id)
        self.assertEqual(self.f.result()["status"], "manual")
        self.assertEqual(self.f.result()["reason"], "revision_already_attempted")
        self.assertIsNotNone(self.f.result()["completed_at"])

    def test_missing_deploy_lock_is_terminal_manual(self):
        Path(self.f.executor["lock_file"]).unlink()
        self.assertNotEqual(self.f.execute(expect_ok=False).returncode, 0)
        result = self.f.result()
        self.assertEqual((result["status"], result["phase"], result["reason"]),
                         ("manual", "complete", "deploy_lock_missing_or_unreadable"))
        self.assertIsNotNone(result["completed_at"])
        self.assertFalse(self.f.events("nix"))

    def test_gc_roots_protect_both_systems_through_g3_and_completion(self):
        self.f.execute()
        self.assertEqual(self.f.result()["status"], "dry-run")
        expected = {"old-system": str(self.f.old_system), "new-system": str(self.f.new_system)}
        self.assertEqual(self.f.events("dry-activate")[0]["roots"], expected)
        for name, target in expected.items():
            path = Path(self.f.executor["state_dir"]) / name
            self.assertTrue(path.is_symlink())
            self.assertEqual(str(path.resolve()), target)
        self.assertEqual(self.f.events("gc-root")[0]["target"], str(self.f.old_system))

    def test_ticket_attempts_cap_and_durable_local_outbox(self):
        self.f.scenario["ticket_fail"] = True
        outputs = [self.f.tick().stdout for _ in range(8)]
        entry = self.f.state()["reports"][self.f.key]
        self.assertEqual(entry["ticket_attempts"], 5)
        self.assertFalse(entry["ticket"])
        self.assertEqual(len(self.f.events("ticket")), 5)
        self.assertEqual(sum(text.count("ticket retries exhausted") for text in outputs), 1)
        outbox = ledger(self.f.orchestrator, "outbox", self.f.key)
        self.assertEqual(json.loads(outbox.read_text()), entry)
        self.f.scenario["ticket_fail"] = False
        self.f.tick()
        self.assertEqual(len(self.f.events("ticket")), 5)
        self.assertEqual(len(self.f.events("start")), 1)
        # Bounded summaries must not discard the exhausted local report.
        state = self.f.state()
        state["reports"].update({str(i): {"order": i + 10} for i in range(210)})
        save_state(self.f.orchestrator, state)
        self.assertNotIn(self.f.key, self.f.state()["reports"])
        self.assertEqual(json.loads(outbox.read_text()), entry)

    def test_readyz_truthy_nonbooleans_are_rejected(self):
        proof = {"exe": "/fixture/hausnetz", "version": self.f.new_version,
                 "manifest_sha256": self.f.manifest_sha}
        def process(executable, _args, **_kwargs):
            return proof["exe"] if executable == "readlink" else "123"
        for key in ("instance", "engine", "site", "ui"):
            for value in (1, "true", [True], {"ok": True}):
                checks = {"instance": True, "engine": True, "site": True, "ui": True, key: value}
                ready = {"ok": True, "version": proof["version"], "checks": checks}
                def response(url, _timeout):
                    if url.endswith("/api/host-capabilities"):
                        return (self.f.hnet / "capabilities.json").read_bytes()
                    return json.dumps(ready if url.endswith("/readyz") else {
                        "version": proof["version"], "capabilities_sha256": proof["manifest_sha256"]})
                with self.subTest(key=key, value=value), \
                        mock.patch("execute.run", side_effect=process), \
                        mock.patch("execute.http_get", side_effect=response):
                    self.assertFalse(health({"health_timeout": 0.05}, proof))

    def test_executor_labels_controller_evidence_and_preserves_values(self):
        self.f.tick()
        result = self.f.terminal()
        self.assertEqual(result["status"], "dry-run")
        self.assertEqual(result["gates"]["G2"], "controller_evidence")
        self.assertEqual(result["gates"]["G4"], "controller_evidence")
        expected = {"running_nixcfg_rev": self.f.old, "hausnetz_rev": self.f.new_hnet,
                    "version": self.f.new_version, "manifest_sha256": self.f.manifest_sha}
        self.assertEqual(result["controller_evidence"], expected)
        self.assertEqual(self.f.events("start")[0]["args"][-2], self.f.old)
        pending = {**result, "running_nixcfg_rev": self.f.old}
        # G5 belongs to the controller's merged report, not executor status.
        result = {**result, "gates": {key: value for key, value in result["gates"].items() if key != "G5"}}
        self.assertIs(validate_result(result, pending), result)
        for key in expected:
            changed = {**result, "controller_evidence": {**expected, key: "wrong"}}
            with self.subTest(key=key), self.assertRaises(Manual):
                validate_result(changed, pending)
        with self.assertRaises(Manual):
            validate_result({**result, "gates": {**result["gates"], "G2": "pass"}}, pending)


    def prepare_value(self):
        return {"rev": self.f.new_hnet, "narHash": "fixture", "version": self.f.new_version,
                "persisted_ok": True, "manifest_changed": False,
                "manifest_sha256": self.f.manifest_sha, "running_manifest_sha256": self.f.manifest_sha,
                "changed_paths": [], "changed_paths_total": 0, "checker_rev": self.f.old_hnet, "problems": []}

    def test_prepare_nonempty_paths_with_zero_total_is_manual(self):
        self.f.scenario["prepare"] = {"changed_paths": ["state.json"], "changed_paths_total": 0}
        self.manual()
        self.assertEqual(self.f.terminal()["reason"], "G2_prepare_unsafe")

    def test_schema_failure_diagnostics_are_bounded_at_all_boundaries(self):
        from orchestrate import alarm, log_line
        items = ["x" * 800 for _ in range(80)]
        self.f.scenario["prepare"] = {"changed_paths": items, "problems": items, "extra": True}
        self.manual()
        result = self.f.terminal()
        for name in ("changed_paths", "problems"):
            self.assertEqual(len(result[name]), 20)
            self.assertTrue(all(len(item) <= 200 for item in result[name]))
            self.assertEqual(result[name][-1], "+61 more")
        self.assertLess(len(self.f.events("ticket")[0]["text"]), 9000)
        raw = {**result, "mode": "live", "changed_paths": items, "problems": items}
        self.assertLess(len(log_line(raw)), 9000)
        with mock.patch.dict(os.environ, self.f.env):
            alarm(self.f.orchestrator, raw)
        saved = json.loads(Path(self.f.orchestrator["alarm_file"]).read_text())
        self.assertEqual(saved["result"]["changed_paths"], result["changed_paths"])
        self.assertLess(len(saved["message"]), 600)

    def test_checker_url_encodes_path_and_refuses_controls(self):
        from urllib.parse import parse_qs, unquote, urlsplit
        path = self.f.root / "cache ?#% ü" / "hausnetz"
        completed = subprocess.CompletedProcess([], 0, json.dumps(self.prepare_value()).encode(), b"")
        with mock.patch("common.git", return_value=""), mock.patch("common.subprocess.run", return_value=completed) as call:
            gate_g2(path, self.f.old_hnet, self.f.new_hnet, "fixture")
            url = next(a for a in call.call_args.args[0] if a.startswith("git+file://"))
            parsed = urlsplit(url)
            self.assertEqual(unquote(parsed.path), str(path))
            self.assertEqual(parse_qs(parsed.query), {"rev": [self.f.old_hnet]})
            self.assertEqual(parsed.fragment, "cd-prepare")
            self.assertNotIn(" ", url)
            for invalid in (Path("relative"), self.f.root / "bad\npath"):
                with self.subTest(path=invalid), self.assertRaises(Manual) as caught:
                    gate_g2(invalid, self.f.old_hnet, self.f.new_hnet, "fixture")
                self.assertEqual(str(caught.exception), "G2_checker_path")

    def test_hausnetz_fetch_failure_is_distinct_and_retryable(self):
        from common import cache_repo
        def fetch(*args, **kwargs):
            if kwargs.get("worktree"):
                raise Manual("command_failed")
            return cache_repo(*args, **kwargs)
        with mock.patch.dict(os.environ, self.f.env), mock.patch("orchestrate.cache_repo", side_effect=fetch):
            tick(self.f.orchestrator)
            tick(self.f.orchestrator)
        result = self.f.terminal()
        self.assertEqual(result["status"], "fetch_failed")
        self.assertEqual(result["reason"], "hausnetz_fetch_failed")
        self.assertEqual(result["gates"]["G1"], "pass")
        self.assertEqual(self.f.state()["failed"], [])
        self.assertEqual(self.f.state()["attempted"], {})
        self.assertFalse(list((Path(self.f.orchestrator["state_file"]).parent / "hausnetz-cd-ledger/failed").glob("*")))
        self.assertEqual(len(self.f.events("ticket")), 1)
        self.f.tick()
        self.assertEqual(self.f.terminal()["status"], "dry-run")
        self.assertEqual(len(self.f.events("start")), 1)

    def test_pre_pair_failure_alarms_once_after_six_hours_even_dry_run(self):
        with mock.patch.dict(os.environ, self.f.env), \
                mock.patch("orchestrate.cache_repo", side_effect=Manual("command_failed")), \
                mock.patch("orchestrate.time.time") as stamp:
            stamp.return_value = 1000
            tick(self.f.orchestrator)
            stamp.return_value = 1000 + 6 * 3600 - 1
            tick(self.f.orchestrator)
            self.assertFalse(Path(self.f.orchestrator["alarm_file"]).exists())
            self.assertFalse(self.f.events("mailbox"))
            stamp.return_value += 1
            tick(self.f.orchestrator)
            tick(self.f.orchestrator)
        self.assertEqual([e["recipient"] for e in self.f.events("mailbox")], ["mac-lead", "lead"])
        self.assertEqual(len(self.f.events("secondary-telegram")), 1)
        self.assertFalse(self.f.events("ticket"))
        self.assert_no_delivery()
        self.f.tick()
        self.assertNotIn("pre_pair_failure", self.f.state())

    def test_unchanged_tick_caches_evidence_until_thirty_minutes_or_main_moves(self):
        self.f.pin(self.f.old_hnet, 3)
        self.f.new = self.f.commit(self.f.repo)
        self.f.tick()
        self.f.tick()
        self.assertEqual(len([e for e in self.f.events("ssh") if e["action"] == "evidence"]), 1)
        state = self.f.state()
        self.assertEqual(state["evaluated"]["main"], self.f.new)
        self.assertEqual(state["evaluated"]["running"], self.f.old)
        state["evaluated"]["at"] -= 1801
        Path(self.f.orchestrator["state_file"]).write_text(json.dumps(state))
        self.f.tick()
        self.assertEqual(len([e for e in self.f.events("ssh") if e["action"] == "evidence"]), 2)
        self.f.advance("unrelated.nix", "a change\n")
        self.f.tick()
        self.assertEqual(len([e for e in self.f.events("ssh") if e["action"] == "evidence"]), 3)
        self.assert_no_delivery()

    def test_persistent_unpushed_running_main_rewrite_and_sudo_failures_alarm(self):
        from common import cache_repo
        for cause in ("unpushed", "main-rewrite", "sudo"):
            with self.subTest(cause=cause), tempfile.TemporaryDirectory(prefix="t125-preflight-") as tmp:
                fixture = Fixture(Path(tmp))
                try:
                    if cause == "unpushed":
                        Path(fixture.executor["evidence_file"]).write_text(json.dumps({
                            "schema": "inspr.pharos.nix-deployment-evidence.v1", "source_revision": "f" * 40}))
                    elif cause == "main-rewrite":
                        cache = Path(fixture.orchestrator["cache_dir"]) / "nixcfg.git"
                        cache.parent.mkdir(parents=True)
                        cache_repo(cache, fixture.orchestrator["nixcfg_url"])
                        fixture.git(fixture.repo, "update-ref", "refs/heads/main", fixture.old)
                    else:
                        fixture.scenario["sudo_fail"] = True
                    fixture.tick()
                    state = fixture.state()
                    self.assertFalse(fixture.events("mailbox"))
                    state["pre_pair_failure"]["since"] -= 6 * 3600 + 1
                    Path(fixture.orchestrator["state_file"]).write_text(json.dumps(state))
                    fixture.tick()
                    fixture.tick()
                    self.assertEqual(len(fixture.events("mailbox")), 2)
                    self.assertEqual(len(fixture.events("secondary-telegram")), 1)
                    self.assertFalse(fixture.events("start"))
                    self.assertEqual(fixture.state()["failed"], [])
                finally:
                    fixture.stop()

    def test_unsubstituted_entrypoints_refuse_existing_placeholder_file(self):
        import execute as executor
        import orchestrate as controller
        for module, args in (("orchestrate.py", []), ("execute.py", [self.f.new, self.f.new_hnet, "dry-run",
                             self.f.new_version, self.f.manifest_sha, self.f.old, "f" * 32])):
            with self.subTest(module=module):
                settings = self.f.orchestrator if module == "orchestrate.py" else self.f.executor
                self.f.write(self.f.root / "@CONFIG@", json.dumps(settings))
                result = subprocess.run([sys.executable, "-B", str(SOURCE / module), *args],
                                        cwd=self.f.root, env=self.f.env, capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                entrypoint = controller if module == "orchestrate.py" else executor
                action = "tick" if module == "orchestrate.py" else "execute"
                with mock.patch.object(entrypoint, "CONFIG_FILE", "@CONFIG@"), \
                        mock.patch.object(sys, "argv", [module, *args]), \
                        mock.patch.object(Path, "read_bytes", return_value=json.dumps(settings).encode()) as read, \
                        mock.patch.object(entrypoint, action) as transaction:
                    with self.assertRaises(SystemExit):
                        entrypoint.main()
                    read.assert_not_called()
                    transaction.assert_not_called()
        self.assertFalse(self.f.events())

    def test_sudo_fixture_resolves_utilities_from_path(self):
        utility = self.f.bin / "cat"
        utility.write_text("#!" + sys.executable + "\nprint('PATH-resolved-cat')\n")
        utility.chmod(0o700)
        result = subprocess.run([str(self.f.bin / "sudo"), "-n", "cat", str(self.f.root / "evidence.json")],
                                env=self.f.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "PATH-resolved-cat\n")

    def test_vm_test_requires_latest_exact_revision_success(self):
        from orchestrate import vm_test
        good = {"id": 1, "head_sha": self.f.new_hnet, "status": "completed", "conclusion": "success"}
        bad = [{"workflow_runs": []}, {"workflow_runs": [{**good, "head_sha": self.f.old_hnet}]},
               {"workflow_runs": [{**good, "status": "in_progress", "conclusion": None}]},
               {"workflow_runs": [{**good, "conclusion": "failure"}]},
               {"workflow_runs": [good, {**good, "id": 2, "status": "queued"}]}, {}, {"workflow_runs": None}]
        for response in bad:
            with self.subTest(response=response), mock.patch("orchestrate.run", return_value=json.dumps(response)):
                self.assertEqual(vm_test(self.f.new_hnet)[0], "manual")
        with mock.patch("orchestrate.run", side_effect=Manual("command_failed")):
            self.assertEqual(vm_test(self.f.new_hnet)[0], "manual")
        with mock.patch("orchestrate.run", return_value=json.dumps({"workflow_runs": [good]})) as call:
            self.assertEqual(vm_test(self.f.new_hnet)[0], "pass")
            self.assertIn("vm-test.yml/runs?head_sha=" + self.f.new_hnet, call.call_args.args[1][-1])

    def test_vm_test_error_blocks_live_before_executor(self):
        self.f.scenario["vm_test_error"] = True
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["gates"]["G5"], "manual")
        self.assertFalse(self.f.events("start"))
        self.assertFalse(self.f.events("switch"))

    def test_vm_test_error_is_recorded_but_dry_run_completes(self):
        self.f.scenario["vm_test_error"] = True
        self.f.tick()
        self.assertEqual(self.f.terminal()["status"], "dry-run")
        self.assertEqual(self.f.terminal()["gates"]["G5"], "manual")
        self.assertIn("G5:manual", self.f.events("ticket")[0]["text"])

    def test_mailbox_failure_does_not_suppress_other_alarm_paths(self):
        from orchestrate import alarm
        self.f.scenario["mailbox_fail"] = "mac-lead"
        self.f.save()
        with mock.patch.dict(os.environ, self.f.env):
            alarm(self.f.orchestrator, {"mode": "live", "nixcfg_rev": self.f.new,
                  "hausnetz_rev": self.f.new_hnet, "reason": "rollback_failed"})
        self.assertEqual(len(self.f.events("mailbox")), 2)
        self.assertEqual([e["recipient"] for e in self.f.events("local-mailbox")], ["mac-lead", "lead"])
        self.assertEqual(len(self.f.events("secondary-telegram")), 1)

    def alarm_cli(self):
        # No live switch or production command is reachable: all commands are PATH fakes.
        self.f.orchestrator.update(enabled=False, mode="dry-run")
        return self.f.tick(args=("--test-alarm",))

    def assert_alarm_chain(self, *, remote=True, fallback=False):
        expected = ["mac-lead", "lead"]
        self.assertEqual([e["recipient"] for e in self.f.events("mailbox")], expected if remote else [])
        self.assertEqual([e["recipient"] for e in self.f.events("local-mailbox")], expected if fallback else [])
        self.assertEqual(len(self.f.events("secondary-telegram")), 1)
        messages = [e["text"] for e in self.f.events()
                    if e["kind"] in {"mailbox", "local-mailbox", "secondary-telegram", "alarm"}]
        self.assertTrue(messages)
        self.assertEqual(len(set(messages)), 1)
        self.assertTrue(messages[0].startswith("TEST (no action): "))  # LEAD 2026-11-27: Markus must not be alarmed

    def test_test_alarm_remote_success_without_fallback(self):
        self.alarm_cli()
        self.assert_alarm_chain()
        self.assertFalse(self.f.events("ssh"))
        self.assertFalse(self.f.events("ticket"))
        self.assertFalse(Path(self.f.orchestrator["alarm_file"]).exists())

    def test_test_alarm_missing_file_falls_back_to_both_local_mailboxes(self):
        self.f.orchestrator["mailbox_remote_file"] = str(self.f.root / "absent")
        result = self.alarm_cli()
        self.assert_alarm_chain(remote=False, fallback=True)
        self.assertIn("remote mailbox file missing/invalid", result.stderr)

    def test_test_alarm_invalid_file_falls_back_to_both_local_mailboxes(self):
        Path(self.f.orchestrator["mailbox_remote_file"]).write_text(
            "host=fixture-agents\nport=2222\nuser=agents\njunk=true\n")
        result = self.alarm_cli()
        self.assert_alarm_chain(remote=False, fallback=True)
        self.assertIn("remote mailbox file missing/invalid", result.stderr)

    def test_either_remote_recipient_failure_falls_back_without_duplicate_csb1(self):
        for recipient in ("mac-lead", "lead"):
            with self.subTest(recipient=recipient), tempfile.TemporaryDirectory(prefix="t125-alarm-") as root:
                fixture = Fixture(Path(root))
                fixture.scenario["mailbox_fail"] = recipient
                fixture.orchestrator["enabled"] = False
                result = fixture.tick(args=("--test-alarm",))
                self.assertEqual([e["recipient"] for e in fixture.events("mailbox")], ["mac-lead", "lead"])
                self.assertEqual([e["recipient"] for e in fixture.events("local-mailbox")], ["mac-lead", "lead"])
                self.assertEqual(len(fixture.events("secondary-telegram")), 1)
                self.assertIn("remote mailbox " + recipient, result.stderr)

    def test_csb1_failure_is_logged_after_mailbox_fallback(self):
        self.f.orchestrator["mailbox_remote_file"] = str(self.f.root / "absent")
        self.f.scenario["secondary_telegram_fail"] = True
        result = self.alarm_cli()
        self.assert_alarm_chain(remote=False, fallback=True)
        self.assertIn("alarm route failed: csb1 Telegram", result.stderr)

    def test_local_mailbox_failure_does_not_suppress_other_recipient_or_csb1(self):
        self.f.orchestrator["mailbox_remote_file"] = str(self.f.root / "absent")
        self.f.scenario["local_mailbox_fail"] = "mac-lead"
        result = self.alarm_cli()
        self.assert_alarm_chain(remote=False, fallback=True)
        self.assertIn("local mailbox mac-lead", result.stderr)

    def test_mailbox_target_strictly_rejects_junk(self):
        from orchestrate import mailbox_target
        path = self.f.root / "mbx-remote"
        valid = "host=fixture-agents\nport=2222\nuser=agents\n"
        junk = [valid + "extra=yes\n", valid + "\n", valid.replace("host=", " host="),
                valid.replace("user=", "host="), valid.replace("user=", "username="),
                valid.replace("2222", "0"), valid.replace("2222", "65536"),
                valid.replace("2222", "+22"), valid.replace("2222", "22 "),
                valid.replace("2222", "2_2"), valid.replace("agents\n", "Agents\n"),
                valid.replace("user=agents", "user=agents;id"), valid.replace("user=agents", "user="),
                valid.replace("fixture-agents", "-option"), valid.replace("fixture-agents", "a/b"),
                valid.replace("fixture-agents", "a b"), valid.replace("fixture-agents", "a;id"),
                valid.replace("fixture-agents", "$(id)"), valid.replace("fixture-agents", "a_underscore"),
                valid.replace("fixture-agents", "fe80::1%scope"), valid.replace("\n", "\r\n"),
                "host=a\nport=22\n", "\xff", "x" * 4097]
        for value in junk:
            with self.subTest(value=value):
                path.write_bytes(value.encode("latin1"))
                with self.assertRaises((Manual, UnicodeError)):
                    mailbox_target(path)

    def test_mailbox_target_accepts_hostnames_ipv4_ipv6_and_port_boundaries(self):
        from orchestrate import mailbox_target
        path = self.f.root / "mbx-remote"
        for host in ("fixture-agents", "mbx.example.test", "192.0.2.1", "2001:db8::1", "::1"):
            for port in (1, 65535):
                with self.subTest(host=host, port=port):
                    path.write_text(f"user=_agents-1\nhost={host}\nport={port}")
                    self.assertEqual(mailbox_target(path), (host, port, "_agents-1"))

    def test_test_alarm_leaves_existing_state_and_deploy_paths_untouched(self):
        state = Path(self.f.orchestrator["state_file"])
        alarm_file = Path(self.f.orchestrator["alarm_file"])
        self.f.write(state, 'existing state: do not parse or change\n')
        self.f.write(alarm_file, 'previous alarm\n')
        before = {path: (path.read_bytes(), path.stat().st_mtime_ns, path.stat().st_mode)
                  for path in (state, alarm_file, self.f.root / "evidence.json", self.f.root / "deploy.lock")}
        self.alarm_cli()
        self.assert_alarm_chain()
        for path, snapshot in before.items():
            self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns, path.stat().st_mode), snapshot)
        self.assertEqual(Path(self.f.executor["current_system"]).resolve(), self.f.old_system)
        self.assertFalse((self.f.root / "remote-state").exists())
        self.assertFalse((self.f.root / "cache").exists())
        self.assertFalse((self.f.root / "exports").exists())
        self.assertEqual({e["kind"] for e in self.f.events()}, {"mailbox", "alarm", "secondary-telegram"})

    def test_test_alarm_does_not_create_state_or_deploy_directories(self):
        self.alarm_cli()
        self.assertFalse(Path(self.f.orchestrator["state_file"]).parent.exists())
        self.assertFalse((self.f.root / "cache").exists())
        self.assertFalse((self.f.root / "remote-state").exists())

    def test_test_alarm_is_explicit_and_rejects_deployment_flags(self):
        self.f.orchestrator["enabled"] = False
        self.f.tick()
        self.assertFalse(self.f.events())
        for args in (("--test-alarm", "--once", "--dry-run"), ("--test-alarm", "--dry-run"),
                     ("--test-alarm", "--once"), ("--test-alarm", "--live"), ("--test",)):
            self.assertNotEqual(self.f.tick(args=args, expect_ok=False).returncode, 0)
        self.assertFalse(self.f.events())

    def test_preflight_missing_mailbox_file_uses_full_fallback_once(self):
        self.f.orchestrator["mailbox_remote_file"] = str(self.f.root / "absent")
        with mock.patch.dict(os.environ, self.f.env), \
                mock.patch("orchestrate.cache_repo", side_effect=Manual("command_failed")), \
                mock.patch("orchestrate.time.time", return_value=1000) as stamp, \
                mock.patch("sys.stderr") as log:
            tick(self.f.orchestrator)
            stamp.return_value += 6 * 3600
            tick(self.f.orchestrator)
            tick(self.f.orchestrator)
        self.assertFalse(self.f.events("mailbox"))
        self.assertEqual([e["recipient"] for e in self.f.events("local-mailbox")], ["mac-lead", "lead"])
        self.assertEqual(len(self.f.events("secondary-telegram")), 1)
        self.assertIn("CD PREFLIGHT UNAVAILABLE", self.f.events("secondary-telegram")[0]["text"])
        self.assertIn("remote mailbox file missing/invalid", str(log.write.call_args_list))

    def test_rollback_failure_missing_mailbox_file_falls_back_once(self):
        self.f.orchestrator["mailbox_remote_file"] = str(self.f.root / "absent")
        self.f.scenario.update(health_fail=True, rollback_fail=True)
        output = self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "rollback_failed")
        self.assertFalse(self.f.events("mailbox"))
        self.assertEqual([e["recipient"] for e in self.f.events("local-mailbox")], ["mac-lead", "lead"])
        self.assertEqual(len(self.f.events("secondary-telegram")), 1)
        self.assertIn("remote mailbox file missing/invalid", output.stderr)
        self.f.tick("live")
        self.assertEqual(len(self.f.events("secondary-telegram")), 1)
        self.assertEqual(len(self.f.events("local-mailbox")), 2)

    def test_dry_run_never_alarms_on_executor_failure(self):
        self.f.scenario["crash"] = True
        self.f.tick()
        self.assertFalse(Path(self.f.orchestrator["alarm_file"]).exists())
        self.assertFalse(self.f.events("mailbox"))
        self.assertFalse(self.f.events("secondary-telegram"))

    def test_dry_run_measures_memory_peak_into_status_and_ticket(self):
        self.f.tick()
        self.assertEqual(self.f.terminal()["memory_peak_bytes"], 536870912)
        token = self.f.terminal()["run_id"]
        self.assertEqual(self.f.events("memory-peak")[0]["unit"], "hausnetz-cd-" + token + ".service")
        self.assertIn("memory_peak_bytes=536870912", self.f.events("ticket")[0]["text"])
        self.assertIn("--property=MemoryAccounting=yes", self.f.events("start")[0]["args"])
        events = self.f.events()
        self.assertLess(next(i for i, e in enumerate(events) if e["kind"] == "dry-activate"),
                        next(i for i, e in enumerate(events) if e["kind"] == "memory-peak"))

    def test_memory_peak_unavailable_is_explicit_without_blocking_dry_run(self):
        self.f.scenario["memory_peak"] = "[not set]"
        self.f.tick()
        self.assertEqual(self.f.terminal()["status"], "dry-run")
        self.assertIsNone(self.f.terminal()["memory_peak_bytes"])
        self.assertEqual(self.f.terminal()["memory_peak_reason"], "systemd_memory_peak_unavailable")

    def test_disabled_once_dry_run_runs_full_chain_and_forces_mode(self):
        self.f.orchestrator.update(enabled=False, mode="live")
        self.f.tick(args=("--once", "--dry-run"))
        self.assertIsNone(self.f.state()["pending"], "manual dry-run must not await live acknowledgement")
        result = self.f.terminal()
        self.assertEqual(result["status"], "dry-run")
        self.assertEqual(result["mode"], "dry-run")
        self.assertEqual(result["gates"]["G1"], "pass")
        self.assertEqual(result["gates"]["G3"], "pass")
        self.assertTrue(self.f.events("prepare"))
        self.assertTrue(self.f.events("start"))
        self.assertTrue(self.f.events("ticket"))
        self.assertFalse(self.f.events("http"))
        self.assertFalse(self.f.events("switch"))
        self.assertFalse(self.f.events("telegram"))
        self.assertFalse(self.f.events("mailbox"))

    def test_once_requires_both_flags_and_refuses_live_pending(self):
        for args in (("--once",), ("--dry-run",), ("--once", "--live")):
            with self.subTest(args=args):
                self.assertNotEqual(self.f.tick(args=args, expect_ok=False).returncode, 0)
        state = {"schema": "inspr.hausnetz-cd-state.v1", "attempted": {}, "failed": [], "reports": {},
                 "pending": {"mode": "live", "nixcfg_rev": self.f.new, "hausnetz_rev": self.f.new_hnet,
                             "run_id": "f" * 32, "run_key": self.f.key, "deadline": time.time() + 0.2}, "sequence": 0}
        self.f.write(Path(self.f.orchestrator["state_file"]), json.dumps(state))
        self.assertNotEqual(self.f.tick(args=("--once", "--dry-run"), expect_ok=False).returncode, 0)
        self.assertFalse(self.f.events())


    def rehearsal(self, variant="A"):
        self.f.orchestrator["enabled"] = False
        self.f.executor["health_timeout"] = 2
        self.f.scenario["activation"] = "would activate the configuration..."
        self.f.tick(args=("rehearse", "--variant", variant))
        return self.f.terminal()

    def test_rehearsal_a_real_switch_and_rollback_without_changes(self):
        result = self.rehearsal()
        self.assertEqual(result["status"], "rolled_back", result)
        self.assertEqual(result["rollback_health"], "pass")
        self.assertEqual(result["new_proof"]["revision"], self.f.old_hnet)
        self.assertNotEqual(result["new_proof"]["expected_revision"], self.f.old_hnet)
        self.assertEqual(result["old_proof"]["expected_revision"], self.f.old_hnet)
        self.assertEqual(result["readback_before"], result["readback_after_switch"])
        self.assertEqual(result["readback_before"], result["readback_after"])
        self.assertEqual([e["target"] for e in self.f.events("switch")], [str(self.f.old_system)] * 2)
        self.assertFalse(self.f.events("profile"))
        self.assertFalse(self.f.events("nix"))
        self.assertFalse(self.f.events("acceptance"))
        self.assertEqual(len(self.f.events("telegram")), 1)
        self.assertTrue(self.f.events("telegram")[0]["text"].startswith("TEST (no action): "))
        self.assertFalse(self.f.events("mailbox"))
        self.assertFalse(self.f.events("secondary-telegram"))
        self.assertNotIn("disabled", self.f.state())
        self.assertFalse(list(Path(self.f.executor["state_dir"]).glob("rehearsal-token-*")))

    def test_rehearsal_b_exact_alarm_counts_and_latch(self):
        result = self.rehearsal("B")
        self.assertEqual(result["status"], "rollback_failed", result)
        self.assertNotEqual(result["old_proof"]["expected_revision"], self.f.old_hnet)
        self.assertEqual(result["readback_before"], result["readback_after"])
        self.assertEqual(len(self.f.events("switch")), 2)
        for kind, count in (("telegram", 1), ("secondary-telegram", 1), ("mailbox", 2)):
            self.assertEqual(len(self.f.events(kind)), count)
            self.assertTrue(all(e["text"].startswith("TEST (no action): ") for e in self.f.events(kind)))
        self.assertTrue(self.f.state()["disabled"])
        self.assertTrue(Path(self.f.orchestrator["alarm_file"]).exists())
        events = self.f.events()
        self.f.tick(args=("--once", "--dry-run"))
        self.assertEqual(self.f.events(), events)
        self.assertTrue(self.f.state()["disabled"])

    def test_rehearsal_b_fallback_uses_normal_chain_once(self):
        Path(self.f.orchestrator["mailbox_remote_file"]).unlink()
        self.assertEqual(self.rehearsal("B")["status"], "rollback_failed")
        self.assertEqual(len(self.f.events("telegram")), 1)
        self.assertEqual(len(self.f.events("secondary-telegram")), 1)
        self.assertEqual(len(self.f.events("local-mailbox")), 2)
        self.assertTrue(all(e["text"].startswith("TEST (no action): ") for e in self.f.events("local-mailbox")))

    def test_rehearsal_refuses_missing_token_and_real_target(self):
        self.f.save()
        args = ("rehearse", "--variant", "A", "--token", "a" * 32, "--run-id", "b" * 32)
        subprocess.run([str(self.f.executor_path), *args], env=self.f.env, capture_output=True, timeout=10)
        path = Path(self.f.executor["state_dir"]) / "results" / ("b" * 32 + ".json")
        self.assertEqual(json.loads(path.read_text())["status"], "rehearsal_aborted")
        self.assertFalse(self.f.events("switch"))
        for extra in ((self.f.new,), ("--nixcfg-rev", self.f.new)):
            result = subprocess.run([str(self.f.executor_path), *args, *extra], env=self.f.env,
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 2)
        self.assertFalse(self.f.events("switch"))

    def test_rehearsal_refuses_nonempty_activation(self):
        self.f.executor["health_timeout"] = 2
        self.f.tick(args=("rehearse", "--variant", "A"))
        self.assertEqual(self.f.terminal()["status"], "rehearsal_aborted")
        self.assertFalse(self.f.events("switch"))
        self.assertTrue(all(e["text"].startswith("TEST (no action): ") for e in self.f.events("mailbox")))

    def test_rehearsal_aborts_on_service_generation_or_boot_change(self):
        for scenario in ("rehearsal_restart", "rehearsal_generation", "rehearsal_boot_change"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory(prefix="t125-rehearsal-") as tmp:
                fixture = Fixture(Path(tmp))
                try:
                    fixture.executor["health_timeout"] = 2
                    fixture.scenario.update(activation="would activate the configuration...")
                    fixture.scenario[scenario] = True
                    fixture.tick(args=("rehearse", "--variant", "A"))
                    self.assertEqual(fixture.terminal()["status"], "rehearsal_aborted")
                    self.assertEqual(len(fixture.events("switch")), 1)
                    self.assertEqual(len(fixture.events("secondary-telegram")), 1)
                finally:
                    fixture.stop()

    def test_rehearsal_rechecks_empty_activation_before_rollback(self):
        self.f.scenario["rehearsal_rollback_units"] = True
        result = self.rehearsal()
        self.assertEqual(result["status"], "rehearsal_aborted")
        self.assertEqual(result["reason"], "rehearsal_activation_not_empty")
        self.assertEqual(len(self.f.events("switch")), 1)

    def test_rehearsal_boot_readback_requires_default_and_entries(self):
        from execute import rehearsal_readback
        def response(_command, args):
            if "--list-generations" in args:
                return "1 fixture generation"
            return "a" * 32 if "--property=InvocationID" in args else "123"
        config = self.f.executor
        with mock.patch("execute.run", side_effect=response):
            before = rehearsal_readback(config)
            self.assertEqual(before["boot_default"]["assignments"], ['"saved"'])
            self.assertEqual(before["boot_default"]["environment"], ["saved_entry=fixture"])
            for text in ("", "set default=0\n", "menuentry fixture {}\n"):
                self.f.write(self.f.root / "boot/grub/grub.cfg", text)
                with self.subTest(text=text), self.assertRaises(Manual):
                    rehearsal_readback(config)

    def test_rehearsal_holds_shared_lock(self):
        with open(self.f.executor["lock_file"]) as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.f.tick(args=("rehearse", "--variant", "A"))
        self.assertFalse(self.f.events("switch"))
        self.assertIsNone(self.f.state()["pending"])

    def test_latch_blocks_timer_and_once_and_never_clears_itself(self):
        state = {**self.f.live_state, "disabled": {"at": "fixture", "alarmed": False}}
        self.f.write(Path(self.f.orchestrator["state_file"]), json.dumps(state))
        for args in ((), (), ("--once", "--dry-run")):
            self.f.tick(args=args)
            self.assertIn("disabled", self.f.state())
            self.assertTrue(self.f.state()["disabled"])
        self.assertFalse(self.f.events("ssh"))
        self.assertEqual(len(self.f.events("mailbox")), 2)
        self.assertEqual(len(self.f.events("secondary-telegram")), 1)

    def test_latch_written_on_first_real_rollback_failure(self):
        self.f.scenario.update(health_fail=True, rollback_fail=True)
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "rollback_failed")
        self.assertIn("disabled", self.f.state())
        self.assertTrue(self.f.state()["disabled"])
        before = self.f.events()
        self.f.tick()
        self.assertEqual(self.f.events(), before)

    def test_latch_recovers_unsent_failure_alarm_after_controller_crash(self):
        from orchestrate import finish
        result = {"schema": "inspr.pharos.guarded-deploy-result.v1", "status": "rollback_failed",
                  "mode": "live", "nixcfg_rev": self.f.new, "hausnetz_rev": self.f.new_hnet,
                  "run_key": self.f.key, "run_id": "c" * 32}
        with mock.patch("orchestrate.report", side_effect=RuntimeError("crash")), self.assertRaises(RuntimeError):
            finish(self.f.orchestrator, self.f.live_state, result)
        self.assertIn("disabled", self.f.state())
        self.assertFalse(self.f.state()["disabled"]["alarmed"])
        self.f.tick()
        self.assertTrue(self.f.state()["disabled"]["alarmed"])
        self.assertEqual(len(self.f.events("mailbox")), 2)
        self.assertEqual(len(self.f.events("secondary-telegram")), 1)
        self.assertIn("ROLLBACK FAILED", self.f.events("mailbox")[0]["text"])
        before = self.f.events()
        self.f.tick()
        self.assertEqual(self.f.events(), before)
        self.assertFalse(self.f.events("start"))

    def test_clear_disable_requires_reason_and_preserves_history(self):
        state = {**self.f.live_state, "disabled": {"alarmed": True}, "failed": [self.f.new_hnet]}
        self.f.write(Path(self.f.orchestrator["state_file"]), json.dumps(state))
        for args in (("--clear-disable",), ("--clear-disable", "--reason", " "),
                     ("--clear-disable", "--reason", "reviewed", "--once", "--dry-run")):
            self.assertEqual(self.f.tick(args=args, expect_ok=False).returncode, 2)
        self.f.tick(args=("--clear-disable", "--reason", "operator inspected recovery"))
        self.assertNotIn("disabled", self.f.state())
        self.assertEqual(self.f.state()["failed"], [self.f.new_hnet])
        self.assertEqual(self.f.state()["disable_cleared"]["reason"], "operator inspected recovery")
        self.assertFalse(self.f.events())

    def attended_setup(self):
        self.f.live_state.pop("attended_remaining", None)
        self.f.auto_ack = False

    def test_attended_counter_initializes_three_and_no_ack_no_switch(self):
        self.attended_setup()
        self.f.tick("live")
        pending = self.f.state()["pending"]
        self.assertEqual(self.f.state()["attended_remaining"], 3)
        self.assertEqual(pending["phase"], "awaiting_ack")
        self.f.tick()
        self.assertFalse(self.f.events("start"))
        self.assertFalse(self.f.events("switch"))
        self.assertEqual(len(self.f.events("mailbox")), 2)
        self.assertIn("awaiting attended ack", self.f.events("mailbox")[0]["text"])

    def test_attended_ack_timeout_leaves_release_manual(self):
        self.attended_setup()
        self.f.tick("live")
        state = self.f.state()
        state["pending"]["ack_deadline"] = 0
        self.f.write(Path(self.f.orchestrator["state_file"]), json.dumps(state))
        self.f.tick()
        self.assertEqual(self.f.terminal()["status"], "ack_timeout")
        self.assertEqual(self.f.state()["attended_remaining"], 3)
        self.f.tick()
        self.assertFalse(self.f.events("start"))
        self.assertFalse(self.f.events("switch"))
        self.assertEqual(len(self.f.events("mailbox")), 4)
        self.assertIn("ack timeout, release left manual", self.f.events("mailbox")[-1]["text"])

    def test_attended_ack_is_run_scoped_and_counter_decrements_on_success(self):
        self.attended_setup()
        self.f.tick("live")
        pending = self.f.state()["pending"]
        root = Path(self.f.orchestrator["state_file"]).parent
        self.f.write(root / ("ack-live-" + pending["run_id"]), "wrong token")
        self.f.tick()
        self.assertFalse(self.f.events("switch"))
        self.f.write(root / ("ack-live-" + pending["run_id"]), pending["run_id"])
        self.f.tick()
        self.assertEqual(self.f.terminal()["status"], "succeeded")
        self.assertEqual(self.f.state()["attended_remaining"], 2)
        self.assertEqual(len(self.f.events("switch")), 1)

    def test_attended_timely_file_survives_next_tick_after_deadline(self):
        self.attended_setup()
        self.f.tick("live")
        state = self.f.state()
        pending = state["pending"]
        ack = Path(self.f.orchestrator["state_file"]).parent / ("ack-live-" + pending["run_id"])
        self.f.write(ack, pending["run_id"])
        written = ack.stat().st_mtime
        pending["ack_deadline"] = written + 0.01
        self.f.write(Path(self.f.orchestrator["state_file"]), json.dumps(state))
        time.sleep(0.02)
        self.f.tick()
        self.assertEqual(self.f.terminal()["status"], "succeeded")
        self.assertEqual(self.f.state()["attended_remaining"], 2)

    def test_attended_failure_does_not_decrement(self):
        self.attended_setup()
        self.f.auto_ack = True
        self.f.scenario["health_fail"] = True
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["rollback"], "succeeded")
        self.assertEqual(self.f.state()["attended_remaining"], 3)

    def test_executor_live_without_ack_refuses(self):
        self.f.execute(mode="live")
        self.assertEqual(self.f.result()["status"], "manual")
        self.assertEqual(self.f.result()["reason"], "attended_ack_missing")
        self.assertFalse(self.f.events("switch"))

    def test_acceptance_green_runs_trusted_pre_switch_revision(self):
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "succeeded")
        self.assertEqual(self.f.terminal()["acceptance"], "pass")
        event = self.f.events("acceptance")[0]
        self.assertEqual(event["args"], [self.f.old_hnet, "just", "acceptance", "http://fixture.invalid",
                                         self.f.new_version, self.f.manifest_sha])
        self.assertEqual(len(self.f.events("acceptance")), 1)

    def acceptance_bad(self, **scenario):
        self.f.scenario.update(scenario)
        self.f.orchestrator["acceptance_timeout"] = 0.2 if scenario.get("acceptance_hang") else 2
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "failed")
        self.assertEqual(self.f.terminal()["rollback"], "succeeded")
        self.assertEqual(self.f.terminal()["acceptance"], "fail")
        self.assertEqual(Path(self.f.executor["current_system"]).resolve(), self.f.old_system)
        self.assertEqual(len(self.f.events("switch")), 2)
        self.assertIn("ACCEPTANCE FAILED", self.f.events("mailbox")[0]["text"])

    def test_acceptance_red_rolls_back(self):
        self.acceptance_bad(acceptance_output='{"ok":false}')

    def test_acceptance_nonzero_rolls_back(self):
        self.acceptance_bad(acceptance_exit=1)

    def test_acceptance_timeout_rolls_back(self):
        self.acceptance_bad(acceptance_hang=True)

    def test_acceptance_garbage_rolls_back(self):
        self.acceptance_bad(acceptance_output="garbage")

    def test_acceptance_nonstandard_json_rolls_back(self):
        self.acceptance_bad(acceptance_output='{"ok":true,"invalid":NaN}')

    def test_acceptance_missing_rolls_back(self):
        self.acceptance_bad(acceptance_missing=True)

    def test_acceptance_unset_refuses_before_switch(self):
        self.f.orchestrator["acceptance_command"] = []
        self.assertNotEqual(self.f.tick("live", expect_ok=False).returncode, 0)
        self.assertFalse(self.f.events("start"))
        self.assertFalse(self.f.events("switch"))

    def test_dry_run_acceptance_not_run(self):
        self.f.tick()
        self.assertEqual(self.f.terminal()["acceptance"], "not_run")
        self.assertFalse(self.f.events("acceptance"))

    def test_vm_test_retryable_outage_alarm_once_and_recovery(self):
        self.f.scenario["vm_test_error"] = True
        self.f.orchestrator["vm_test_wait_timeout"] = 0.01
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "vm_test_wait")
        self.assertEqual(self.f.state()["failed"], [])
        self.assertEqual(self.f.state()["attempted"], {})
        self.f.tick()
        self.f.tick()
        self.assertEqual(len(self.f.events("mailbox")), 2)
        self.assertFalse(self.f.events("start"))
        self.f.scenario["vm_test_error"] = False
        self.f.tick()
        self.assertEqual(self.f.terminal()["status"], "succeeded")
        self.assertNotIn("vm_test_wait", self.f.state())

    def test_repeated_fetch_failure_persists_pre_pair_reset(self):
        self.f.orchestrator["hausnetz_url"] = str(self.f.root / "absent")
        self.f.tick()
        state = self.f.state()
        state["pre_pair_failure"] = {"since": 0, "alarmed": False}
        self.f.write(Path(self.f.orchestrator["state_file"]), json.dumps(state))
        self.f.tick()
        self.assertNotIn("pre_pair_failure", self.f.state())
        self.assertEqual(len(self.f.events("ticket")), 1)

    def test_executor_result_refuses_controller_only_status(self):
        result = {"schema": "inspr.pharos.guarded-deploy-result.v1", "nixcfg_rev": self.f.new,
                  "hausnetz_rev": self.f.new_hnet, "run_id": "a" * 32, "mode": "dry-run", "status": "fetch_failed"}
        with self.assertRaises(Manual):
            validate_result(result, result)

    def test_once_trial_does_not_reserve_pair_or_executor_revision(self):
        self.f.tick(args=("--once", "--dry-run"))
        self.assertEqual(self.f.state()["attempted"], {})
        self.assertFalse(ledger(self.f.orchestrator, "attempted", self.f.key).exists())
        self.assertFalse(list((Path(self.f.executor["state_dir"]) / "attempted").glob("*.json")))
        self.f.tick("live")
        self.assertEqual(self.f.terminal()["status"], "succeeded")
        self.assertEqual(len(self.f.events("start")), 2)


class TestAlertSender(unittest.TestCase):
    def setUp(self):
        import types
        path = SOURCE / "hausnetz-cd-alert.py"
        if not path.exists():
            path = REPO / "hosts/csb1/hausnetz-cd-alert.py"
        self.sender = types.ModuleType("cd_alert")
        exec(compile(path.read_text(), str(path), "exec"), self.sender.__dict__)
        self.temporary = tempfile.TemporaryDirectory(prefix="t125-csb1-alert-")
        self.addCleanup(self.temporary.cleanup)
        self.credential = Path(self.temporary.name) / "notification-fixture"
        self.credential.write_text('WATCHTOWER_NOTIFICATION_URL="telegram://123:fixture_token@telegram?chats=-123,456"\n')

    def test_sender_uses_existing_target_in_process_and_stdin_only(self):
        from urllib.parse import parse_qs
        with mock.patch.object(self.sender.urllib.request, "build_opener") as build:
            build.return_value.open.return_value.__enter__.return_value.status = 200
            self.assertTrue(self.sender.send("ROLLBACK FAILED rev=fixture", str(self.credential)))
            self.assertEqual(build.return_value.open.call_count, 2)
            for call in build.return_value.open.call_args_list:
                request = call.args[0]
                self.assertTrue(request.full_url.startswith("https://api.telegram.org/bot"))
                self.assertEqual(parse_qs(request.data.decode())["text"], ["ROLLBACK FAILED rev=fixture"])
            self.assertEqual(build.call_args.args[0].proxies, {})
            redirect = build.call_args.args[1]
            self.assertIsNone(redirect.redirect_request(None, None, 302, "", {}, "https://other.invalid"))
        with mock.patch.object(sys, "argv", ["sender"]), mock.patch.object(sys, "stdin") as stdin:
            stdin.read.return_value = "alarm"
            self.sender.NOTIFICATION_ENV = str(self.credential)
            with mock.patch.object(self.sender, "send", return_value=True) as send:
                self.assertEqual(self.sender.main(), 0)
                stdin.read.assert_called_once_with(2049)
                send.assert_called_once_with("alarm", str(self.credential))

    def test_sender_rejects_bad_inputs_without_logging_credentials(self):
        import contextlib
        import io
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr), \
                mock.patch.object(self.sender.urllib.request, "build_opener") as build:
            for message in ("", "x" * 2049, "bad\rline"):
                self.assertFalse(self.sender.send(message, str(self.credential)))
            build.assert_not_called()
            for target in ("https://other.invalid", "telegram://bad@telegram?chats=123",
                           "telegram://123:fixture_token@other.invalid?chats=123",
                           "telegram://123:fixture_token@telegram?chats=not-a-chat"):
                self.credential.write_text("WATCHTOWER_NOTIFICATION_URL=" + target + "\n")
                self.assertFalse(self.sender.send("alarm", str(self.credential)))
            build.assert_not_called()
            self.credential.write_text("WATCHTOWER_NOTIFICATION_URL=telegram://123:fixture_token@telegram?chats=123\n")
            build.return_value.open.side_effect = OSError("synthetic sensitive diagnostic")
            self.assertFalse(self.sender.send("alarm", str(self.credential)))
            self.sender.NOTIFICATION_ENV = "@NOTIFICATION_ENV@"
            with mock.patch.object(sys, "argv", ["sender"]):
                self.assertEqual(self.sender.main(), 1)
        self.assertEqual(stdout.getvalue() + stderr.getvalue(), "")

    def test_sender_module_reuses_existing_secret_without_defining_one(self):
        source = (REPO / "hosts/csb1/hausnetz-cd-alert.nix").read_text()
        self.assertIn("config.age.secrets.csb1-watchtower-env.path", source)
        self.assertNotIn("age.secrets.csb1-watchtower-env =", source)
        self.assertIn("./hausnetz-cd-alert.nix", (REPO / "hosts/csb1/configuration.nix").read_text())


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
        ("G2 exit status", "common.py", [('if returncode != 0:', 'if False:'), ('returncode == 0 and value["persisted_ok"] is True', 'True and value["persisted_ok"] is True')], "test_prepare_nonzero_is_manual"),
        ("G2 manifest changed", "common.py", [('value["manifest_changed"] is False and not value["problems"]', 'True and not value["problems"]')], "test_prepare_manifest_changed_is_manual"),
        ("G2 persisted data", "common.py", [('returncode == 0 and value["persisted_ok"] is True', 'returncode == 0 and True')], "test_prepare_persisted_false_is_manual"),
        ("G2 narHash", "common.py", [('value["narHash"] == nar_hash', 'True')], "test_prepare_narhash_mismatch_is_manual"),
        ("G2 expected revision", "common.py", [('value["rev"] == expected and value["narHash"]', 'True and value["narHash"]')], "test_prepare_rev_mismatch_is_manual"),
        ("G2 manifest byte identity", "common.py", [('value["manifest_changed"] is False', 'True'), ('value["manifest_sha256"] == value["running_manifest_sha256"]', 'True')], "test_g2_manifest_must_be_byte_identical"),
        ("G2 problems", "common.py", [('not value["problems"]', 'True')], "test_g2_manifest_missing"),
        ("G2 schema", "common.py", [('isinstance(value, dict) and set(value) == fields', 'isinstance(value, dict)')], "test_prepare_unknown_field_is_manual"),
        ("G2 missing checker revision", "common.py", [('"changed_paths_total", "checker_rev", "problems"}', '"changed_paths_total", "problems"}'), ('value["checker_rev"] == running', 'True')], "test_prepare_missing_checker_rev_is_manual"),
        ("G2 no diff taken", "common.py", [('value["changed_paths_total"] == 0', 'value["changed_paths_total"] in {-1, 0}')], "test_prepare_no_diff_is_manual"),
        ("G2 changed path count", "common.py", [('value["changed_paths_total"] == 0', 'value["changed_paths_total"] in {0, 1}')], "test_prepare_changed_paths_total_is_manual"),
        ("G2 checker revision binding", "common.py", [('value["checker_rev"] == running', 'True')], "test_prepare_checker_rev_mismatch_is_manual"),
        ("G2 changed paths retained", "orchestrate.py", [('result["changed_paths"] = exc.changed_paths', 'result["changed_paths"] = []')], "test_prepare_unsafe_diagnostics_are_retained"),
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
        ("executor idempotency", "execute.py", [('\n    if mode != "rehearse" and not trial and attempt.exists():', '\n    if False:'), ('\n        if mode != "rehearse" and not trial and attempt.exists():', '\n        if False:')], "test_idempotency_success_and_executor_duplicate"),
        ("crashed executor detection", "orchestrate.py", [('if response["unit_state"] not in {"active", "activating", "deactivating"}:', 'if False:')], "test_crashed_running_unit_is_failed_once_dry_run"),
        ("run-scoped status identity", "orchestrate.py", [('            and result.get("run_id") == pending["run_id"]', '            and True'), ('isinstance(result, dict) and result.get("run_id") == pending["run_id"]', 'isinstance(result, dict)')], "test_stale_skipped_status_is_ignored"),
        ("result identity run ID", "orchestrate.py", [('            and result.get("run_id") == pending["run_id"]', '            and True')], "test_result_identity_requires_run_id"),
        ("SSH retry grace", "orchestrate.py", [('retry = fixture_limit(config, "ssh_retry_timeout", SSH_RETRY_TIMEOUT)', 'retry = 0')], "test_short_ssh_drop_does_not_alarm"),
        ("executor observation budget", "common.py", [('POLL_BUDGET = EXECUTOR_BUDGET + SSH_RETRY_TIMEOUT + 120', 'POLL_BUDGET = 720')], "test_poll_and_runtime_budgets"),
        ("transient memory limit", "orchestrate.py", [('\n      --property=MemoryHigh=1G --property=MemoryMax=1500M', '\n      --property=MemoryHigh=1G --property=MemoryMax=4G')], "test_dry_run_success_and_limits"),
        ("dry-run isolation", "execute.py", [('if mode == "dry-run":\n                result["status"]', 'if False:\n                result["status"]')], "test_dry_run_success_and_limits"),
        ("binary store-path proof", "execute.py", [('require(executable == proof["exe"],', 'require(True,')], "test_exe_mismatch_rolls_back"),
        ("metadata version proof", "execute.py", [('isinstance(value, dict) and value.get("version") == proof["version"]', 'True')], "test_meta_version_mismatch_rolls_back"),
        ("bare HTTP 200 rejected", "execute.py", [('isinstance(value, dict) and value.get("version") == proof["version"]', 'True'), ('value.get("capabilities_sha256") == proof["manifest_sha256"]', 'True')], "test_bare_200_is_not_revision_health"),
        ("G2 usage exit status", "common.py", [('if returncode != 0:', 'if False:'), ('returncode == 0 and value["persisted_ok"] is True', 'returncode in {0, 2} and value["persisted_ok"] is True')], "test_prepare_usage_exit_is_manual"),
        ("G2 unexpected exit status", "common.py", [('if returncode != 0:', 'if False:'), ('returncode == 0 and value["persisted_ok"] is True', 'True and value["persisted_ok"] is True')], "test_prepare_other_exit_is_manual"),
        ("G2 problems retained", "orchestrate.py", [('result["problems"] = exc.problems', 'result["problems"] = []')], "test_prepare_nonzero_records_problems"),
        ("metadata manifest digest proof", "execute.py", [('value.get("capabilities_sha256") == proof["manifest_sha256"]', 'True')], "test_meta_manifest_mismatch_rolls_back"),
        ("metadata manifest missing", "execute.py", [('value.get("capabilities_sha256") == proof["manifest_sha256"]', 'True')], "test_meta_manifest_missing_rolls_back"),
        ("readiness version proof", "execute.py", [('ready.get("version") == proof["version"]', 'True')], "test_readyz_version_mismatch_rolls_back"),
        ("readiness checks proof", "execute.py", [('isinstance(checks, dict) and set(checks) == {"instance", "engine", "site", "ui"}\n                    and all(value is True for value in checks.values())', 'True')], "test_readyz_check_false_rolls_back"),
        ("three-check readiness rejected", "execute.py", [('set(checks) == {"instance", "engine", "site", "ui"}', '{"engine", "site", "ui"}.issubset(checks)')], "test_three_check_readyz_rolls_back"),
        ("capabilities body hash proof", "execute.py", [('hashlib.sha256(capabilities).hexdigest() == proof["manifest_sha256"]', 'True')], "test_capabilities_body_mismatch_rolls_back"),
        ("rollback capabilities body proof", "execute.py", [('hashlib.sha256(capabilities).hexdigest() == proof["manifest_sha256"]', 'True')], "test_rollback_capabilities_body_must_match_old_proof"),
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
        ("recorded rollback", "execute.py", [('run(result["old_system"] + "/bin/switch-to-configuration", ["switch"]', 'run(result["new_system"] + "/bin/switch-to-configuration", ["switch"]')], "test_health_fail_rolls_back_recorded_system"),
        ("rollback old proof", "execute.py", [('require(health(config, result["old_proof"]), "rollback_health_failed")', 'require(True, "rollback_health_failed")')], "test_rollback_must_prove_old_revision"),
        ("wait for completed rollback", "orchestrate.py", [('or (result.get("phase") == "complete" and result.get("completed_at"))', 'or True')], "test_health_fail_rolls_back_recorded_system"),
        ("rollback Telegram", "execute.py", [('"auto-rollback" if result["rollback"]', '"wrong" if result["rollback"]')], "test_health_fail_rolls_back_recorded_system"),
        ("rollback failure alarms", "orchestrate.py", [('alarm(config, result, prefix + label)', 'pass')], "test_rollback_failure_alarms_both_independent_paths"),
        ("host live enable gate", "execute.py", [('require(mode != "live" or config.get("allow_live") is True,', 'require(True,')], "test_live_disabled_on_host"),
        ("independent alert required", "orchestrate.py", [('require(config.get("secondary_telegram_command"),', 'require(True,')], "test_missing_independent_alert_refuses_live"),
        ("agent disabled default", "orchestrate.py", [('if config.get("enabled") is not True:', 'if False:')], "test_disabled_agent_has_no_effect"),
        ("build resource limit", "execute.py", [('"--max-jobs", "1", "--cores", "2"', '"--max-jobs", "4", "--cores", "8"')], "test_dry_run_success_and_limits"),
        ("G2 extra stdout", "common.py", [('value = strict_json(stdout)', 'value = json.JSONDecoder().raw_decode(stdout.decode())[0]')], "test_prepare_extra_stdout_is_manual"),
        ("G2 app timeout", "common.py", [('capture_output=True, timeout=600, check=False)', 'capture_output=True, timeout=None, check=False)')], "test_prepare_timeout_is_manual"),
        ("fresh starting status", "execute.py", [('    save()\n    attempt = state', '    attempt = state')], "test_starting_status_precedes_lock"),
        ("lock parse errors per tick", "orchestrate.py", [('except (Manual, OSError, KeyError, TypeError, ValueError):\n            pre_pair_failure(config, state)', 'except OSError:\n            pre_pair_failure(config, state)')], "test_lock_parse_errors_retry_silently"),
        ("built package versus prepared version", "execute.py", [('require(result["new_proof"]["version"] == expected_version,', 'require(True,')], "test_built_version_must_match_prepare"),
        ("activation never killed by timeout", "execute.py", [('run(new_system + "/bin/switch-to-configuration", ["switch"], timeout=None)', 'run(new_system + "/bin/switch-to-configuration", ["switch"], timeout=120)')], "test_poll_and_runtime_budgets"),
        ("remote expected revision regex", "orchestrate.py", [('[[ "$expected" =~ ^[0-9a-f]{40}$ ]]', 'true')], "test_remote_rev_and_digest_regexes"),
        ("remote run ID regex", "orchestrate.py", [('[[ "$run_id" =~ ^[0-9a-f]{32}$ ]]', 'true')], "test_remote_rev_and_digest_regexes"),
        ("remote version regex", "orchestrate.py", [('[[ "$version" =~ ^[0-9]{12}\\.0\\.0$ ]]', 'true')], "test_remote_rev_and_digest_regexes"),
        ("remote manifest digest regex", "orchestrate.py", [('[[ "$manifest_sha" =~ ^[0-9a-f]{64}$ ]]', 'true')], "test_remote_rev_and_digest_regexes"),
        ("G3 no SGR stripping", "common.py", [('text = re.sub(r"\\x1b\\[[0-9;]*m", "", text)', 'text = text')], "test_g3_captured_pin_only_and_sgr_pass"),
        ("G3 strip all escapes", "common.py", [('r"\\x1b\\[[0-9;]*m"', 'r"\\x1b(?:\\[[0-?]*[ -/]*[@-~]|\\][^\\x07]*(?:\\x07|\\x1b\\\\)|.)"')], "test_g3_other_escapes_and_controls_fail"),
        ("G3 controls rejected", "common.py", [('all(char == "\\n" or char.isprintable() for char in text)', 'True')], "test_g3_other_escapes_and_controls_fail"),
        ("G3 raw control bytes preserved", "execute.py", [('timeout=G3_COMMAND_TIMEOUT, binary=True).decode("utf-8")', 'timeout=G3_COMMAND_TIMEOUT)')], "test_g3_control_bytes_are_not_normalized_away"),
        ("pre-pair SSH failure is retryable", "orchestrate.py", [('            print("hausnetz-cd: tick skipped; source or running evidence unavailable", flush=True)\n            return', '            state["failed"].append(expected)\n            save_state(config, state)\n            return')], "test_unchanged_pin_and_evidence_ssh_failure_across_two_commits"),
        ("pre-pair old source failure is retryable", "orchestrate.py", [('            print("hausnetz-cd: tick skipped; source or running evidence unavailable", flush=True)\n            return', '            state["failed"].append(expected)\n            save_state(config, state)\n            return')], "test_missing_old_source_retries_without_tombstone"),
        ("executor gated baseline", "execute.py", [('require(old_rev == gated_running,', 'require(True,')], "test_executor_rejects_changed_gated_baseline"),
        ("G2 running release checker", "common.py", [('git(repo, "checkout", "--quiet", "--detach", old)', 'git(repo, "checkout", "--quiet", "--detach", new)')], "test_prepare_exact_command"),
        ("G2 independent ancestry", "common.py", [('        git(repo, "merge-base", "--is-ancestor", old, new)', '        pass')], "test_prepare_rejects_non_descendant_before_app"),
        ("duplicate run refusal terminal", "execute.py", [('result.update(status="manual", phase="complete", reason=reason,', 'result.update(status="running", phase="complete", reason=reason,')], "test_duplicate_run_has_terminal_refusal_without_overwriting_original"),
        ("revision refusal terminal", "execute.py", [('result.update(status="manual", phase="complete", reason=reason,', 'result.update(status="running", phase="complete", reason=reason,')], "test_revision_refusal_is_terminal_before_lock"),
        ("missing lock refusal terminal", "execute.py", [('result.update(status="manual", phase="complete", reason=reason,', 'result.update(status="running", phase="complete", reason=reason,')], "test_missing_deploy_lock_is_terminal_manual"),
        ("old system GC root", "execute.py", [('run("nix-store", ["--add-root", state / "old-system", "--indirect", "--realise", old_system])', 'pass')], "test_gc_roots_protect_both_systems_through_g3_and_completion"),
        ("new system GC root", "execute.py", [('"--out-link", state / "new-system",', '"--no-link",')], "test_gc_roots_protect_both_systems_through_g3_and_completion"),
        ("ticket retry cap", "orchestrate.py", [('entry.get("ticket_attempts", 0) < 5', 'entry.get("ticket_attempts", 0) < 6')], "test_ticket_attempts_cap_and_durable_local_outbox"),
        ("strict readiness booleans", "execute.py", [('all(value is True for value in checks.values())', 'all(checks.values())')], "test_readyz_truthy_nonbooleans_are_rejected"),
        ("controller gate labels", "execute.py", [('result["gates"]["G2"] = "controller_evidence"', 'result["gates"]["G2"] = "pass"'), ('result["gates"]["G4"] = "controller_evidence"', 'result["gates"]["G4"] = "pass"')], "test_dry_run_success_and_limits"),
        ("controller evidence values", "execute.py", [('"running_nixcfg_rev": gated_running,', '"running_nixcfg_rev": new_rev,')], "test_executor_labels_controller_evidence_and_preserves_values"),
        ("controller evidence validation", "orchestrate.py", [('require(result.get("running_nixcfg_rev") == pending["running_nixcfg_rev"]', 'require(True or result.get("running_nixcfg_rev") == pending["running_nixcfg_rev"]')], "test_executor_labels_controller_evidence_and_preserves_values"),
        ("remote running baseline regex", "orchestrate.py", [('[[ "$running" =~ ^[0-9a-f]{40}$ ]]', 'true')], "test_remote_rev_and_digest_regexes"),
        ("G2 checker URL pin", "common.py", [(' + "?rev=" + old + "#cd-prepare"', ' + "#cd-prepare"')], "test_prepare_exact_command"),
        ("G2 offline checker", "common.py", [('\"--offline\", ', '')], "test_prepare_exact_command"),
        ("G2 no lock writes", "common.py", [('\"--no-write-lock-file\", ', '')], "test_prepare_exact_command"),
        ("G2 nonempty paths despite zero total", "common.py", [('and not paths', 'and True')], "test_prepare_nonempty_paths_with_zero_total_is_manual"),
        ("bounded diagnostic count", "common.py", [('limit = 19 if len(items) > 20 else 20', 'limit = len(items)')], "test_schema_failure_diagnostics_are_bounded_at_all_boundaries"),
        ("bounded diagnostic strings", "common.py", [('if len(item) > 200 else item', 'if False else item')], "test_schema_failure_diagnostics_are_bounded_at_all_boundaries"),
        ("checker URL encoding", "common.py", [('quote(path, safe="/")', 'path')], "test_checker_url_encodes_path_and_refuses_controls"),
        ("checker path validation", "common.py", [('Path(repo).is_absolute() and all(c.isprintable() for c in path)', 'True')], "test_checker_url_encodes_path_and_refuses_controls"),
        ("fetch phase is distinct", "orchestrate.py", [('result["phase"] = "fetch"', 'pass')], "test_hausnetz_fetch_failure_is_distinct_and_retryable"),
        ("fetch failures have no reservation", "orchestrate.py", [('if result["status"] not in {"fetch_failed", "vm_test_wait"} and not result.get("trial") and not result.get("rehearsal"):', 'if True:')], "test_hausnetz_fetch_failure_is_distinct_and_retryable"),
        ("pre-pair six hour alarm", "orchestrate.py", [('>= 6 * 60 * 60', '>= 7 * 60 * 60')], "test_pre_pair_failure_alarms_once_after_six_hours_even_dry_run"),
        ("pre-pair alarms once", "orchestrate.py", [('failure["alarmed"] = True', 'failure["alarmed"] = False')], "test_pre_pair_failure_alarms_once_after_six_hours_even_dry_run"),
        ("cached unchanged main", "orchestrate.py", [('evaluated.get("main") == new', 'False')], "test_unchanged_tick_caches_evidence_until_thirty_minutes_or_main_moves"),
        ("cache expires at thirty minutes", "orchestrate.py", [('< 30 * 60', '< 60 * 60')], "test_unchanged_tick_caches_evidence_until_thirty_minutes_or_main_moves"),
        ("cache invalidates on main movement", "orchestrate.py", [('evaluated.get("main") == new', 'True')], "test_unchanged_tick_caches_evidence_until_thirty_minutes_or_main_moves"),
        ("state path confinement", "common.py", [('if not resolved.startswith(STATE_ROOT + os.sep):', 'if False:')], "test_state_path_refuses_traversal_prefix_siblings_and_symlinks"),
        ("fixture utilities use PATH", "hausnetz-cd-command.py", [('shutil.which(name)', '"/usr/bin/" + name')], "test_sudo_fixture_resolves_utilities_from_path"),
        ("executor raw source refuses", "execute.py", [('\n        require(not CONFIG_FILE.startswith("@"), "unsubstituted_configuration")', '\n        pass')], "test_unsubstituted_entrypoints_refuse_existing_placeholder_file"),
        ("orchestrator raw source refuses", "orchestrate.py", [('require(not CONFIG_FILE.startswith("@"), "unsubstituted_configuration")', 'pass')], "test_unsubstituted_entrypoints_refuse_existing_placeholder_file"),
        ("G5 exact revision", "orchestrate.py", [('r.get("head_sha") == rev', 'True')], "test_vm_test_requires_latest_exact_revision_success"),
        ("G5 completed workflow", "orchestrate.py", [('latest.get("status") == "completed"', 'True')], "test_vm_test_requires_latest_exact_revision_success"),
        ("G5 successful conclusion", "orchestrate.py", [('latest.get("conclusion") == "success"', 'True')], "test_vm_test_requires_latest_exact_revision_success"),
        ("G5 latest run", "orchestrate.py", [('latest = max(runs,', 'latest = min(runs,')], "test_vm_test_requires_latest_exact_revision_success"),
        ("G5 live gate", "orchestrate.py", [('config["mode"] == "dry-run" or result["gates"]["G5"] == "pass"', 'True')], "test_vm_test_error_blocks_live_before_executor"),
        ("G5 dry-run observation", "orchestrate.py", [('config["mode"] == "dry-run" or result["gates"]["G5"] == "pass"', 'result["gates"]["G5"] == "pass"')], "test_vm_test_error_is_recorded_but_dry_run_completes"),
        ("dry-run never alarms", "orchestrate.py", [('if result["mode"] != "live" and not pre_pair and not test and not result.get("rehearsal"):', 'if False:')], "test_dry_run_never_alarms_on_executor_failure"),
        ("mailbox both recipients", "orchestrate.py", [('else:\n        for recipient in ("mac-lead", "lead"):', 'else:\n        for recipient in ("mac-lead",):')], "test_mailbox_failure_does_not_suppress_other_alarm_paths"),
        ("mailbox fallback required", "orchestrate.py", [('if fallback:', 'if False:')], "test_test_alarm_missing_file_falls_back_to_both_local_mailboxes"),
        ("mailbox fallback both recipients", "orchestrate.py", [('if fallback:\n        for recipient in ("mac-lead", "lead"):', 'if fallback:\n        for recipient in ("mac-lead",):')], "test_test_alarm_missing_file_falls_back_to_both_local_mailboxes"),
        ("mailbox rejects extra lines", "orchestrate.py", [('text.removesuffix("\\n").split("\\n")', 'text.removesuffix("\\n").split("\\n")[:3]')], "test_test_alarm_invalid_file_falls_back_to_both_local_mailboxes"),
        ("mailbox rejects host junk", "orchestrate.py", [('r"[A-Za-z0-9.:-]+", host', 'r".+", host'), ('require(len(host) <= 253 and re.fullmatch(', 'require(True or re.fullmatch(')], "test_mailbox_target_strictly_rejects_junk"),
        ("mailbox rejects port junk", "orchestrate.py", [('r"[0-9]{1,5}", values["port"]', 'r".+", values["port"]')], "test_mailbox_target_strictly_rejects_junk"),
        ("mailbox failed send triggers fallback", "orchestrate.py", [('fallback = True\n                alarm_route_failed("remote mailbox "', 'fallback = False\n                alarm_route_failed("remote mailbox "')], "test_either_remote_recipient_failure_falls_back_without_duplicate_csb1"),
        ("test alarm never writes state", "orchestrate.py", [('"TEST (no action): CD ALARM", test=True)\n            return', '"TEST (no action): CD ALARM", test=True)\n            atomic_json(config["state_file"], {})\n            return')], "test_test_alarm_leaves_existing_state_and_deploy_paths_untouched"),
        ("test alarm never writes alarm file", "orchestrate.py", [('if not test:', 'if True:')], "test_test_alarm_leaves_existing_state_and_deploy_paths_untouched"),
        ("test alarm explicit only", "orchestrate.py", [('if args.test_alarm:', 'if True:')], "test_test_alarm_is_explicit_and_rejects_deployment_flags"),
        ("test alarm cannot combine deploy flags", "orchestrate.py", [('bool(args.command), args.clear_disable, args.test_alarm, args.once or args.dry_run', 'bool(args.command), args.clear_disable, False, args.once or args.dry_run')], "test_test_alarm_is_explicit_and_rejects_deployment_flags"),
        ("dry-run memory measurement", "execute.py", [('result["memory_peak_bytes"] = int(peak)', 'pass')], "test_dry_run_measures_memory_peak_into_status_and_ticket"),
        ("manual dry-run forced mode", "orchestrate.py", [('"enabled": True, "mode": "dry-run", "manual_dry_run": True', '"enabled": True, "manual_dry_run": True')], "test_disabled_once_dry_run_runs_full_chain_and_forces_mode"),
        ("manual dry-run requires both flags", "orchestrate.py", [('if args.once != args.dry_run:', 'if False:')], "test_once_requires_both_flags_and_refuses_live_pending"),
        ("manual dry-run refuses live pending", "orchestrate.py", [('not state["pending"] or state["pending"]["mode"] == "dry-run"', 'True')], "test_once_requires_both_flags_and_refuses_live_pending"),
        ("disabled latch ignored", "orchestrate.py", [('if "disabled" in state:', 'if False:')], "test_latch_blocks_timer_and_once_and_never_clears_itself"),
        ("disabled latch auto-cleared", "orchestrate.py", [('        if "disabled" in state:', '        state.pop("disabled", None)\n        if "disabled" in state:')], "test_latch_blocks_timer_and_once_and_never_clears_itself"),
        ("disabled latch not written", "orchestrate.py", [('state.setdefault("disabled",', 'dict().setdefault("disabled",')], "test_latch_written_on_first_real_rollback_failure"),
        ("live switch without attended ack", "orchestrate.py", [('if not valid_ack:', 'if False:')], "test_attended_counter_initializes_three_and_no_ack_no_switch"),
        ("attended decrement on failure", "orchestrate.py", [('if result["status"] == "succeeded":\n        if result["mode"]', 'if result["status"] in {"succeeded", "failed"}:\n        if result["mode"]')], "test_attended_failure_does_not_decrement"),
        ("attended counter skipped", "orchestrate.py", [('if config["mode"] == "live" and state["attended_remaining"] > 0:', 'if False:')], "test_attended_counter_initializes_three_and_no_ack_no_switch"),
        ("acceptance red accepted", "orchestrate.py", [('value.get("ok") is True, "acceptance_red_or_schema"', 'True, "acceptance_red_or_schema"')], "test_acceptance_red_rolls_back"),
        ("acceptance malformed JSON accepted", "common.py", [(', parse_constant=invalid_constant', '')], "test_acceptance_nonstandard_json_rolls_back"),
        ("acceptance timeout ignored", "orchestrate.py", [('timeout=config.get("acceptance_timeout", ACCEPTANCE_TIMEOUT)', 'timeout=None')], "test_acceptance_timeout_rolls_back"),
        ("acceptance failure skips rollback", "execute.py", [('if switched and not rehearsal_changed:', 'if False:')], "test_acceptance_red_rolls_back"),
        ("executor accepts fetch failure", "orchestrate.py", [('result.get("status") in EXECUTOR_TERMINAL |', 'result.get("status") in TERMINAL |')], "test_executor_result_refuses_controller_only_status"),
        ("trial reserves production pair", "orchestrate.py", [('if not pending.get("trial"):', 'if True:')], "test_once_trial_does_not_reserve_pair_or_executor_revision"),
        ("repeated fetch loses reset", "orchestrate.py", [('if result["status"] in {"fetch_failed", "vm_test_wait"} and key in state["reports"]:\n        save_state(config, state)', 'if result["status"] in {"fetch_failed", "vm_test_wait"} and key in state["reports"]:\n        pass')], "test_repeated_fetch_failure_persists_pre_pair_reset"),
        ("vm-test failure becomes permanent", "orchestrate.py", [('result.update(status="vm_test_wait", run_key=key + "-vm-test")', 'result.update(status="manual", run_key=key + "-vm-test")')], "test_vm_test_retryable_outage_alarm_once_and_recovery"),
        ("health revision identity ignored", "execute.py", [('revision(proof.get("expected_revision")) == revision(proof["revision"])', 'True')], "test_rehearsal_a_real_switch_and_rollback_without_changes"),
        ("rehearsal allows activation changes", "execute.py", [('rehearsal_units(activation.stdout)', 'pass')], "test_rehearsal_refuses_nonempty_activation"),
        ("csb1 sender bounds message", "hausnetz-cd-alert.py", [('len(message) > 2048', 'False')], "TestAlertSender.test_sender_rejects_bad_inputs_without_logging_credentials"),
    ]
    def check_mutant(case):
        label, file, edits, test = case
        with tempfile.TemporaryDirectory(prefix="t125-mutant-", dir="/tmp") as temporary:
            source = Path(temporary)
            for path in SOURCE.glob("*"):
                if path.suffix in {".py", ".sh"}:
                    shutil.copyfile(path, source / path.name)
            for path in (REPO / "tests/fixtures/hausnetz-cd-command.py", REPO / "hosts/csb1/hausnetz-cd-alert.py"):
                shutil.copyfile(path, source / path.name)
            text = (source / file).read_text()
            for before, after in edits:
                if text.count(before) != 1:
                    raise AssertionError("Mutant no longer matches exactly once: " + label)
                text = text.replace(before, after, 1)
            (source / file).write_text(text)
            target = test if "." in test else "TestCD." + test
            result = subprocess.run([sys.executable, "-B", str(Path(__file__).resolve()), target],
                                    env=dict(os.environ, HAUSNETZ_CD_SOURCE=source.name),
                                    capture_output=True, text=True, timeout=45, check=False)
            if result.returncode == 0:
                raise AssertionError("SURVIVED guard-removal mutant: " + label)
            # Do not count a syntax/import/fixture setup failure as a killed
            # mutant. The selected behavior assertion itself must fail.
            if "FAIL: " not in result.stderr:
                raise AssertionError("Invalid mutant run: " + label + "\n" + result.stderr)
            return label
    for case in cases:
        print("must-fail mutant killed: " + check_mutant(case), flush=True)
    print("T125: " + str(len(cases)) + " guard-removal mutants killed", flush=True)


def parallel_cases():
    names = unittest.defaultTestLoader.getTestCaseNames(TestCD)
    groups = [names[index::4] for index in range(4)]
    def check_group(group):
        return subprocess.run([sys.executable, "-B", str(Path(__file__).resolve()),
                               *("TestCD." + name for name in group)],
                              capture_output=True, text=True, timeout=600, check=False)
    with ThreadPoolExecutor(max_workers=4) as workers:
        results = list(workers.map(check_group, groups))
    for result in results:
        print(result.stdout, end="", flush=True)
        print(result.stderr, end="", file=sys.stderr, flush=True)
    if any(result.returncode for result in results):
        raise SystemExit("T125: transaction shard failed")
    print("T125: " + str(len(names)) + " transaction cases passed (4 bounded subprocesses)", flush=True)


if __name__ == "__main__":
    if sys.argv[1:] == ["--mutants"]:
        mutants()
    elif sys.argv[1:] == ["--parallel"]:
        parallel_cases()
    else:
        unittest.main(verbosity=2)
