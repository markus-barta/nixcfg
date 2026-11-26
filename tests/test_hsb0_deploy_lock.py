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
RECIPES += ("switch-simple", "test", "flake-rebuild-current", "rollback", "cleanup")
ROOT_RECIPES = {"nix-switch", "nix-build", "test"}
COMMANDS = {"nh", "nixos-rebuild", "just"}


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
        (self.root / "ancestor-descriptors").mkdir()
        (self.root / "scripts/hsb0-deploy-lock.sh").write_text(
            helper.replace("lock=/run/hsb0-deploy.lock", "lock=" + str(self.lock))
            .replace('/proc/"$$"/fd/[0-9]*', str(self.root / "descriptors/[0-9]*"))
            .replace('/proc/"$ancestor"/fd/[0-9]*', str(self.root / "ancestor-descriptors/[0-9]*"))
            .replace('/proc/"$ancestor"/status', str(self.root / "ancestor-status")))
        self.env["RECIPE_DESCRIPTORS"] = str(self.root / "descriptors")
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
    if os.environ.get("RECIPE_HOST_FAIL"):
        raise SystemExit(1)
    print(os.environ["RECIPE_HOST"])
elif name == "sudo":
    # Real sudo closes descriptors >= 3 before running its command.
    os.closerange(3, 65536)
    if args[0] == "bash":
        for descriptor in pathlib.Path(os.environ["RECIPE_DESCRIPTORS"]).iterdir():
            descriptor.unlink()
    os.environ.pop("RECIPE_LOCKED", None)
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
elif name in {"nh", "nixos-rebuild"} or (name == "just" and args == ["_cleanup"]):
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
        self.aliases = json.loads(dumped.stdout)["aliases"]

    def run_recipe(self, name, host="hsb0", mutant=False, pass_fds=()):
        variables = {"hostname": host, "user": "mba", "args": ""}
        lines = []
        for line in self.recipes[name]["body"]:
            lines.append("".join(part if isinstance(part, str) else variables[part[0][1]]
                                 for part in line))
        body = "\n".join(lines)
        if mutant:
            before = "bash scripts/hsb0-deploy-lock.sh "
            self.assertEqual(body.count(before), 1)
            body = body.replace(before, "")
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
        command = next(e for e in events if e["name"] in COMMANDS)
        locks = [e for e in events if e["name"] == "flock"]
        self.assertEqual(len(locks), 1)
        self.assertEqual(locks[0]["args"][4], str(self.lock))
        expected_root = "1" if name in ROOT_RECIPES else "0"
        self.assertEqual(locks[0]["root"], expected_root)
        self.assertEqual(command["root"], expected_root)
        self.assertEqual(command["locked"], "1")
        expected = {"switch": ["os", "switch", "-H", "hsb0", ".", "--"],
                    "nix-switch": ["switch", "--flake", ".#hsb0", "-L"],
                    "nix-build": ["build", "--flake", ".#hsb0"],
                    "switch-simple": ["os", "switch", "-H", "hsb0", "."],
                    "test": ["test", "--flake", ".#hsb0", "-L"],
                    "flake-rebuild-current": ["os", "switch", "-H", "hsb0", "."],
                    "rollback": ["os", "rollback"], "cleanup": ["_cleanup"]}
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
                command = next(e for e in events if e["name"] in COMMANDS)
                self.assertEqual(command["root"], "1" if name in ROOT_RECIPES else "0")
                if name not in {"rollback", "cleanup"}:
                    self.assertIn(".#hsb8" if name in ROOT_RECIPES else "hsb8", command["args"])
                self.assertNotIn("no hsb0 deploy lock yet", result.stdout)

    def test_missing_file_notes_and_proceeds(self):
        self.lock.unlink()
        for name in RECIPES:
            with self.subTest(recipe=name):
                result, events = self.run_recipe(name)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("no hsb0 deploy lock yet", result.stdout)
                self.assertFalse([e for e in events if e["name"] == "flock"])
                self.assertEqual(len([e for e in events if e["name"] in COMMANDS]), 1)

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
                self.assertFalse([e for e in events if e["name"] in COMMANDS])

    def test_lock_error_fails_closed(self):
        self.env["RECIPE_FLOCK_ERROR"] = "1"
        for name in RECIPES:
            with self.subTest(recipe=name):
                result, events = self.run_recipe(name)
                self.assertEqual(result.returncode, 1)
                self.assertFalse([e for e in events if e["name"] in COMMANDS])

    def test_command_failure_propagates(self):
        self.env["RECIPE_COMMAND_EXIT"] = "42"
        for name in RECIPES:
            with self.subTest(recipe=name):
                result, _ = self.run_recipe(name)
                self.assertEqual(result.returncode, 42)

    def test_all_recipe_lock_removal_mutants_are_killed(self):
        # Require a behavior assertion failure, never a syntax/fixture error.
        for name in RECIPES:
            with self.subTest(recipe=name):
                result, events = self.run_recipe(name, mutant=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len([e for e in events if e["name"] in COMMANDS]), 1)
                with self.assertRaises(AssertionError):
                    self.assertEqual(len([e for e in events if e["name"] == "flock"]), 1)
                print("must-fail mutant killed: just " + name + " deploy lock", flush=True)

    def test_switch_simple_alias_and_cleanup_wrapper(self):
        self.assertEqual(self.aliases["ss"]["target"], "switch-simple")
        body = str(self.recipes["_cleanup"]["body"])
        self.assertIn("sudo nix-collect-garbage -d", body)
        self.assertIn("nix-collect-garbage -d", body)
        self.assert_locked("cleanup")

    def test_hostname_failure_and_empty_hostname_refuse(self):
        for failure in (False, True):
            self.env["RECIPE_HOST_FAIL"] = "1" if failure else ""
            for name in RECIPES:
                with self.subTest(recipe=name, failed=failure):
                    result, events = self.run_recipe(name, host="")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("cannot determine hostname", result.stderr)
                    self.assertFalse([e for e in events if e["name"] in COMMANDS])

    def assert_ancestor_refusal(self, name, lock):
        result, events = self.run_recipe(name, pass_fds=(lock.fileno(),))
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertIn("held by ancestor after descriptor closure", result.stderr)
        self.assertFalse([e for e in events if e["name"] in COMMANDS | {"flock"}])

    def test_outer_lock_before_sudo_refuses_without_waiting(self):
        with self.lock.open("r") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            (self.root / "ancestor-descriptors" / str(lock.fileno())).symlink_to(self.lock)
            for name in ROOT_RECIPES:
                with self.subTest(recipe=name):
                    (self.root / "descriptors" / str(lock.fileno())).symlink_to(self.lock)
                    self.assert_ancestor_refusal(name, lock)
                    self.assertFalse(list((self.root / "descriptors").iterdir()), "sudo must close inherited fds")
            with self.lock.open("r") as contender, self.assertRaises(BlockingIOError):
                fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_helper_safety_mutants_are_killed(self):
        path = self.root / "scripts/hsb0-deploy-lock.sh"
        original = path.read_text()
        before = 'if ! host=$(hostname -s) || [[ -z $host ]]; then'
        self.assertEqual(original.count(before), 1)
        path.write_text(original.replace(before, 'host=$(hostname -s) || true\nif false; then'))
        result, events = self.run_recipe("switch", host="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue([e for e in events if e["name"] == "nh"])
        with self.assertRaises(AssertionError):
            self.assertNotEqual(result.returncode, 0)
        print("must-fail mutant killed: hostname failure must refuse", flush=True)
        before = 'if [[ $descriptor -ef $lock ]]; then'
        self.assertEqual(original.count(before), 2)
        # Remove the ancestor check only, retaining the inherited-fd check.
        first, second = original.rsplit(before, 1)
        path.write_text(first + 'if false; then' + second)
        with self.lock.open("r") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            (self.root / "ancestor-descriptors" / str(lock.fileno())).symlink_to(self.lock)
            with self.assertRaises(AssertionError):
                self.assert_ancestor_refusal("nix-switch", lock)
        print("must-fail mutant killed: ancestor flock must fail fast", flush=True)

    def test_ci_and_runbook_contracts_and_mutants(self):
        workflow = (REPO / ".github/workflows/check.yml").read_text()
        def check_ci(text):
            self.assertIn('nix-shell -p bash git python3 just --run "bash tests/T125-hausnetz-cd.sh"', text)
        check_ci(workflow)
        with self.assertRaises(AssertionError):
            check_ci(workflow.replace('bash git python3 just --run', 'bash git python3 --run'))
        print("must-fail mutant killed: CI must provide just", flush=True)
        runner = (REPO / "tests/T125-hausnetz-cd.sh").read_text()
        def check_runner(text):
            self.assertIn('test_hausnetz_cd.py" --parallel', text)
            self.assertIn('test_hausnetz_cd.py" --mutants', text)
        check_runner(runner)
        for flag in ('--parallel', '--mutants'):
            with self.subTest(removed=flag), self.assertRaises(AssertionError):
                check_runner(runner.replace(flag, ''))
            print("must-fail mutant killed: T125 must retain " + flag, flush=True)
        runbook = ' '.join((REPO / "hosts/hsb0/docs/RUNBOOK.md").read_text().split())
        def check_runbook(text):
            for name in RECIPES:
                self.assertIn('`' + name + '`', text)
            self.assertIn('same-version changes under 8 KiB', text)
            self.assertIn('G4 guards module changes', text)
            self.assertIn('root recipes directly without an outer flock', text)
        check_runbook(runbook)
        for before in ('same-version changes under 8 KiB', 'G4 guards module changes', '`cleanup`'):
            with self.subTest(removed=before), self.assertRaises(AssertionError):
                check_runbook(runbook.replace(before, 'omitted'))
            print("must-fail mutant killed: RUNBOOK " + before, flush=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
