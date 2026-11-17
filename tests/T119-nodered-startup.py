#!/usr/bin/env python3
"""OPS-605: evaluate the real wrapper and run it offline with node/npm stubs."""

import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PINS = {
    "node-red-contrib-telegrambot": "19.0.3",
    "node-red-contrib-influxdb": "0.7.0",
    "cheerio": "1.2.0",
}
IMAGE = (
    "nodered/node-red:5.0.9-24@sha256:"
    "2ccd38b4066648bd5e17430c50a2f8102c566a82fd4f2fc5c342e61664d6896f"
)
ENTRYPOINT = "/usr/src/node-red/entrypoint.sh"
FLAGS = [
    "install", "--prefix", "/data", "--save-exact", "--no-audit",
    "--no-update-notifier", "--no-fund", "--omit=dev",
    "--fetch-timeout=30000", "--fetch-retries=1",
]
ARGS = ["--userDir", "/data", "argument with spaces", ""]

# These stubs check the actual arguments and record only synthetic fixture data.
# No container, network, real /data writes or NixOS build is involved.
STUB = r'''
import json
import os
from pathlib import Path
import re
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
with Path(os.environ["TEST_CALLS"]).open("a") as calls:
    calls.write(json.dumps([name, args]) + "\n")
state_file = Path(os.environ["TEST_PACKAGES"])
state = json.loads(state_file.read_text())
if name == "node":
    assert len(args) == 2 and args[0] == "-p", args
    match = re.fullmatch(r"require\('/data/node_modules/([^']+)/package.json'\).version", args[1])
    assert match, args
    version = state.get(match[1])
    if version is None:
        sys.exit(1)
    print(version)
elif name == "npm":
    if os.environ["TEST_FAIL_NPM"] == "1":
        sys.exit(42)
    package, version = args[-1].rsplit("@", 1)
    state[package] = version
    state_file.write_text(json.dumps(state))
else:
    assert name == "entrypoint.sh", name
    sys.exit(int(os.environ["TEST_ENTRYPOINT_STATUS"]))
'''


class NodeRedStartup(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Reading the evaluated mount extracts exactly the script Compose uses,
        # retaining Nix string escaping and store-path wiring in the test.
        result = subprocess.run(
            [
                "nix-instantiate", "--eval", "--read-write-mode", "--strict", "--json", "--expr", r'''
                let
                  service = (import ./hosts/csb0/docker/compose-spec.nix).services.nodered;
                  suffix = ":/opt/nixcfg/nodered-startup.sh:ro";
                  mounts = builtins.filter
                    (mount: builtins.match "/nix/store/.*:/opt/nixcfg/nodered-startup.sh:ro" mount != null)
                    service.volumes;
                  mount = assert builtins.length mounts == 1; builtins.head mounts;
                  path = builtins.substring 0
                    (builtins.stringLength mount - builtins.stringLength suffix) mount;
                in {
                  inherit (service) image entrypoint volumes;
                  script = builtins.readFile path;
                }
                ''',
            ],
            cwd=ROOT, text=True, capture_output=True, timeout=30, check=True,
        )
        cls.service = json.loads(result.stdout)
        cls.source = cls.service["script"]

    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="nodered-startup-")
        self.addCleanup(self.work.cleanup)
        self.directory = Path(self.work.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        for name in ("node", "npm", "entrypoint.sh"):
            stub = self.bin / name
            stub.write_text(f"#!{sys.executable}\n" + STUB)
            stub.chmod(0o755)
        self.calls = self.directory / "calls.jsonl"
        self.packages = self.directory / "packages.json"
        self.packages.write_text("{}")
        # Replace only the absolute handoff; version checks must still use /data.
        self.assertEqual(self.source.count(ENTRYPOINT), 1)
        self.script = self.directory / "startup.sh"
        self.script.write_text(self.source.replace(
            ENTRYPOINT, shlex.quote(str(self.bin / "entrypoint.sh")),
        ))

    def run_startup(self, *, fail_npm=False, status=0):
        self.calls.write_text("")
        variables = os.environ.copy()
        variables.update({
            "PATH": str(self.bin) + os.pathsep + variables.get("PATH", ""),
            "TEST_CALLS": str(self.calls),
            "TEST_PACKAGES": str(self.packages),
            "TEST_FAIL_NPM": "1" if fail_npm else "0",
            "TEST_ENTRYPOINT_STATUS": str(status),
        })
        result = subprocess.run(
            ["/bin/bash", str(self.script), *ARGS], cwd=self.directory,
            env=variables, text=True, capture_output=True, timeout=10, check=False,
        )
        self.assertEqual(result.returncode, status, result.stderr)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(calls[-1], ["entrypoint.sh", ARGS])
        self.assertEqual(sum(name == "entrypoint.sh" for name, _ in calls), 1)
        node_calls = [args for name, args in calls if name == "node"]
        self.assertEqual(node_calls, [
            ["-p", f"require('/data/node_modules/{package}/package.json').version"]
            for package in PINS
        ])
        installs = [args for name, args in calls if name == "npm"]
        for args in installs:
            self.assertEqual(args[:-1], FLAGS)
            self.assertIn(args[-1], [f"{name}@{version}" for name, version in PINS.items()])
        return result, [args[-1] for args in installs]

    def test_pins_and_compose_wiring(self):
        self.assertEqual(self.service["image"], IMAGE)
        self.assertEqual(self.service["entrypoint"], [
            "/bin/bash", "/opt/nixcfg/nodered-startup.sh",
        ])
        mounts = self.service["volumes"]
        self.assertEqual([mount for mount in mounts if not mount.startswith("/nix/store/")], [
            "nodered-data:/data", "nodered-scripts:/scripts",
            "nodered-webserver:/webserver", "shared-tmp:/shared-tmp",
        ])
        self.assertTrue(self.source.startswith("#!/bin/bash\n"))
        self.assertEqual(dict(re.findall(
            r"^ensure_package ([\w-]+) ([\d.]+)$", self.source, re.MULTILINE,
        )), PINS)
        self.assertTrue(self.source.rstrip().endswith(f'exec {ENTRYPOINT} "$@"'))
        subprocess.run(["/bin/bash", "-n", str(self.script)], check=True)

    def test_matching_versions_skip_npm_even_offline(self):
        self.packages.write_text(json.dumps(PINS))
        result, installs = self.run_startup(fail_npm=True)
        self.assertEqual(installs, [])
        self.assertNotIn("WARN", result.stderr)

    def test_missing_versions_install_exactly_and_persist(self):
        result, installs = self.run_startup()
        self.assertEqual(installs, [f"{name}@{version}" for name, version in PINS.items()])
        self.assertEqual(json.loads(self.packages.read_text()), PINS)
        self.assertNotIn("WARN", result.stderr)
        # Another container start sees the same persistent /data state.
        _, installs = self.run_startup(fail_npm=True)
        self.assertEqual(installs, [])

    def test_only_mismatched_and_missing_versions_install(self):
        self.packages.write_text(json.dumps({
            "node-red-contrib-telegrambot": "19.0.2",
            "node-red-contrib-influxdb": "0.7.0",
        }))
        _, installs = self.run_startup()
        self.assertEqual(installs, ["node-red-contrib-telegrambot@19.0.3", "cheerio@1.2.0"])

    def test_all_npm_failures_warn_and_still_exec(self):
        result, installs = self.run_startup(fail_npm=True, status=23)
        self.assertEqual(installs, [f"{name}@{version}" for name, version in PINS.items()])
        warnings = result.stderr.splitlines()
        self.assertEqual(len(warnings), 3)
        for warning, package in zip(warnings, installs):
            self.assertTrue(warning.startswith("WARN: "), warning)
            self.assertIn(package, warning)
            self.assertIn("continuing startup", warning)


if __name__ == "__main__":
    unittest.main(verbosity=2)
