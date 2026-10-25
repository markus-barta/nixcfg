"""OPS-452: retained release verification, isolation, and retired-app fixtures."""

import contextlib
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "janus_pin_check", ROOT / "scripts/janus-engine-pin-check.py"
)
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)
CONTRACT = ROOT / "hosts/csb1/docker/janus/managed-service-production"


class Response(io.BytesIO):
    def __init__(self, body, headers=None):
        super().__init__(body)
        self.headers = headers or {}


class RetainedPinTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Real, offline Nix evaluation of precisely the metadata used in CI.
        # This must not depend on a NixOS build, flake fetch, Docker or secrets.
        cls.real_state = checker.load_state(
            ROOT / "hosts/csb1/docker/compose-spec.nix",
            ROOT / "hosts/csb1/shared-flow.nix",
        )
        cls.real_receipt = json.loads((CONTRACT / "release-admission.json").read_text())
        cls.real_policy = json.loads((CONTRACT / "release-channels-v1.json").read_text())

    def setUp(self):
        self.state = copy.deepcopy(self.real_state)
        self.receipt = copy.deepcopy(self.real_receipt)
        self.policy = copy.deepcopy(self.real_policy)
        self.manifests = {}
        self.releases = {}
        self.requests = []
        self.signatures = []
        for name in ("staged", "managed"):
            pin = checker.parse_pin(self.state[name]["image"], checker.IMAGE)
            manifest = json.dumps({"schemaVersion": 2, "fixture": name}).encode()
            digest = "sha256:" + hashlib.sha256(manifest).hexdigest()
            self.state[name]["image"] = f"{checker.IMAGE}:{pin['tag']}@{digest}"
            self.manifests[pin["tag"]] = (manifest, digest)
            self.releases[pin["tag"]] = {
                "tag_name": pin["tag"], "draft": False, "prerelease": False,
                "published_at": "2026-09-01T00:00:00Z",
                # The real retained release workflow uses this fixed name.
                "assets": [{"name": "rust-engine-sbom.spdx.json"}],
            }
            if name == "managed":
                self.state[name]["environment"] = ["JANUS_RELEASE_ARTIFACT_DIGEST=" + digest]
                self.receipt["artifact"]["digest"] = digest
                self.receipt["scanner"]["subject"] = checker.IMAGE + "@" + digest

    def fake_urlopen(self, request, timeout):
        self.assertEqual(timeout, 30)
        url = request.full_url
        self.requests.append(request)
        release_prefix = f"https://api.github.com/repos/{checker.REPOSITORY}/releases/tags/"
        if url.startswith(release_prefix):
            return Response(json.dumps(self.releases[url.removeprefix(release_prefix)]).encode())
        if url.startswith("https://ghcr.io/token?"):
            self.assertNotIn("Authorization", request.headers)
            return Response(b'{"token":"synthetic-pull-fixture"}')
        manifest_prefix = "https://ghcr.io/v2/inspr-at/janus/janus-engine/manifests/"
        if url.startswith(manifest_prefix):
            self.assertEqual(request.get_header("Authorization"), "Bearer synthetic-pull-fixture")
            body, digest = self.manifests[url.removeprefix(manifest_prefix)]
            return Response(body, {"Docker-Content-Digest": digest})
        self.fail("unexpected request, including a latest-release lookup: " + url)

    def fake_cosign(self, command, **kwargs):
        self.signatures.append(command)
        self.assertEqual(command[:2], ["cosign", "verify"])
        image, digest = command[-1].split("@")
        self.assertEqual(image, checker.IMAGE)
        tag = next(tag for tag, (_, expected) in self.manifests.items() if expected == digest)
        self.assertEqual(command[command.index("--certificate-identity") + 1],
                         f"https://github.com/{checker.REPOSITORY}/.github/workflows/rust.yml@refs/tags/{tag}")
        self.assertEqual(command[command.index("--certificate-oidc-issuer") + 1], checker.ISSUER)
        self.assertFalse(any("insecure" in arg or "ignore" in arg for arg in command))
        return subprocess.CompletedProcess(command, 0, json.dumps([
            {"critical": {"image": {"docker-manifest-digest": digest}}}
        ]), "")

    def run_fixture(self, args=None, opener=None, cosign=None, state_loader=None,
                    missing_receipt=False, **main_kwargs):
        stdout, stderr = io.StringIO(), io.StringIO()

        def read_evidence(path):
            if path == CONTRACT / "release-admission.json":
                if missing_receipt:
                    raise FileNotFoundError("fixture release-admission.json missing")
                return json.dumps(self.receipt)
            self.assertEqual(path, CONTRACT / "release-channels-v1.json")
            return json.dumps(self.policy)

        with (
            patch.object(checker, "load_state", return_value=self.state, side_effect=state_loader),
            patch.object(checker.Path, "read_text", autospec=True, side_effect=read_evidence),
            patch.object(checker, "urlopen", side_effect=opener or self.fake_urlopen),
            patch.object(checker.subprocess, "run", side_effect=cosign or self.fake_cosign),
            patch.dict(checker.os.environ, {
                "JANUS_ENGINE_GITHUB_TOKEN": "synthetic-github-fixture",
            }),
            contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr),
        ):
            status = checker.main(args or [], **main_kwargs)
        return status, stdout.getvalue(), stderr.getvalue()

    def test_checked_in_metadata_and_admission_are_consistent(self):
        pins = checker.check_local(self.real_state, self.real_receipt, self.real_policy)
        self.assertEqual(len(pins), 2)
        self.assertNotEqual(pins[0]["tag"], pins[1]["tag"])

    def test_real_nix_override_detects_reenabled_app(self):
        with tempfile.TemporaryDirectory(prefix="janus-retirement-fixture-") as directory:
            fixture = Path(directory) / "compose-spec.nix"
            # Override the actual service, rather than editing a textual match.
            compose = json.dumps(str(ROOT / "hosts/csb1/docker/compose-spec.nix"))
            fixture.write_text(
                f"let real = import (builtins.toPath {compose}); in real // {{ "
                "services = real.services // { janus = real.services.janus // { profiles = []; }; }; }"
            )
            state = checker.load_state(fixture, ROOT / "hosts/csb1/shared-flow.nix")
        with self.assertRaisesRegex(checker.CheckError, "must remain profile-gated as retired"):
            checker.check_local(state, self.real_receipt, self.real_policy)

    def test_good_fixture_verifies_both_retained_releases_and_actual_sbom_name(self):
        status, stdout, stderr = self.run_fixture()
        self.assertEqual(status, 0, stderr)
        self.assertIn("Janus app declared retired", stdout)
        self.assertIn("Pharos/staged", stdout)
        self.assertIn("managed transactiond", stdout)
        self.assertEqual(len(self.signatures), 2)
        self.assertEqual(len(self.requests), 6)
        for request in self.requests:
            if request.full_url.startswith("https://api.github.com/"):
                self.assertEqual(request.get_header("Authorization"), "Bearer synthetic-github-fixture")

    def test_production_inputs_ignore_environment_overrides(self):
        def load_defaults(compose, flow):
            self.assertEqual(compose, ROOT / "hosts/csb1/docker/compose-spec.nix")
            self.assertEqual(flow, ROOT / "hosts/csb1/shared-flow.nix")
            return self.state

        with patch.dict(checker.os.environ, {
            "JANUS_ENGINE_STAGED_COMPOSE_FILE": "/untrusted/compose-spec.nix",
            "JANUS_ENGINE_IMAGE_REPO": "ghcr.io/untrusted/engine",
            "JANUS_ENGINE_RELEASE_REPO": "untrusted/engine",
        }):
            status, _, stderr = self.run_fixture(state_loader=load_defaults)
        self.assertEqual(status, 0, stderr)
        self.assertEqual(len(self.requests), 6)

    def test_compose_override_is_a_python_keyword_argument(self):
        fixture = Path("fixture-compose-spec.nix")

        def load_fixture(compose, flow):
            self.assertEqual(compose, fixture)
            self.assertEqual(flow, ROOT / "hosts/csb1/shared-flow.nix")
            return self.state

        status, _, stderr = self.run_fixture(state_loader=load_fixture, compose=fixture)
        self.assertEqual(status, 0, stderr)

    def test_invalid_python_repository_arguments_remain_rejected(self):
        for overrides, message in (
            ({"image_repo": "https://untrusted.invalid/engine"}, "only ghcr.io"),
            ({"release_repo": "untrusted/engine/extra"}, "invalid release repository"),
        ):
            with self.subTest(overrides=overrides):
                status, _, stderr = self.run_fixture(**overrides)
                self.assertEqual(status, 1, stderr)
                self.assertIn(message, stderr)
                self.assertFalse(self.requests)

    def test_newer_release_does_not_invalidate_retained_pins(self):
        self.releases["rust-engine-v9.9.9"] = {
            "tag_name": "rust-engine-v9.9.9", "published_at": "2026-10-25T00:00:00Z",
            "draft": False, "prerelease": False, "assets": [],
        }
        status, _, stderr = self.run_fixture()
        self.assertEqual(status, 0, stderr)
        self.assertTrue(all("9.9.9" not in request.full_url for request in self.requests))

    def test_bad_local_fixtures_fail_before_network_access(self):
        cases = [
            ("janus", "profiles", [], "retired"),
            ("janus", "restart", "unless-stopped", "retired"),
            ("staged", "image", checker.IMAGE + ":latest", "immutable"),
            ("staged", "profiles", [], "staged engine"),
            ("staged", "network_mode", "host", "staged engine"),
            ("staged", "labels", ["traefik.enable=true"], "staged engine"),
            ("placeholder", "profiles", ["disabled"], "placeholder"),
            ("placeholder", "restart", "no", "placeholder"),
            ("placeholder", "volumes", [], "read-only"),
            ("placeholder", "image", "caddy:latest", "digest-pinned"),
            ("routing", "active", False, "routing"),
            ("routing", "upstream", "http://retired-app.invalid:8080", "routing"),
            ("managed", "network_mode", "host", "networkless"),
            ("managed", "environment", [], "environment digest"),
            ("managed", "image", self.state["staged"]["image"], "environment digest"),
        ]
        for section, key, bad, message in cases:
            with self.subTest(section=section, key=key):
                original = self.state[section][key]
                self.state[section][key] = bad
                status, _, stderr = self.run_fixture()
                self.assertEqual(status, 1, stderr)
                self.assertIn(message, stderr)
                self.assertFalse(self.requests)
                self.state[section][key] = original

    def test_admission_mismatch_is_red(self):
        self.receipt["artifact"]["digest"] = "sha256:" + "0" * 64
        status, _, stderr = self.run_fixture()
        self.assertEqual(status, 1)
        self.assertIn("admission receipt", stderr)

    def test_placeholder_mount_shadowing_fails_before_network_access(self):
        retained = copy.deepcopy(self.state["placeholder"]["volumes"])
        shadow_mounts = [
            {"type": "bind", "source": "./untrusted", "target": target, "read_only": True}
            for target in (
                "/srv/janus-placeholder/Caddyfile", "/srv/janus-placeholder",
                "/srv/janus-placeholder/index.html", "/srv", "/",
                "/srv/janus-placeholder/", "/srv/./janus-placeholder/Caddyfile",
                "/srv/other/../janus-placeholder/Caddyfile", "//srv/janus-placeholder/Caddyfile",
            )
        ] + [
            retained[0],
            {"type": "volume", "source": "untrusted", "target": "/srv/janus-placeholder"},
            "./untrusted:/srv/janus-placeholder/Caddyfile:ro",
        ]
        for mount in shadow_mounts:
            with self.subTest(mount=mount):
                self.state["placeholder"]["volumes"] = retained + [mount]
                status, _, stderr = self.run_fixture()
                self.assertEqual(status, 1, stderr)
                self.assertIn("read-only", stderr)
                self.assertFalse(self.requests)

    def test_placeholder_bind_must_remain_read_only_and_not_create_paths(self):
        retained = copy.deepcopy(self.state["placeholder"]["volumes"])
        for key, value in (("read_only", False), ("bind", {"create_host_path": True})):
            with self.subTest(key=key):
                self.state["placeholder"]["volumes"] = copy.deepcopy(retained)
                self.state["placeholder"]["volumes"][0][key] = value
                status, _, stderr = self.run_fixture()
                self.assertEqual(status, 1, stderr)
                self.assertIn("read-only", stderr)
                self.assertFalse(self.requests)

    def test_unrelated_placeholder_bind_does_not_shadow_retained_files(self):
        self.state["placeholder"]["volumes"].append({
            "type": "bind", "source": "./cache", "target": "/srv/janus-placeholder-cache",
            "read_only": True,
        })
        status, _, stderr = self.run_fixture()
        self.assertEqual(status, 0, stderr)

    def test_unverified_admission_is_red(self):
        for key in ("signature", "provenance", "sbom", "source", "scanner"):
            with self.subTest(key=key):
                self.receipt[key]["verified"] = False
                status, _, stderr = self.run_fixture()
                self.assertEqual(status, 1, stderr)
                self.receipt[key]["verified"] = True

    def test_admission_scanner_subject_or_findings_are_red(self):
        for key, bad in (("subject", checker.IMAGE + "@sha256:" + "0" * 64), ("critical", 1), ("high", 1)):
            with self.subTest(key=key):
                original = self.receipt["scanner"][key]
                self.receipt["scanner"][key] = bad
                status, _, stderr = self.run_fixture()
                self.assertEqual(status, 1)
                self.assertIn("scanner admission", stderr)
                self.receipt["scanner"][key] = original

    def test_changed_channel_verifier_is_red(self):
        self.policy["channels"][0]["oidc_issuer"] = "https://untrusted.invalid"
        status, _, stderr = self.run_fixture()
        self.assertEqual(status, 1)
        self.assertIn("verification policy", stderr)

    def test_authenticated_redirect_is_refused(self):
        request = checker.Request("https://api.github.com/fixture", headers={"Authorization": "Bearer synthetic-fixture"})
        with self.assertRaisesRegex(checker.CheckError, "unexpected redirect"):
            checker.NoRedirects().redirect_request(request, None, 302, "redirect", {}, "https://untrusted.invalid/")

    def test_revoked_pin_is_red_for_either_engine(self):
        for _, digest in self.manifests.values():
            with self.subTest(digest=digest):
                self.policy["revoked_digests"] = [digest]
                status, _, stderr = self.run_fixture()
                self.assertEqual(status, 1)
                self.assertIn("revoked", stderr)

    def test_unpublished_or_unrelated_release_is_red(self):
        tag = next(iter(self.releases))
        for key, bad in (("draft", True), ("prerelease", True), ("published_at", None), ("tag_name", "rust-engine-v9.9.9")):
            with self.subTest(key=key):
                original = self.releases[tag][key]
                self.releases[tag][key] = bad
                status, _, stderr = self.run_fixture()
                self.assertEqual(status, 1)
                self.assertIn("published stable release", stderr)
                self.releases[tag][key] = original

    def test_absent_sbom_or_digest_in_unrelated_filename_is_red(self):
        tag = next(iter(self.releases))
        for assets in ([], [{"name": self.manifests[tag][1] + ".txt"}]):
            with self.subTest(assets=assets):
                self.releases[tag]["assets"] = assets
                status, _, stderr = self.run_fixture()
                self.assertEqual(status, 1)
                self.assertIn("SPDX SBOM", stderr)

    def test_registry_digest_mismatch_is_red(self):
        tag = next(iter(self.manifests))
        body, _ = self.manifests[tag]
        self.manifests[tag] = (body, "sha256:" + "0" * 64)
        status, _, stderr = self.run_fixture()
        self.assertEqual(status, 1)
        self.assertIn("tag digest", stderr)

    def test_registry_body_mismatch_is_red(self):
        tag = next(iter(self.manifests))
        _, digest = self.manifests[tag]
        self.manifests[tag] = (b"corrupt manifest", digest)
        status, _, stderr = self.run_fixture()
        self.assertEqual(status, 1)
        self.assertIn("manifest bytes", stderr)

    def test_signature_failure_or_wrong_subject_is_red(self):
        for result in (
            subprocess.CompletedProcess([], 1, "", "verification failed"),
            subprocess.CompletedProcess([], 0, "[]", ""),
            subprocess.CompletedProcess([], 0, json.dumps([
                {"critical": {"image": {"docker-manifest-digest": "sha256:" + "0" * 64}}}
            ]), ""),
        ):
            with self.subTest(result=result):
                status, _, stderr = self.run_fixture(cosign=lambda *args, **kwargs: result)
                self.assertEqual(status, 1, stderr)
                self.assertIn("signature", stderr)

    def test_missing_or_malformed_evidence_is_an_error(self):
        for error in (
            HTTPError("https://api.github.com/fixture", 404, "not found", {}, None),
            URLError("fixture network unavailable"),
        ):
            with self.subTest(error=error):
                def fail_request(*args, **kwargs):
                    raise error

                status, stdout, stderr = self.run_fixture(opener=fail_request)
                self.assertEqual(status, 2)
                self.assertEqual(stdout, "")
                self.assertNotIn("synthetic-github-fixture", stderr)
        status, _, stderr = self.run_fixture(opener=lambda *args, **kwargs: Response(b"not JSON"))
        self.assertEqual(status, 2, stderr)

    def test_nonzero_nix_eval_exits_two_before_network_access(self):
        calls = []

        def failed_nix(command, **kwargs):
            self.assertEqual(command[:2], ["nix", "eval"])
            calls.append(command)
            return subprocess.CompletedProcess(command, 1, "", "fixture eval failed")

        status, stdout, stderr = self.run_fixture(state_loader=checker.load_state, cosign=failed_nix)
        self.assertEqual(status, 2, stderr)
        self.assertEqual(stdout, "")
        self.assertIn("could not evaluate", stderr)
        self.assertEqual(len(calls), 1)
        self.assertFalse(self.requests)
        self.assertNotIn("synthetic-github-fixture", stderr)

    def test_missing_release_admission_exits_two_before_network_access(self):
        status, stdout, stderr = self.run_fixture(missing_receipt=True)
        self.assertEqual(status, 2, stderr)
        self.assertEqual(stdout, "")
        self.assertIn("evidence unavailable", stderr)
        self.assertFalse(self.requests)
        self.assertFalse(self.signatures)
        self.assertNotIn("synthetic-github-fixture", stderr)

    def test_quiet_suppresses_only_success(self):
        status, stdout, stderr = self.run_fixture(["--quiet"])
        self.assertEqual((status, stdout, stderr), (0, "", ""))
        self.state["janus"]["profiles"] = []
        status, stdout, stderr = self.run_fixture(["--quiet"])
        self.assertEqual(status, 1)
        self.assertEqual(stdout, "")
        self.assertIn("retired", stderr)

    def test_shell_entrypoint_help_and_unknown_arguments(self):
        entrypoint = ROOT / "scripts/janus-engine-pin-check.sh"
        help_result = subprocess.run(["bash", str(entrypoint), "--help"], capture_output=True, text=True, check=False)
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertIn("retained engine pins", help_result.stdout)
        bad_result = subprocess.run(["bash", str(entrypoint), "--bad"], capture_output=True, text=True, check=False)
        self.assertEqual(bad_result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
