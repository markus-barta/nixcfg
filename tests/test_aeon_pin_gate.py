"""Real git-diff fixtures and fail-closed provenance checks for NIX-591."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
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


class GitHubFixtures(unittest.TestCase):
    def responses(self, status="ahead", merge_base=TAG_SHA):
        return [
            {"object": {"type": "commit", "sha": TAG_SHA}},
            {"object": {"type": "commit", "sha": MAIN_SHA}},
            {"status": status, "base_commit": {"sha": TAG_SHA}, "merge_base_commit": {"sha": merge_base}},
        ]

    def test_lightweight_and_annotated_tags_on_main(self):
        for status in ("ahead", "identical"):
            with self.subTest(status=status), patch.object(gate, "github_get", side_effect=self.responses(status)):
                self.assertEqual(gate.verify_tag(PIN), TAG_SHA)
        responses = self.responses()
        responses[0] = {"object": {"type": "tag", "sha": "e" * 40}}
        responses.insert(1, {"object": {"type": "commit", "sha": TAG_SHA}})
        with patch.object(gate, "github_get", side_effect=responses):
            self.assertEqual(gate.verify_tag(PIN), TAG_SHA)

    def test_off_main_and_wrong_merge_base_fail(self):
        for status, merge_base in (("behind", TAG_SHA), ("diverged", TAG_SHA), ("ahead", MAIN_SHA)):
            with self.subTest(status=status), patch.object(gate, "github_get", side_effect=self.responses(status, merge_base)):
                with self.assertRaises(gate.GateError):
                    gate.verify_tag(PIN)

    def test_missing_or_invalid_tag_fails(self):
        for result in (gate.GateError("GitHub request failed"), {}, {"object": {"type": "blob", "sha": TAG_SHA}}):
            with self.subTest(result=result), patch.object(gate, "github_get", side_effect=[result]):
                with self.assertRaises(gate.GateError):
                    gate.verify_tag(PIN)


class JobFixtures(unittest.TestCase):
    def run_mode(self, mode, pin):
        output = io.StringIO()
        with patch.object(gate, "classify", return_value=pin), patch.object(gate.sys, "argv", ["gate", mode]), contextlib.redirect_stdout(output):
            gate.main()
        return output.getvalue()

    def test_non_pin_gate_reports_without_network(self):
        with patch.object(gate, "registry_get", side_effect=AssertionError("network")), patch.object(gate, "github_get", side_effect=AssertionError("network")):
            self.assertIn("aeon_pin_gate=not_applicable", self.run_mode("verify", None))

    def test_pin_classifier_logs_zero_tests(self):
        with patch.dict(os.environ, {"GITHUB_OUTPUT": ""}):
            self.assertIn("pharos_fast_lane=pin_only tests_ran=0", self.run_mode("classify", PIN))


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
        steps = self.workflow["jobs"]["pharos-rollout"]["steps"]
        self.assertEqual(steps[0]["with"]["fetch-depth"], 0)
        self.assertEqual(steps[1]["id"], "pin")
        self.assertIn(" classify", steps[1]["run"])
        for step in steps[2:]:
            with self.subTest(step=step.get("name", step.get("uses"))):
                self.assertEqual(step["if"], "steps.pin.outputs.pin_only != 'true'")

    def test_gate_always_reports_and_both_jobs_use_the_aggregate_diff(self):
        gate_job = self.workflow["jobs"]["aeon-pin-gate"]
        self.assertEqual(gate_job["if"], "always()")
        self.assertEqual(gate_job["name"], "aeon-pin-gate")
        self.assertEqual(gate_job["permissions"], {"contents": "read"})
        self.assertEqual(gate_job["steps"][0]["with"]["fetch-depth"], 0)
        classify = self.workflow["jobs"]["pharos-rollout"]["steps"][1]
        verify = gate_job["steps"][-1]
        for step in (classify, verify):
            self.assertEqual(step["env"]["HEAD_SHA"], "${{ github.sha }}")
            self.assertEqual(step["env"]["BASE_SHA"], "${{ github.event.pull_request.base.sha || github.event.merge_group.base_sha || github.event.before }}")
        triggers = self.workflow.get("on", self.workflow.get("true"))
        self.assertEqual(triggers["merge_group"], {"types": ["checks_requested"]})
        self.assertNotIn("pull_request_target", triggers)


if __name__ == "__main__":
    unittest.main()
