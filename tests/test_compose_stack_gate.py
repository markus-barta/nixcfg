"""Keep the compose gate usable after a host retires its migration YAML."""

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import compose_stack_gate as gate


class ComposeStackGateTest(unittest.TestCase):
    def test_discovers_nix_and_legacy_hosts_once(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            for relative in (
                "hosts/hsb1/docker/compose-spec.nix",
                "hosts/csb0/docker/compose-spec.nix",
                "hosts/csb0/docker/docker-compose.yml",
            ):
                path = repo / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            with patch.object(gate, "REPO", repo):
                self.assertEqual(gate.known_hosts(), ["csb0", "hsb1"])

    def test_nix_baseline_uses_the_host_spec_option(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(gate, "REPO", Path(directory)), patch.object(
                gate, "run", return_value='{"services": {}}'
            ) as run:
                self.assertEqual(gate.original_spec("hsb1"), {"services": {}})
                run.assert_called_once_with(
                    ["nix", "eval", "--json", ".#nixosConfigurations.hsb1.config.nixcfg.composeStack.spec"]
                )

    def test_rendering_still_rejects_changed_services_mounts_and_dns(self):
        expected = {
            "services": {
                "edge": {"network_mode": "host", "volumes": ["/data:/data"]},
                "bridge": {"image": "example:1"},
            }
        }
        rendered = json.loads(json.dumps(expected))
        rendered["services"]["edge"]["dns"] = ["192.0.2.1"]
        mutants = {}
        for name in ("dropped service", "changed mount", "missing host DNS", "bridge DNS", "project"):
            mutants[name] = json.loads(json.dumps(rendered))
        del mutants["dropped service"]["services"]["bridge"]
        mutants["changed mount"]["services"]["edge"]["volumes"] = ["/wrong:/data"]
        del mutants["missing host DNS"]["services"]["edge"]["dns"]
        mutants["bridge DNS"]["services"]["bridge"]["dns"] = ["192.0.2.1"]
        mutants["project"]["name"] = "changed"
        for name, spec in [("valid", rendered), *mutants.items()]:
            with self.subTest(name=name), patch.object(gate, "original_spec", return_value=expected), patch.object(
                gate, "rendered_spec", return_value=spec
            ), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(gate.check("hsb1"), name == "valid")


if __name__ == "__main__":
    unittest.main()
