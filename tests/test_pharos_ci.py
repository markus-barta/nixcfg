"""Public dependency caching must never skip a contract or publish private inputs."""

import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("pharos_ci_nix", ROOT / "scripts/pharos-ci-nix.py")
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


def yaml(path):
    return json.loads(subprocess.check_output([
        "ruby", "-rjson", "-rpsych", "-e", "puts JSON.generate(Psych.load_file(ARGV[0]))",
        str(path),
    ]))


class CacheBoundaryFixtures(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = yaml(ROOT / ".github/workflows/check.yml")
        cls.action = yaml(ROOT / ".github/actions/pharos-nix/action.yml")

    def test_every_shard_prepares_before_tests_and_only_private_shard_writes(self):
        writers = []
        for shard in self.workflow["jobs"]["pharos-rollout"]["needs"]:
            job = self.workflow["jobs"][shard]
            self.assertEqual(job["permissions"], {"contents": "read"})
            self.assertNotIn("needs", job)  # No new serial prepare-job barrier.
            steps = job["steps"]
            preparations = [(i, step) for i, step in enumerate(steps)
                            if step.get("uses") == "./.github/actions/pharos-nix"]
            (index, preparation), = preparations
            self.assertEqual(index, 2)  # Immediately after checkout/classification.
            self.assertEqual(preparation["if"], "steps.pin.outputs.pin_only != 'true'")
            if preparation.get("with", {}).get("save-cache") == "true":
                writers.append(shard)
            for step in steps[index + 1:]:
                # Cache hits never control test execution, even in the writer.
                self.assertNotIn("cache", step.get("if", ""))
                self.assertNotIn("continue-on-error", step)
        writer, = writers
        self.assertTrue(any(step.get("id") == "hausnetz-input"
                            for step in self.workflow["jobs"][writer]["steps"]))

    def test_snapshot_is_synchronous_and_precedes_every_private_consumer(self):
        steps = self.action["runs"]["steps"]
        self.assertEqual(self.action["inputs"]["save-cache"]["default"], "false")
        installer, restore, select, tools, save = steps
        self.assertTrue(installer["uses"].startswith("cachix/install-nix-action@"))
        self.assertNotIn("nix_path", installer.get("with", {}))
        self.assertTrue(restore["uses"].startswith("nix-community/cache-nix-action/restore@"))
        self.assertEqual(restore["with"]["save"], "false")
        self.assertEqual(set(restore["with"]), {"primary-key", "save"})
        self.assertEqual(select["run"], "python3 scripts/pharos-ci-nix.py")
        self.assertIn("\nnix-shell -p ", tools["run"])
        self.assertIn("\n  --run true\n", tools["run"])
        self.assertNotIn(".#", tools["run"])
        self.assertTrue(save["uses"].startswith("nix-community/cache-nix-action/save@"))
        self.assertEqual(save["if"],
                         "inputs.save-cache == 'true' && steps.cache.outputs.hit-primary-key != 'true'")
        self.assertEqual(save["with"], {"primary-key": "${{ steps.cache.outputs.primary-key }}"})
        self.assertNotIn("secrets.", json.dumps(self.action))
        # Combined cache actions save in a post-job hook, after private fetches.
        for step in steps:
            if "uses" in step:
                self.assertRegex(step["uses"], r"@[0-9a-f]{40}$")
                self.assertNotRegex(step["uses"], r"cache-nix-action@")

    def test_cache_is_shared_exact_and_invalidated_by_dependency_changes(self):
        restore = self.action["runs"]["steps"][1]
        key = restore["with"]["primary-key"]
        for required in ("runner.os", "runner.arch", "'flake.lock'",
                         "'.github/actions/pharos-nix/action.yml'", "'scripts/pharos-ci-nix.py'"):
            self.assertIn(required, key)
        self.assertNotIn("shard", key)
        self.assertNotIn("restore-prefixes", json.dumps(restore))

    def test_cache_fixtures_are_wired_in_the_independent_gate(self):
        steps = self.workflow["jobs"]["aeon-pin-gate"]["steps"]
        self.assertEqual(sum("test_pharos_ci.py" in step.get("run", "") for step in steps), 1)


class PublicInputFixtures(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.lock = json.loads((ROOT / "flake.lock").read_text())
        self.node = self.lock["nodes"][self.lock["nodes"][self.lock["root"]]["inputs"]["nixpkgs"]]["locked"]
        self.source = "/nix/store/" + "a" * 32 + "-source"
        self.result = {"hash": self.node["narHash"], "storePath": self.source}
        self.output = self.root / "github-env"

    def prepare(self, lock=None, result=None, error=None):
        lock_file = self.root / "flake.lock"
        lock_file.write_text(json.dumps(self.lock if lock is None else lock))
        with patch.object(setup.subprocess, "check_output",
                          return_value=json.dumps(self.result if result is None else result),
                          side_effect=error) as fetch:
            setup.prepare(lock_file, self.output)
        return fetch

    def test_only_the_locked_public_source_is_fetched_and_hash_verified(self):
        fetch = self.prepare()
        self.assertEqual(fetch.call_args.args[0], [
            "nix", "store", "prefetch-file", "--json", "--unpack", "--name", "source",
            "--expected-hash", self.node["narHash"],
            f"https://github.com/nixos/nixpkgs/archive/{self.node['rev']}.tar.gz",
        ])
        self.assertEqual(self.output.read_text(), f"NIX_PATH=nixpkgs={self.source}\n")

    def test_lock_node_name_is_resolved_from_the_root_not_assumed(self):
        node_name = self.lock["nodes"][self.lock["root"]]["inputs"]["nixpkgs"]
        self.lock["nodes"]["renamed"] = self.lock["nodes"].pop(node_name)
        self.lock["nodes"][self.lock["root"]]["inputs"]["nixpkgs"] = "renamed"
        self.prepare()
        self.assertTrue(self.output.exists())

    def test_private_mutable_and_malformed_inputs_fail_before_fetch(self):
        for field, bad in (("type", "git"), ("owner", "private-owner"),
                           ("repo", "another-input"), ("rev", "main"),
                           ("rev", "a" * 40 + "\ninjected=true"),
                           ("narHash", "sha256-not-a-digest")):
            with self.subTest(field=field), patch.object(setup.subprocess, "check_output") as fetch:
                lock = copy.deepcopy(self.lock)
                node = lock["nodes"][lock["nodes"][lock["root"]]["inputs"]["nixpkgs"]]["locked"]
                node[field] = bad
                lock_file = self.root / "flake.lock"
                lock_file.write_text(json.dumps(lock))
                with self.assertRaises(ValueError):
                    setup.prepare(lock_file, self.output)
                fetch.assert_not_called()
                self.assertFalse(self.output.exists())

    def test_hash_mismatch_or_unsafe_store_path_never_exports_nix_path(self):
        for result in (dict(self.result, hash="sha256-" + "A" * 43 + "="),
                       dict(self.result, storePath=self.source + "\nINJECTED=true"),
                       dict(self.result, storePath="/tmp/unverified-source")):
            with self.subTest(result=result), self.assertRaises(ValueError):
                self.prepare(result=result)
            self.assertFalse(self.output.exists())

    def test_fetch_failure_cannot_turn_into_a_cache_success(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.prepare(error=subprocess.CalledProcessError(1, ["nix"]))
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
