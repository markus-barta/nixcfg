"""Execute the real justfile recipe bodies with offline commands; never sudo/build."""

import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
RECIPES = ("switch", "nix-switch", "nix-build")


class TestRecipes(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="t125-recipes-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.lock = self.root / "deploy.lock"
        self.lock.touch(mode=0o644)
        self.log = self.root / "events"
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        RECIPE_LOG=str(self.log), RECIPE_HOST="hsb0", RECIPE_ROOT="0")
        helper = (REPO / "scripts/hsb0-deploy-lock.sh").read_text()
        (self.root / "scripts").mkdir()
        (self.root / "descriptors").mkdir()
        (self.root / "scripts/hsb0-deploy-lock.sh").write_text(
            helper.replace("lock=/run/hsb0-deploy.lock", "lock=" + str(self.lock))
            .replace('/proc/"$$"/fd/[0-9]*', str(self.root / "descriptors/[0-9]*")))
        fake = '''import fcntl, json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
def event():
    with open(os.environ["RECIPE_LOG"], "a") as out:
        out.write(json.dumps({"name": name, "args": args,
                              "root": os.environ["RECIPE_ROOT"],
                              "locked": os.environ.get("RECIPE_LOCKED")}) + "\\n")
if name == "hostname":
    assert args == ["-s"]
    print(os.environ["RECIPE_HOST"])
elif name == "sudo":
    os.environ["RECIPE_ROOT"] = "1"
    os.execvp(args[0], args)
elif name == "flock":
    event()
    assert args[:4] == ["-w", "900", "-E", "75"]
    if os.environ.get("RECIPE_BUSY"):
        raise SystemExit(75)
    if os.environ.get("RECIPE_FLOCK_ERROR"):
        raise SystemExit(1)
    if args[4].isdigit():
        fcntl.flock(int(args[4]), fcntl.LOCK_EX | fcntl.LOCK_NB)
        raise SystemExit(0)
    assert pathlib.Path(args[4]).name == "deploy.lock"
    fd = os.open(args[4], os.O_RDONLY)
    os.set_inheritable(fd, True)
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    os.environ["RECIPE_LOCKED"] = "1"
    os.execvp(args[5], args[5:])
elif name in {"nh", "nixos-rebuild"}:
    event()
    raise SystemExit(int(os.environ.get("RECIPE_COMMAND_EXIT", "0")))
elif name == "git":
    pass
elif name in {"just", "curl"}:
    pass
else:
    raise AssertionError(name)
'''
        for name in ("hostname", "sudo", "flock", "nh", "nixos-rebuild", "git", "just", "curl"):
            path = self.bin / name
            path.write_text("#!" + sys.executable + "\n" + fake)
            path.chmod(0o700)
        # Let just parse its own syntax and render the recipe's actual body.
        dumped = subprocess.run([shutil.which("just"), "--dump", "--dump-format", "json"],
                                cwd=REPO, capture_output=True, text=True, check=True, timeout=10)
        self.recipes = json.loads(dumped.stdout)["recipes"]

    def run_recipe(self, name, host="hsb0", mutant=False, pass_fds=()):
        variables = {"hostname": host, "user": "mba", "args": ""}
        lines = []
        for line in self.recipes[name]["body"]:
            lines.append("".join(part if isinstance(part, str) else variables[part[0][1]]
                                 for part in line))
        body = "\n".join(lines)
        if mutant:
            before = "bash scripts/hsb0-deploy-lock.sh nh os switch"
            self.assertEqual(body.count(before), 1)
            body = body.replace(before, "nh os switch")
        # The Mac must exercise the NixOS branch using PATH fakes only.
        body = "OSTYPE=linux-gnu\n" + body
        result = subprocess.run(["bash", "-c", body], cwd=self.root,
                                env=dict(self.env, RECIPE_HOST=host), capture_output=True,
                                text=True, check=False, timeout=10, pass_fds=pass_fds)
        events = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        if self.log.exists():
            self.log.unlink()
        return result, events

    def assert_locked(self, name, mutant=False):
        result, events = self.run_recipe(name, mutant=mutant)
        self.assertEqual(result.returncode, 0, result.stderr)
        command = next(e for e in events if e["name"] in {"nh", "nixos-rebuild"})
        locks = [e for e in events if e["name"] == "flock"]
        self.assertEqual(len(locks), 1)
        self.assertEqual(locks[0]["args"][4], str(self.lock))
        expected_root = "0" if name == "switch" else "1"
        self.assertEqual(locks[0]["root"], expected_root)
        self.assertEqual(command["root"], expected_root)
        self.assertEqual(command["locked"], "1")
        expected = {"switch": ["os", "switch", "-H", "hsb0", ".", "--"],
                    "nix-switch": ["switch", "--flake", ".#hsb0", "-L"],
                    "nix-build": ["build", "--flake", ".#hsb0"]}
        self.assertEqual(command["args"], expected[name])

    def test_hsb0_recipes_lock_as_existing_user(self):
        for name in RECIPES:
            with self.subTest(recipe=name):
                self.assert_locked(name)

    def test_other_hosts_keep_commands_and_users(self):
        for name in RECIPES:
            with self.subTest(recipe=name):
                result, events = self.run_recipe(name, host="hsb8")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse([e for e in events if e["name"] == "flock"])
                command = next(e for e in events if e["name"] in {"nh", "nixos-rebuild"})
                self.assertEqual(command["root"], "0" if name == "switch" else "1")
                self.assertIn("hsb8" if name == "switch" else ".#hsb8", command["args"])
                self.assertNotIn("no hsb0 deploy lock yet", result.stdout)

    def test_missing_file_notes_and_proceeds(self):
        self.lock.unlink()
        for name in RECIPES:
            with self.subTest(recipe=name):
                result, events = self.run_recipe(name)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("no hsb0 deploy lock yet", result.stdout)
                self.assertFalse([e for e in events if e["name"] == "flock"])
                self.assertEqual(len([e for e in events if e["name"] in {"nh", "nixos-rebuild"}]), 1)

    def test_outer_manual_lock_is_reused(self):
        with self.lock.open("r") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            (self.root / "descriptors" / str(lock.fileno())).symlink_to(self.lock)
            result, events = self.run_recipe("switch", pass_fds=(lock.fileno(),))
            self.assertEqual(result.returncode, 0, result.stderr)
            locks = [e for e in events if e["name"] == "flock"]
            self.assertEqual(len(locks), 1)
            self.assertEqual(locks[0]["args"][4], str(lock.fileno()))
            self.assertEqual(len([e for e in events if e["name"] == "nh"]), 1)
            # The original open description remains locked after just exits.
            with self.lock.open("r") as contender:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_busy_fails_closed(self):
        self.env["RECIPE_BUSY"] = "1"
        for name in RECIPES:
            with self.subTest(recipe=name):
                result, events = self.run_recipe(name)
                self.assertEqual(result.returncode, 75)
                self.assertIn("hsb0 deploy lock busy (hausnetz-cd running?)", result.stderr)
                self.assertFalse([e for e in events if e["name"] in {"nh", "nixos-rebuild"}])

    def test_lock_error_fails_closed(self):
        self.env["RECIPE_FLOCK_ERROR"] = "1"
        for name in RECIPES:
            with self.subTest(recipe=name):
                result, events = self.run_recipe(name)
                self.assertEqual(result.returncode, 1)
                self.assertFalse([e for e in events if e["name"] in {"nh", "nixos-rebuild"}])

    def test_command_failure_propagates(self):
        self.env["RECIPE_COMMAND_EXIT"] = "42"
        for name in RECIPES:
            with self.subTest(recipe=name):
                result, _ = self.run_recipe(name)
                self.assertEqual(result.returncode, 42)

    def test_switch_lock_removal_mutant_is_killed(self):
        # Require a behavior assertion failure, never a syntax/fixture error.
        result, events = self.run_recipe("switch", mutant=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len([e for e in events if e["name"] == "nh"]), 1)
        with self.assertRaises(AssertionError):
            self.assertEqual(len([e for e in events if e["name"] == "flock"]), 1)
        print("must-fail mutant killed: just switch deploy lock", flush=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
