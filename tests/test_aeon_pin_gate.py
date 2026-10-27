"""Real git-diff fixtures and fail-closed provenance checks for NIX-591."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import sys
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("aeon_pin_gate", ROOT / "scripts/aeon-pin-gate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
OLD = "260929232203.0.0"
NEW = "260930075300.0.0"
OLD_DIGEST = "sha256:" + "a" * 64
NEW_DIGEST = "sha256:" + "b" * 64
PIN = {"version": NEW, "digest": NEW_DIGEST}
TAG_SHA = "c" * 40
MAIN_SHA = "d" * 40


def compose(version=OLD, digest=OLD_DIGEST, service="aeon", image="aeon"):
    return (
        "{\n  # release header\n" + "  # context\n" * 8 + "  services = {\n"
        f"    {service} = {{\n"
        f'      image = "ghcr.io/inspr-at/{image}:{version}@{digest}"; # release\n'
        '      restart = "unless-stopped";\n'
        "    };\n  };\n}\n"
    )


class DiffFixtures(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / "tests/.tmp"
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="aeon-pin-", dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        # Hosted runners have no git author configured. Reuse an existing
        # repository author for these disposable fixtures, without changing
        # machine config or putting an identity in the test source/logs.
        author = subprocess.check_output(
            ["git", "-C", str(ROOT), "log", "-1", "--format=%an%n%ae"]
        ).decode().splitlines()
        self.git_env = dict(os.environ)
        self.git_env.update(
            GIT_AUTHOR_NAME=author[0], GIT_COMMITTER_NAME=author[0],
            GIT_AUTHOR_EMAIL=author[1], GIT_COMMITTER_EMAIL=author[1],
        )
        self.git("init", "-q")
        self.path = self.repo / gate.PIN_PATH
        self.path.parent.mkdir(parents=True)
        self.path.write_text(compose())
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(
            ["git", "-C", str(self.repo), *args], stderr=subprocess.PIPE, env=self.git_env
        ).decode().strip()

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "pin fixture")
        return self.git("rev-parse", "HEAD")

    def classify(self):
        return gate.classify(self.repo, self.base, self.commit())

    def test_pin_only_with_release_comment(self):
        self.path.write_text(compose(NEW, NEW_DIGEST).replace("; # release\n", "; # next release\n"))
        self.assertEqual(self.classify(), PIN)

    def test_second_hunk_runs_full_suite(self):
        self.path.write_text(compose(NEW, NEW_DIGEST).replace("# release header", "# updated release header"))
        self.assertIsNone(self.classify())
        diff = self.git("diff", "--unified=3", self.base, "HEAD")
        self.assertEqual(sum(line.startswith("@@ ") for line in diff.splitlines()), 2)

    def test_adjacent_service_change_runs_full_suite(self):
        self.path.write_text(compose(NEW, NEW_DIGEST).replace('restart = "unless-stopped"', 'restart = "always"'))
        self.assertIsNone(self.classify())

    def test_other_services_image_in_same_shape_runs_full_suite(self):
        self.path.write_text(compose(service="pharos", image="pharos"))
        self.base = self.commit()
        self.path.write_text(compose(NEW, NEW_DIGEST, service="pharos", image="pharos"))
        self.assertIsNone(self.classify())

    def test_other_service_using_aeon_image_runs_full_suite(self):
        self.path.write_text(compose(service="another"))
        self.base = self.commit()
        self.path.write_text(compose(NEW, NEW_DIGEST, service="another"))
        self.assertIsNone(self.classify())

    def test_second_file_runs_full_suite_without_reading_its_content(self):
        self.path.write_text(compose(NEW, NEW_DIGEST))
        (self.repo / "other.txt").write_text("unrelated fixture")
        head = self.commit()
        with patch.object(gate, "command", wraps=gate.command) as calls:
            self.assertIsNone(gate.classify(self.repo, self.base, head))
        self.assertFalse(any("show" in call.args[0] for call in calls.call_args_list))

    def test_mode_change_runs_full_suite(self):
        self.path.write_text(compose(NEW, NEW_DIGEST))
        self.git("update-index", "--chmod=+x", gate.PIN_PATH)
        self.git("commit", "-qm", "mode fixture")
        self.assertIsNone(gate.classify(self.repo, self.base, self.git("rev-parse", "HEAD")))

    def test_missing_digest_wrong_version_and_comment_only_run_full_suite(self):
        for text in (compose(NEW, "sha256:" + "b" * 63), compose("latest", NEW_DIGEST), compose().replace("; # release\n", "; # comment\n")):
            with self.subTest(text=text):
                self.path.write_text(text)
                self.assertIsNone(self.classify())

    def test_deleted_or_inserted_line_runs_full_suite(self):
        self.path.write_text(compose(NEW, NEW_DIGEST) + "# extra line\n")
        self.assertIsNone(self.classify())

    def test_merge_group_checks_aggregate_not_last_commit(self):
        (self.repo / "other.txt").write_text("first queued PR")
        self.commit()
        self.path.write_text(compose(NEW, NEW_DIGEST))
        self.assertIsNone(self.classify())

    def test_pull_request_uses_merge_base(self):
        branch = self.git("symbolic-ref", "--short", "HEAD")
        self.git("checkout", "-qb", "pin")
        self.path.write_text(compose(NEW, NEW_DIGEST))
        head = self.commit()
        self.git("checkout", "-q", branch)
        (self.repo / "base-only.txt").write_text("base branch advanced")
        base = self.commit()
        self.assertEqual(gate.classify(self.repo, base, head), PIN)

    def test_empty_diff_manual_dispatch_initial_push_and_invalid_shas(self):
        self.assertIsNone(gate.classify(self.repo, self.base, self.base))
        self.assertIsNone(gate.classify(self.repo, "", self.base))
        self.assertIsNone(gate.classify(self.repo, "0" * 40, self.base))
        with self.assertRaises(gate.GateError):
            gate.classify(self.repo, "--bad", self.base)
        with self.assertRaises(gate.GateError):
            gate.classify(self.repo, "e" * 40, self.base)


class RegistryFixtures(unittest.TestCase):
    def setUp(self):
        self.payload = b'{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json"}'
        self.digest = "sha256:" + hashlib.sha256(self.payload).hexdigest()
        self.pin = {"version": NEW, "digest": self.digest}
        self.responses = [
            (b'{"token":"synthetic-fixture"}', {}),
            (self.payload, {"Docker-Content-Digest": self.digest}),
            (self.payload, {"Docker-Content-Digest": self.digest}),
        ]

    def test_tag_and_digest_manifest_bytes_are_verified(self):
        with patch.object(gate, "registry_get", side_effect=self.responses) as request:
            gate.verify_registry(self.pin)
        urls = [call.args[0] for call in request.call_args_list]
        self.assertTrue(urls[1].endswith("/" + NEW))
        self.assertTrue(urls[2].endswith("/" + self.digest))

    def test_tag_mismatch_missing_digest_and_forged_header_fail(self):
        failures = (
            [self.responses[0], (self.payload, {"Docker-Content-Digest": NEW_DIGEST})],
            [*self.responses[:2], gate.GateError("registry request failed")],
            [self.responses[0], (b'{"schemaVersion":2}', {"Docker-Content-Digest": self.digest})],
            [self.responses[0], (self.payload, {})],
        )
        for responses in failures:
            with self.subTest(responses=responses), patch.object(gate, "registry_get", side_effect=responses):
                with self.assertRaises(gate.GateError):
                    gate.verify_registry(self.pin)

    def test_registry_error_is_redacted(self):
        for error in (
            gate.urllib.error.URLError("untrusted server diagnostic"),
            gate.http.client.IncompleteRead(b"synthetic truncated response", 100),
        ):
            with self.subTest(error=type(error).__name__), patch.object(gate.urllib.request, "build_opener") as opener:
                opener.return_value.open.side_effect = error
                with self.assertRaisesRegex(gate.GateError, "^registry request failed$"):
                    gate.registry_get("https://ghcr.io/v2/inspr-at/aeon/manifests/missing")

    def test_redirects_are_rejected(self):
        with self.assertRaises(gate.GateError):
            gate.NoRedirect().redirect_request(None, None, 302, "redirect", {}, "https://elsewhere.invalid/")


class GitTransportFixtures(unittest.TestCase):
    # Real local Git graph and upload-pack, with a synthetic SSH executable.
    # Production ls-remote/fetch/peeling/merge-base commands all run unchanged;
    # no request reaches the network and no real private key is used.
    git = DiffFixtures.git
    commit = DiffFixtures.commit

    def setUp(self):
        DiffFixtures.setUp(self)
        if self.git("symbolic-ref", "--short", "HEAD") != "main":
            self.git("branch", "-m", "main")
        self.scratch = self.repo / ".git" / "scratch"
        self.scratch.mkdir()
        fake_bin = self.repo / ".git" / "bin"
        fake_bin.mkdir()
        ssh = fake_bin / "ssh"
        ssh.write_text(f"#!{sys.executable}\n" + r'''
import json, os, pathlib, stat, sys
args = sys.argv[1:]
assert args[:2] == ['-F', '/dev/null']
assert all(x in args for x in ['IdentitiesOnly=yes', 'BatchMode=yes',
                              'ConnectTimeout=15', 'StrictHostKeyChecking=yes',
                              'GlobalKnownHostsFile=/dev/null'])
key = pathlib.Path(args[args.index('-i') + 1])
assert key.read_text() == os.environ['FIXTURE_KEY'] + '\n'
assert stat.S_IMODE(key.stat().st_mode) == 0o600
assert stat.S_IMODE(key.parent.stat().st_mode) == 0o700
known = next(x.split('=', 1)[1] for x in args if x.startswith('UserKnownHostsFile='))
assert pathlib.Path(known).read_text() == os.environ['FIXTURE_HOST_KEY'] + '\n'
assert 'PAIMOS_DEPLOY_KEY' not in os.environ
assert args[-2:] == ['git@github.com', "git-upload-pack '/inspr-at/paimos.git'"]
os.execvp('git', ['git', 'upload-pack', os.environ['FIXTURE_GIT_REMOTE']])
''')
        ssh.chmod(0o700)
        self.fixture_key = "OPS-480 synthetic SSH fixture"
        self.child_env = {
            'PATH': str(fake_bin) + os.pathsep + os.environ['PATH'],
            'RUNNER_TEMP': str(self.scratch), 'PAIMOS_DEPLOY_KEY': self.fixture_key,
            'FIXTURE_KEY': self.fixture_key, 'FIXTURE_HOST_KEY': gate.GITHUB_HOST_KEY,
            'FIXTURE_GIT_REMOTE': str(self.repo), 'GIT_SSH_VARIANT': 'ssh',
            'GIT_SSH_COMMAND': 'existing hausnetz override',
        }

    def verify(self):
        try:
            # tempfile caches its directory per process; pin it to this test's scratch.
            with patch.dict(os.environ, self.child_env), patch.object(tempfile, "tempdir", str(self.scratch)):
                return gate.verify_tag(PIN)
        finally:
            self.assertEqual(list(self.scratch.iterdir()), [])

    def advance(self):
        self.path.write_text(self.path.read_text() + "# advance fixture\n")
        return self.commit()

    def test_lightweight_tag_ancestor_of_main(self):
        self.git("tag", "v" + NEW)
        self.advance()
        self.assertEqual(self.verify(), self.base)

    def test_annotated_tag_identical_to_main(self):
        self.git("tag", "-a", "v" + NEW, "-m", "release fixture")
        self.assertEqual(self.verify(), self.base)

    def test_nested_annotated_tag(self):
        self.git("tag", "-a", "inner", "-m", "inner fixture")
        self.git("tag", "-a", "v" + NEW, "inner", "-m", "release fixture")
        self.advance()
        self.assertEqual(self.verify(), self.base)

    def test_off_main_tag_is_rejected(self):
        self.git("checkout", "-qb", "release")
        self.advance()
        self.git("tag", "v" + NEW)
        self.git("checkout", "-q", "main")
        with self.assertRaisesRegex(gate.GateError, "not on paimos main"):
            self.verify()

    def test_diverged_tag_is_rejected(self):
        self.git("checkout", "-qb", "release")
        self.advance()
        self.git("tag", "v" + NEW)
        self.git("checkout", "-q", "main")
        (self.repo / "main-only").write_text("main fixture")
        self.commit()
        with self.assertRaisesRegex(gate.GateError, "not on paimos main"):
            self.verify()

    def test_missing_tag_fails_and_removes_key(self):
        with self.assertRaisesRegex(gate.GateError, "tag or main is missing"):
            self.verify()

    def test_blob_tag_is_rejected(self):
        blob = self.git("hash-object", str(self.path))
        self.git("tag", "v" + NEW, blob)
        with self.assertRaises(gate.GateError):
            self.verify()

    def test_malformed_or_duplicate_advertisements_fail(self):
        for payload in (b"not a ref", b"\xff", (f"{TAG_SHA}\trefs/heads/main\n" * 2).encode(),
                        f"{TAG_SHA}\trefs/heads/unexpected\n".encode()):
            with self.subTest(payload=payload), self.assertRaises(gate.GateError):
                gate.advertised_refs(payload, {"refs/heads/main"})

    def test_ref_race_is_rejected(self):
        self.git("tag", "v" + NEW)
        original = gate.command

        def move_after_advertising(args, **kwargs):
            if "fetch" in args:
                self.advance()
                self.git("tag", "-f", "v" + NEW)
            return original(args, **kwargs)

        with patch.object(gate, "command", side_effect=move_after_advertising):
            with self.assertRaisesRegex(gate.GateError, "refs changed"):
                self.verify()

    def test_ssh_failure_redacts_output_and_cleans_key(self):
        with patch.object(gate.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 1, stdout=self.fixture_key.encode(), stderr=self.fixture_key.encode())):
            with self.assertRaises(gate.GateError) as caught:
                self.verify()
        self.assertIn("PAIMOS_DEPLOY_KEY", str(caught.exception))
        self.assertNotIn(self.fixture_key, str(caught.exception))

    def test_missing_key_uses_anonymous_git_while_public(self):
        self.git("tag", "v" + NEW)
        self.child_env['PAIMOS_DEPLOY_KEY'] = ''
        with patch.object(gate, "PUBLIC_REMOTE", str(self.repo)), patch.object(gate, "command", wraps=gate.command) as requests:
            self.assertEqual(self.verify(), self.base)
        for call in requests.call_args_list:
            self.assertEqual(call.kwargs['env']['GIT_SSH_COMMAND'], 'false')
            self.assertIn('credential.helper=', call.args[0])

    def test_git_commands_ignore_checkout_credentials_and_config(self):
        self.git("tag", "v" + NEW)
        with patch.object(gate, "command", wraps=gate.command) as calls:
            self.assertEqual(self.verify(), self.base)
        for call in calls.call_args_list:
            options = call.kwargs
            self.assertTrue(options['cwd'].is_relative_to(self.scratch))
            self.assertEqual(options['env']['GIT_CONFIG_GLOBAL'], '/dev/null')
            self.assertEqual(options['env']['GIT_CONFIG_NOSYSTEM'], '1')
            self.assertEqual(options['env']['GIT_CONFIG_COUNT'], '0')
            self.assertNotIn('PAIMOS_DEPLOY_KEY', options['env'])

    def test_private_repo_without_key_has_clear_failure(self):
        self.child_env['PAIMOS_DEPLOY_KEY'] = ''
        with patch.object(gate, "command", side_effect=gate.GateError("git request failed")):
            with self.assertRaisesRegex(gate.GateError, "PAIMOS_DEPLOY_KEY is required"):
                self.verify()


class JobFixtures(unittest.TestCase):
    def run_mode(self, mode, pin):
        output = io.StringIO()
        with patch.object(gate, "classify", return_value=pin), patch.object(gate.sys, "argv", ["gate", mode]), contextlib.redirect_stdout(output):
            gate.main()
        return output.getvalue()

    def test_non_pin_gate_reports_without_network(self):
        with patch.object(gate, "registry_get", side_effect=AssertionError("network")), patch.object(gate, "verify_tag", side_effect=AssertionError("network")):
            self.assertIn("aeon_pin_gate=not_applicable", self.run_mode("verify", None))

    def test_successful_verification_preserves_exact_output(self):
        with patch.object(gate, "verify_registry"), patch.object(gate, "verify_tag", return_value=TAG_SHA):
            output = self.run_mode("verify", PIN)
        self.assertEqual(output, f"aeon_pin_gate=verified digest={NEW_DIGEST} tag_commit={TAG_SHA}\n"
                         "attestation_verification=deferred dependency=AEON-407\n")

    def test_pin_classifier_logs_zero_tests(self):
        output = self.run_mode("classify", PIN)
        self.assertEqual(output.splitlines()[0], "pin_only=true")
        self.assertIn("pharos_fast_lane=pin_only tests_ran=0", output)

    def test_non_pin_classifier_requests_full_suite(self):
        output = self.run_mode("classify", None)
        self.assertEqual(output.splitlines()[0], "pin_only=false")
        self.assertIn("pharos_fast_lane=full_suite", output)


class WorkflowFixtures(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # The existing Actions pin gate uses Ruby/Psych too; no new dependency.
        cls.workflow = json.loads(subprocess.check_output([
            "ruby", "-rjson", "-rpsych", "-e",
            "puts JSON.generate(Psych.load_file(ARGV[0]))",
            str(ROOT / ".github/workflows/check.yml"),
        ]))

    def test_every_existing_pharos_step_runs_for_non_pin_diffs(self):
        for shard in self.workflow["jobs"]["pharos-rollout"]["needs"]:
            steps = self.workflow["jobs"][shard]["steps"]
            self.assertEqual(steps[0]["with"]["fetch-depth"], 0)
            self.assertEqual(steps[1]["id"], "pin")
            self.assertIn(" classify", steps[1]["run"])
            # Only the validated pin_only line may reach the step outputs.
            self.assertIn("grep -E '^pin_only=(true|false)$'", steps[1]["run"])
            self.assertIn('>> "$GITHUB_OUTPUT"', steps[1]["run"])
            for step in steps[2:]:
                with self.subTest(shard=shard, step=step.get("name", step.get("uses"))):
                    # Cleanup also runs after T38 fails; exact pin-only diffs
                    # still skip every rollout step, including cleanup.
                    expected = "steps.pin.outputs.pin_only != 'true'"
                    if step.get("name") == "Clean up private hsb0 input access (OPS-355)":
                        expected = "always() && " + expected
                    self.assertEqual(step["if"], expected)

    def test_required_check_fails_unless_all_shards_succeed(self):
        job = self.workflow["jobs"]["pharos-rollout"]
        self.assertEqual(job["name"], "Pharos fleet release compatibility")
        self.assertEqual(job["if"], "always()")
        shards = {name for name in self.workflow["jobs"] if name.startswith("pharos-contracts-")}
        self.assertEqual(len(shards), 4)
        self.assertEqual(set(job["needs"]), shards)
        step, = job["steps"]
        self.assertEqual(step["env"]["SHARD_RESULTS"], "${{ join(needs.*.result, ' ') }}")
        # Execute the actual gate for every possible terminal result tuple.
        import itertools
        for results in itertools.product(("success", "failure", "cancelled", "skipped"), repeat=4):
            result = subprocess.run(["bash", "-e", "-c", step["run"]],
                                    env={"SHARD_RESULTS": " ".join(results)}, capture_output=True)
            self.assertEqual(result.returncode == 0, all(value == "success" for value in results), results)

    def test_shards_keep_job_local_prerequisites(self):
        shards = [self.workflow["jobs"][name]["steps"]
                  for name in self.workflow["jobs"]["pharos-rollout"]["needs"]]
        private, = [steps for steps in shards if any(step.get("id") == "hausnetz-input" for step in steps)]
        evidence, = [i for i, step in enumerate(private) if "tests/T38-" in step.get("run", "")]
        self.assertEqual(private[evidence - 1]["id"], "hausnetz-input")
        self.assertEqual(private[evidence + 1]["name"], "Clean up private hsb0 input access (OPS-355)")
        for test in ("T64-fleet-nix-maintenance.sh", "T54-doctrine-private-fleet-boundary.sh",
                     "T68-ncps-warmer-fleet.sh", "T99-hausnetz-hsb0.sh"):
            consumer, = [i for i, step in enumerate(private) if test in step.get("run", "")]
            self.assertGreater(consumer, evidence + 1)
        routing, = [steps for steps in shards if any("git submodule update" in step.get("run", "") for step in steps)]
        checkout, = [i for i, step in enumerate(routing) if "git submodule update" in step.get("run", "")]
        for test in ("T88-model-role-lint.sh", "T80-shared-flow-activation.sh", "T103-traefik-api-auth.py"):
            consumer, = [i for i, step in enumerate(routing) if test in step.get("run", "")]
            self.assertGreater(consumer, checkout)

    def test_gate_always_reports_and_both_jobs_use_the_aggregate_diff(self):
        gate_job = self.workflow["jobs"]["aeon-pin-gate"]
        self.assertEqual(gate_job["if"], "always()")
        self.assertEqual(gate_job["name"], "aeon-pin-gate")
        self.assertEqual(gate_job["permissions"], {"contents": "read"})
        self.assertEqual(gate_job["steps"][0]["with"]["fetch-depth"], 0)
        verify = gate_job["steps"][-1]
        self.assertEqual(verify["env"]["PAIMOS_DEPLOY_KEY"], "${{ secrets.PAIMOS_DEPLOY_KEY }}")
        self.assertNotIn("GH_TOKEN", verify["env"])
        classifiers = [self.workflow["jobs"][shard]["steps"][1]
                       for shard in self.workflow["jobs"]["pharos-rollout"]["needs"]]
        for step in (*classifiers, verify):
            self.assertEqual(step["env"]["HEAD_SHA"], "${{ github.sha }}")
            self.assertEqual(step["env"]["BASE_SHA"], "${{ github.event.pull_request.base.sha || github.event.merge_group.base_sha || github.event.before }}")
        triggers = self.workflow.get("on", self.workflow.get("true"))
        self.assertEqual(triggers["merge_group"], {"types": ["checks_requested"]})
        self.assertNotIn("pull_request_target", triggers)


if __name__ == "__main__":
    unittest.main()
