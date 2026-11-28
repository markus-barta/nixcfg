"""Offline adapter boundary tests: real local bundles, fake VM and checker."""

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


REPO = Path(__file__).resolve().parents[1]
SOURCE = REPO / "modules/hausnetz-cd"
override = os.environ.get("T125_ADAPTER_MUTANT")
if override:
    import re
    if not re.fullmatch(r"t125-adapter-[A-Za-z0-9_-]+", override):
        raise ValueError("unsafe mutant")
    SOURCE = Path("/tmp") / override


FAKE = r'''
import json, os, pathlib, shlex, subprocess, sys, time
root = pathlib.Path(__file__).resolve().parent.parent
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
scenario = json.loads((root / 'scenario').read_text())
def event(kind, **kw):
    with (root / 'events').open('a') as out:
        out.write(json.dumps(dict(kind=kind, args=args, **kw)) + '\n')
if name == 'colima':
    if args == ['list', '--json']:
        print(json.dumps({'name':'ci', 'status':'Running' if (root / 'running').exists() else 'Stopped'}))
    else:
        assert args[:4] == ['--profile','ci','ssh','--']
        remote = shlex.split(args[4])
        assert remote[:5] == ['sudo','-n','-u','ci-hausnetz','--']
        if remote[5] == '/bin/sh':
            event('probe')
            raise SystemExit(75 if scenario.get('probe_fail') else 0)
        assert remote[5:7] == ['/usr/bin/python3', '-c']
        event('remote-' + remote[8])
        if scenario.get('ssh_fail'):
            raise SystemExit(1)  # Actual Colima transport errors collapse here.
        result = subprocess.run([sys.executable, *remote[6:]])
        raise SystemExit(1 if result.returncode else 0)
elif name == 'ci-vm':
    event('ci-vm')
    if args == ['start','--provision-only']:
        if scenario.get('busy'):
            raise SystemExit(75)
        if scenario.get('start_fail'):
            raise SystemExit(1)
        (root / 'running').touch()
    elif args == ['stop']:
        time.sleep(scenario.get('stop_delay', 0))
        (root / 'running').unlink(missing_ok=True)
    else:
        raise AssertionError(args)
elif name == 'git':
    if args[-2:] == ['rev-parse','HEAD'] and scenario.get('head_mismatch'):
        print('b' * 40)
    else:
        raise SystemExit(subprocess.run([str(root / 'real-git'), *args]).returncode)
elif name == 'nix':
    event('checker', head=subprocess.check_output([str(root / 'real-git'),'rev-parse','HEAD'], text=True).strip(),
          home=os.environ['HOME'], path=os.environ['PATH'])
    assert args[:5] == ['develop','-c','just','acceptance','http://192.168.1.99/']
    candidate = (root / 'candidate-rev').read_text()
    assert subprocess.run([str(root / 'real-git'), 'cat-file', '-e', candidate], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0, 'bundle included the candidate'
    (root / 'checker-pid').write_text(str(os.getpid()))
    if scenario.get('hang'):
        time.sleep(20)
    print('checker chatter')
    print('checker stderr', file=sys.stderr)
    if scenario.get('no_json'):
        raise SystemExit(0)
    if scenario.get('duplicate_json'):
        print('{"schema":"hausnetz.acceptance.v1","ok":false,"ok":true}')
        raise SystemExit(0)
    print(json.dumps({'schema':'hausnetz.acceptance.v1','ok':False,'old':True}))
    print(json.dumps({'schema':'hausnetz.acceptance.v1','ok':not scenario.get('red')}))
    raise SystemExit(scenario.get('checker_exit', 1 if scenario.get('red') else 0))
else:
    raise AssertionError(name)
'''


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="t125-adapter-fixture-")
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.repo = self.root / "cache/hausnetz"
        self.repo.mkdir(parents=True)
        self.git = shutil.which("git")
        (self.root / "real-git").symlink_to(self.git)
        def git(*args):
            return subprocess.check_output([self.git, "-C", str(self.repo), *args], stderr=subprocess.DEVNULL,
                                           text=True).strip()
        git("init", "--quiet")
        git("config", "user.name", "Fixture")
        git("config", "user.email", "fixture@invalid")
        git("config", "commit.gpgsign", "false")
        (self.repo / "justfile").write_text("acceptance url version caps:\n    true\n")
        git("add", "justfile")
        git("commit", "--quiet", "-m", "trusted")
        self.rev = git("rev-parse", "HEAD")
        (self.repo / "candidate").write_text("must not run")
        git("add", "candidate")
        git("commit", "--quiet", "-m", "candidate")
        (self.root / "candidate-rev").write_text(git("rev-parse", "HEAD"))
        self.scenario = {}
        self.home = self.root / "guest-home"
        self.home.mkdir()
        for name in ("colima", "ci-vm", "git", "nix"):
            path = self.bin / name
            path.write_text("#!" + sys.executable + "\n" + FAKE)
            path.chmod(0o700)
        guest = (SOURCE / "acceptance-guest.py").read_text()
        guest = guest.replace('HOME = Path("/var/lib/ci-runners/hausnetz")', "HOME = Path(" + repr(str(self.home)) + ")")
        guest = guest.replace('PATH = "/nix/var/nix/profiles/default/bin:/usr/bin:/bin"',
                              'PATH = ' + repr(str(self.bin) + ":/usr/bin:/bin"))
        (self.root / "guest.py").write_text(guest)
        self.config = {"acceptance_url":"http://192.168.1.99/", "cache_dir":str(self.root / "cache"),
                       "state_dir":str(self.root / "state"), "git":self.git,
                       "colima":str(self.bin / "colima"), "ci_vm":str(self.bin / "ci-vm"), "timeout":5, "budget":600}
        self.path = self.root / "adapter.py"
        self.path.write_text((SOURCE / "acceptance-adapter.py").read_text()
                             .replace("@CONFIG@", str(self.root / "config"))
                             .replace("@GUEST@", str(self.root / "guest.py")))
        self.env = dict(os.environ, PYTHONPATH=str(SOURCE), PYTHONDONTWRITEBYTECODE="1")
        self.args = [self.rev, self.config["acceptance_url"], "261127164749.0.0", "a" * 64]
        self.children = []

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.kill()
            child.wait()
        # A deliberate remote-kill mutant can leave this fixture's checker in
        # its own session. Contain that owned test process before deleting it.
        pidfile = self.root / "checker-pid"
        if pidfile.exists():
            try:
                os.killpg(int(pidfile.read_text()), signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.temp.cleanup()

    def save(self):
        (self.root / "scenario").write_text(json.dumps(self.scenario))
        (self.root / "config").write_text(json.dumps(self.config))

    def run_adapter(self, args=None):
        self.save()
        result = subprocess.run([sys.executable, "-B", str(self.path), *(self.args if args is None else args)],
                                env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(len(result.stdout.splitlines()), 1, result.stdout + result.stderr)
        value = json.loads(result.stdout)
        self.assertIsInstance(value, dict)
        return result, value

    def events(self, name):
        path = self.root / "events"
        return [v for v in map(json.loads, path.read_text().splitlines()) if v["kind"] == name] if path.exists() else []

    def test_arguments(self):
        for index, bad in ((0,"A"*40),(0,"a"*39),(1,"http://wrong.invalid/"),
                           (2,"26.11.27"),(2,"260229164749.0.0"),(3,"z"*64),(3,"a"*63)):
            with self.subTest(index=index, bad=bad):
                args = list(self.args)
                args[index] = bad
                result, value = self.run_adapter(args)
                self.assertEqual(result.returncode, 2)
                self.assertFalse(value["ok"])
        self.assertEqual(self.run_adapter([])[0].returncode, 2)
        self.assertEqual(self.run_adapter(["--preflight", "http://wrong.invalid/"])[0].returncode, 2)
        self.assertFalse(self.events("probe"))

    def test_stopped_vm_bundle_and_single_json(self):
        result, value = self.run_adapter()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(value["ok"])
        self.assertNotIn("old", value)
        self.assertIn("checker chatter", result.stderr)
        self.assertIn("checker stderr", result.stderr)
        self.assertEqual([e["args"] for e in self.events("ci-vm")], [["start","--provision-only"],["stop"]])
        checker, = self.events("checker")
        self.assertEqual(checker["head"], self.rev)
        self.assertEqual(checker["home"], str(self.home))
        self.assertFalse(list((self.home / "cd-acceptance").glob("run-*")))

    def test_running_vm_not_owned(self):
        (self.root / "running").touch()
        self.assertEqual(self.run_adapter()[0].returncode, 0)
        self.assertFalse(self.events("ci-vm"))

    def test_busy_lock(self):
        self.scenario["busy"] = True
        result, value = self.run_adapter()
        self.assertEqual(result.returncode, 75)
        self.assertEqual(value["infra"], "unavailable")
        self.assertEqual(value["reason"], "heavy_lock_busy")
        self.assertFalse(self.events("remote-run"))
        self.assertEqual([e["args"] for e in self.events("ci-vm")], [["start","--provision-only"]])

    def test_preflight_release_and_lease_transfer(self):
        self.assertEqual(self.run_adapter(["--preflight", self.args[1]])[0].returncode, 0)
        self.assertTrue((self.root / "running").exists())
        self.assertEqual(len(list((self.root / "state").glob("vm-*.json"))), 1)
        self.assertFalse(self.events("checker"))
        self.assertEqual(self.run_adapter()[0].returncode, 0)
        self.assertFalse((self.root / "running").exists())
        self.assertEqual(self.run_adapter(["--preflight", self.args[1]])[0].returncode, 0)
        self.assertEqual(self.run_adapter(["--release"])[0].returncode, 0)
        self.assertFalse((self.root / "running").exists())

    def test_head_mismatch(self):
        self.scenario["head_mismatch"] = True
        result, value = self.run_adapter()
        self.assertEqual(result.returncode, 75)
        self.assertFalse(value["ok"])
        self.assertFalse(self.events("checker"))
        self.assertFalse(list((self.home / "cd-acceptance").glob("run-*")))

    def test_missing_commit(self):
        self.args[0] = "a" * 40
        result, value = self.run_adapter()
        self.assertEqual(result.returncode, 75)
        self.assertFalse(value["ok"])
        self.assertFalse(self.events("remote-run"))

    def test_ssh_start_and_probe_failures(self):
        for key in ("ssh_fail", "start_fail", "probe_fail"):
            self.scenario = {key:True}
            result, value = self.run_adapter()
            self.assertEqual(result.returncode, 75, key)
            self.assertEqual(value["infra"], "unavailable")

    def test_missing_json_fails_closed(self):
        self.scenario["no_json"] = True
        result, value = self.run_adapter()
        self.assertEqual(result.returncode, 1)
        self.assertFalse(value["ok"])

    def test_duplicate_checker_keys_fail_closed(self):
        self.scenario["duplicate_json"] = True
        result, value = self.run_adapter()
        self.assertEqual(result.returncode, 1)
        self.assertFalse(value["ok"])

    def test_real_red_exit_forwarded(self):
        self.scenario["red"] = True
        result, value = self.run_adapter()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(value, {"schema":"hausnetz.acceptance.v1", "ok":False})

    def test_checker_status_survives_colima_exit_collapse(self):
        self.scenario.update(red=True, checker_exit=42)
        result, value = self.run_adapter()
        self.assertEqual(result.returncode, 42)
        self.assertFalse(value["ok"])

    def test_sigterm_remote_kill_and_stop(self):
        self.scenario["hang"] = True
        self.save()
        process = subprocess.Popen([sys.executable, "-B", str(self.path), *self.args],
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   start_new_session=True)
        self.children.append(process)
        deadline = time.monotonic() + 5
        while not (self.root / "checker-pid").exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue((self.root / "checker-pid").exists())
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=3)
        self.assertNotEqual(process.returncode, 0, stderr)
        self.assertEqual(len(stdout.splitlines()), 1)
        self.assertTrue(self.events("remote-kill"))
        deadline = time.monotonic() + 3
        while (self.root / "running").exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertFalse((self.root / "running").exists())
        pid = int((self.root / "checker-pid").read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_budget_expiry_returns_infra_before_slow_vm_stop(self):
        self.config["budget"] = 0.8
        self.scenario.update(hang=True, stop_delay=1.5)
        started = time.monotonic()
        result, value = self.run_adapter()
        self.assertEqual(result.returncode, 75)
        self.assertEqual(value["infra"], "unavailable")
        self.assertLess(time.monotonic() - started, 1.9)
        self.assertTrue(self.events("remote-kill"))
        deadline = time.monotonic() + 4
        while (self.root / "running").exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertFalse((self.root / "running").exists())

    def test_sigterm_during_stop_still_emits_json_and_releases(self):
        self.scenario["stop_delay"] = 2
        self.save()
        process = subprocess.Popen([sys.executable, "-B", str(self.path), *self.args],
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   start_new_session=True)
        self.children.append(process)
        deadline = time.monotonic() + 5
        while not any(e["args"] == ["stop"] for e in self.events("ci-vm")) and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(any(e["args"] == ["stop"] for e in self.events("ci-vm")))
        self.scenario["stop_delay"] = 0
        self.save()
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=3)
        self.assertEqual(process.returncode, 75, stderr)
        self.assertEqual(len(stdout.splitlines()), 1)
        self.assertEqual(json.loads(stdout)["reason"], "cancelled")
        deadline = time.monotonic() + 3
        while (self.root / "running").exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertFalse((self.root / "running").exists())

    def test_prune_only_owned_directories(self):
        root = self.home / "cd-acceptance"
        root.mkdir()
        unrelated = root / "keep-me"
        unrelated.mkdir()
        for index in range(7):
            (root / ("run-" + format(index,"032x"))).mkdir()
        (root / ("run-" + "f"*32)).symlink_to(unrelated, target_is_directory=True)
        # Run the production pruning function against this fixture's root.
        code = (self.root / "guest.py").read_text().split('if __name__ == "__main__":')[0]
        namespace = {"__name__":"fixture"}
        exec(compile(code, "guest", "exec"), namespace)
        namespace["prune"](root)
        self.assertEqual(len([p for p in root.glob("run-*") if not p.is_symlink()]), 3)
        self.assertTrue(unrelated.exists())
        self.assertTrue((root / ("run-" + "f"*32)).is_symlink())


def mutants():
    cases = [
        ("URL check", "acceptance-adapter.py", 'if args[1] != config["acceptance_url"]:', 'if False:', "test_arguments", 2),
        ("HEAD verification", "acceptance-guest.py", 'if git("-C", checkout, "rev-parse", "HEAD") != rev:', 'if False:', "test_head_mismatch", 1),
        ("lock busy fail closed", "acceptance-adapter.py", 'raise Unavailable("heavy_lock_busy")', 'rc = 0', "test_busy_lock", 1),
        ("single JSON", "acceptance-adapter.py", 'print(json.dumps(value, allow_nan=False))', 'print(json.dumps(value)); print(json.dumps(value))', "test_stopped_vm_bundle_and_single_json", 1),
        ("SIGTERM remote kill", "acceptance-adapter.py", 'self.command(self.ssh("kill"), timeout=1)', 'None', "test_sigterm_remote_kill_and_stop", 1),
    ]
    for name, filename, before, after, test, count in cases:
        with tempfile.TemporaryDirectory(prefix="t125-adapter-", dir="/tmp") as tmp:
            source = Path(tmp)
            for path in SOURCE.glob("*.py"):
                shutil.copyfile(path, source / path.name)
            path = source / filename
            code = path.read_text()
            if code.count(before) != count:
                raise AssertionError("mutant no longer matches: " + name)
            path.write_text(code.replace(before, after))
            result = subprocess.run([sys.executable, "-B", __file__, "AdapterTests." + test],
                                    env=dict(os.environ, T125_ADAPTER_MUTANT=source.name),
                                    capture_output=True, text=True, timeout=20)
            if result.returncode == 0 or "FAIL: " not in result.stderr:
                raise AssertionError("survived or invalid mutant: " + name + "\n" + result.stderr)
            assertion = next(line for line in result.stderr.splitlines() if line.startswith("AssertionError:"))
            print("must-fail adapter mutant killed: " + name + " — " + assertion, flush=True)


if __name__ == "__main__":
    if sys.argv[1:] == ["--mutants"]:
        mutants()
    else:
        unittest.main(verbosity=2)
