"""OPS-158: real local Git + Gitleaks against synthetic service directories."""

import contextlib
import ctypes
import errno
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "hosts/hsb1/home-config-snapshot.py"
SCANNER_CONFIG = REPO / "hosts/hsb1/home-config-gitleaks.toml"
GITLEAKS = shutil.which("gitleaks")
GIT = shutil.which("git")
spec = importlib.util.spec_from_file_location("home_config", SCRIPT)
implementation = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = implementation
spec.loader.exec_module(implementation)


def put(root, name, content):
    target = root / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content)


def alert_modules():
    engine_spec = importlib.util.spec_from_file_location("engine", REPO / "modules/shared/fleet-alerts/engine.py")
    engine = importlib.util.module_from_spec(engine_spec)
    sys.modules["engine"] = engine
    engine_spec.loader.exec_module(engine)
    witness_spec = importlib.util.spec_from_file_location("home_config_watch", REPO / "hosts/hsb1/home-config-watch.py")
    witness = importlib.util.module_from_spec(witness_spec)
    witness_spec.loader.exec_module(witness)
    return engine, witness


@contextlib.contextmanager
def restrict_suid_sgid():
    """Emulate mode-argument rejection; subprocesses need the Linux test below."""
    def guard(function, mode_index, default=None):
        def checked(*args, **kwargs):
            mode = kwargs.get("mode", args[mode_index] if len(args) > mode_index else default)
            if mode & (stat.S_ISUID | stat.S_ISGID):
                raise PermissionError(errno.EPERM, "RestrictSUIDSGID mode argument")
            return function(*args, **kwargs)
        return checked

    with contextlib.ExitStack() as patches:
        for name, index, default in (("chmod", 1, None), ("fchmod", 1, None), ("mkdir", 1, 0o777), ("open", 2, 0o777)):
            patches.enter_context(mock.patch.object(os, name, guard(getattr(os, name), index, default)))
        yield


def install_linux_suid_sgid_filter():
    """Native seccomp inherited across exec, without root, systemd or preloads.

    Match systemd's seccomp_restrict_sxid mode checks, including open's O_CREAT
    condition and the openat2 ENOSYS fallback. Only this fixture child is filtered.
    """
    class Comparison(ctypes.Structure):
        _fields_ = [("arg", ctypes.c_uint), ("op", ctypes.c_int),
                    ("mask", ctypes.c_uint64), ("value", ctypes.c_uint64)]

    library = ctypes.CDLL(os.environ.get("HOME_CONFIG_TEST_SECCOMP_LIBRARY", "libseccomp.so.2"))
    library.seccomp_init.argtypes = [ctypes.c_uint32]
    library.seccomp_init.restype = ctypes.c_void_p
    library.seccomp_syscall_resolve_name.argtypes = [ctypes.c_char_p]
    library.seccomp_syscall_resolve_name.restype = ctypes.c_int
    library.seccomp_rule_add_array.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int,
                                              ctypes.c_uint, ctypes.POINTER(Comparison)]
    library.seccomp_rule_add_array.restype = ctypes.c_int
    library.seccomp_load.argtypes = [ctypes.c_void_p]
    library.seccomp_load.restype = ctypes.c_int
    library.seccomp_release.argtypes = [ctypes.c_void_p]
    library.seccomp_release.restype = None
    context = library.seccomp_init(0x7fff0000)  # SCMP_ACT_ALLOW
    if not context:
        raise RuntimeError("seccomp_init failed")
    try:
        for name, mode_index, flags_index in (("chmod", 1, None), ("fchmod", 1, None),
                                              ("fchmodat", 2, None), ("fchmodat2", 2, None),
                                              ("mkdir", 1, None), ("mkdirat", 2, None),
                                              ("mknod", 1, None), ("mknodat", 2, None),
                                              ("creat", 1, None), ("open", 2, 1), ("openat", 3, 2),
                                              ("openat2", None, None)):
            syscall = library.seccomp_syscall_resolve_name(name.encode("ascii"))
            if syscall == -1:
                if name in {"fchmodat2", "openat2"}:
                    continue  # Not known by older libseccomp releases.
                raise RuntimeError("unknown required syscall: " + name)
            for bit in (stat.S_ISUID, stat.S_ISGID) if mode_index is not None else (0,):
                checks = [] if mode_index is None else [Comparison(mode_index, 7, bit, bit)]  # SCMP_CMP_MASKED_EQ
                if flags_index is not None:
                    checks.append(Comparison(flags_index, 7, os.O_CREAT, os.O_CREAT))
                arguments = (Comparison * len(checks))(*checks)
                action = 0x00050000 | (errno.ENOSYS if mode_index is None else errno.EPERM)
                result = library.seccomp_rule_add_array(context, action, syscall, len(checks), arguments)
                if result < 0:
                    raise RuntimeError("seccomp rule failed: " + name + " errno=" + str(-result))
        result = library.seccomp_load(context)  # libseccomp also sets no_new_privs.
        if result < 0:
            raise RuntimeError("seccomp_load failed: errno=" + str(-result))
    finally:
        library.seccomp_release(context)


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(GITLEAKS, "Gitleaks is required; no mock scanner substitutes for the secret gate")
        self.temporary = tempfile.TemporaryDirectory(prefix="ops158-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / "history"
        self.repo.mkdir(mode=0o2750)
        self.repo.chmod(0o2750)
        self.runtime = self.root / "runtime"
        self.runtime.mkdir(mode=0o700)
        self.nr = self.root / "nodered"
        self.ha = self.root / "homeassistant"
        self.setting_value = "fixture-" + "credential-" + "fortytwo"
        self.planted_value = "fixture" + "Q7tX4aK2vR9pL6zN8bC5wH3sJ1dF0yE"
        put(self.nr, "flows.json", '[{"id":"tab","type":"tab","label":"fixture"}]\n')
        put(self.nr, "settings.js", '// settings fixture\nmodule.exports = {\n    credentialSecret: "' + self.setting_value + '",\n    flowFile: "flows.json",\n};\n')
        put(self.nr, "package.json", '{"name":"fixture","dependencies":{"node-red-node-test":"1.0.0"}}\n')
        for name in ("configuration", "automations", "scripts", "scenes", "customize"):
            put(self.ha, name + ".yaml", "# fixture\n{}\n")
        put(self.ha, "themes/sample.yaml", "sample: {}\n")
        put(self.ha, "blueprints/automation/sample.yaml", "blueprint: {}\n")
        put(self.ha, "packages/sample.yaml", "input_boolean: {}\n")
        for name in ("core.area_registry", "core.floor_registry", "core.device_registry", "core.entity_registry", "core.label_registry",
                     "lovelace", "lovelace.dashboard_main", "lovelace.map", "lovelace_resources", "lovelace_dashboards"):
            put(self.ha, ".storage/" + name, '{"data":{}}\n')
        self.expected = {"nodered/" + name for name in ("flows.json", "settings.js", "package.json")}
        self.expected.update("homeassistant/" + str(path.relative_to(self.ha)) for path in self.ha.rglob("*") if path.is_file())
        for name in ("flows_cred.json", ".flows_cred.json", "flows.json.bak", "flows.json.bak-old", ".config.users.json", "context/state.json", "unknown.json"):
            put(self.nr, name, "{}\n")
        for name in ("secrets.yaml", ".storage/auth", ".storage/auth_provider.homeassistant", ".storage/core.config_entries", ".storage/onboarding",
                     ".storage/core.category_registry", ".storage/lovelace.dashboard_main.bak.20260101", ".storage/lovelace.dashboard_main.bak",
                     ".storage/lovelace.bak", ".storage/lovelace.bak-20260101", ".storage/lovelace.BAK",
                     ".storage/lovelace_backup", "home-assistant_v2.db", "home-assistant.log", ".cloud/data", "tts/voice.mp3",
                     "configuration.yaml.bak", "!archiv/automation.yaml", "themes/!archiv/old.yaml", "themes/sample.bak.yaml", "blueprints/test.yaml.bak",
                     "packages/.hidden.yaml", "unknown.yaml", "themes/README.txt"):
            put(self.ha, name, "{}\n")

    def run_snapshot(self, *, ok=True, git=None, gitleaks=None, verify_only=False, gc_only=False):
        configuration = implementation.Settings(repo=self.repo, runtime=self.runtime, nodered=self.nr,
                                                homeassistant=self.ha, git=git or GIT, gitleaks=gitleaks or GITLEAKS,
                                                scanner_config=SCANNER_CONFIG)
        output = io.StringIO()
        previous_mask = os.umask(0o027)
        try:
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                with mock.patch.object(implementation, "in_service_unit", return_value=True):
                    result = implementation.run(configuration, verify_only=verify_only, gc_only=gc_only, debounce_seconds=0)
        finally:
            os.umask(previous_mask)
        self.assertEqual(result, 0 if ok else 1, output.getvalue())
        self.assertNotIn(self.setting_value, output.getvalue())
        self.assertNotIn(self.planted_value, output.getvalue())
        return output.getvalue()

    def git(self, *arguments, check=True, data=None):
        result = subprocess.run([GIT, "-C", str(self.repo), *arguments], capture_output=True,
                                input=data, env=implementation.private_environment(self.runtime), timeout=10)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr.decode())
        return result.stdout

    def head(self):
        return self.git("rev-parse", "--verify", "HEAD", check=False)

    def tree(self):
        return set(filter(None, self.git("ls-tree", "-rz", "--name-only", "HEAD").decode().split("\0")))

    def source_state(self):
        return {str(path.relative_to(self.root)): (path.stat().st_mode, path.read_bytes())
                for root in (self.nr, self.ha) for path in root.rglob("*") if path.is_file()}

    def assert_history_permissions(self):
        for path in (self.repo, *self.repo.rglob("*")):
            info = path.stat()
            self.assertFalse(info.st_mode & 0o027, str(path))
            self.assertEqual(info.st_gid, self.repo.stat().st_gid, str(path))
            if path.is_dir():
                self.assertEqual(stat.S_IMODE(info.st_mode), 0o2750, str(path))
            else:
                self.assertIn(stat.S_IMODE(info.st_mode), (0o440, 0o640), str(path))

    def restricted_permission_flow(self):
        before = self.source_state()
        stale = self.repo / ".snapshot-init-deadbeef"
        stale.mkdir(mode=0o750)
        put(stale, "config.lock", "synthetic interrupted initialization\n")
        self.assertIn("removed stale service initialization", self.run_snapshot())
        self.assert_history_permissions()
        first = self.head()
        self.assertTrue(first)
        self.assertEqual(self.git("config", "core.sharedRepository").strip(), b"0640")
        self.assertIn("unchanged", self.run_snapshot())
        self.assertEqual(self.head(), first)
        put(self.ha, "automations.yaml", "# restricted changed snapshot\n[]\n")
        self.run_snapshot()
        second = self.head()
        self.assertNotEqual(second, first)
        self.run_snapshot(gc_only=True)
        self.assertEqual(self.head(), second)
        self.assertTrue((self.repo / ".git/gc-success").is_file())
        self.assertTrue(any((self.repo / ".git/objects/pack").glob("*.pack")))
        put(self.ha, "scripts.yaml", "# restricted after GC\n{}\n")
        self.run_snapshot()
        self.run_snapshot(verify_only=True)
        self.assert_history_permissions()
        self.assertEqual(self.tree(), self.expected)
        self.assertFalse(list(self.repo.glob(".snapshot-init-*")))
        # Only the two intentional fixture edits above may change source state.
        for name in ("homeassistant/automations.yaml", "homeassistant/scripts.yaml"):
            before.pop(name)
        after = self.source_state()
        for name in ("homeassistant/automations.yaml", "homeassistant/scripts.yaml"):
            after.pop(name)
        self.assertEqual(before, after)

    def test_restrict_suid_sgid_covers_first_repeat_changed_gc_and_verify(self):
        with restrict_suid_sgid():
            self.restricted_permission_flow()

    def test_restrict_suid_sgid_emulator_rejects_each_mode_api(self):
        target = self.root / "mode-control"
        target.touch()
        with target.open("rb") as handle, restrict_suid_sgid():
            for bit in (stat.S_ISUID, stat.S_ISGID):
                for function, arguments in ((os.chmod, (target, bit | 0o640)),
                                            (os.fchmod, (handle.fileno(), bit | 0o640)),
                                            (os.mkdir, (self.root / "forbidden-dir", bit | 0o750)),
                                            (os.open, (self.root / "forbidden-file", os.O_CREAT | os.O_WRONLY, bit | 0o640))):
                    with self.subTest(function=function, bit=bit), self.assertRaises(PermissionError) as raised:
                        function(*arguments)
                    self.assertEqual(raised.exception.errno, errno.EPERM)

    @unittest.skipUnless(sys.platform == "linux", "Linux seccomp/Git syscall proof runs in check.yml; macOS uses the Python emulator")
    def test_linux_seccomp_covers_real_git_subprocesses(self):
        result = subprocess.run([sys.executable, __file__, "--seccomp-flow"], capture_output=True, timeout=90)
        self.assertEqual(result.returncode, 0, (result.stdout + result.stderr).decode())
        self.assertIn(b"real Git first/repeat/changed/GC/post-GC/verify passed under seccomp", result.stdout)

    def test_allowlist_redaction_author_and_read_only_sources(self):
        before = self.source_state()
        self.run_snapshot()
        self.assertEqual(self.tree(), self.expected)
        filtered = self.git("show", "HEAD:nodered/settings.js").decode()
        self.assertIn('credentialSecret: "[REDACTED]"', filtered)
        self.assertNotIn(self.setting_value, filtered)
        # Search every object, including unreachable blobs: the real credential never entered Git.
        objects = self.git("cat-file", "--batch-all-objects", "--batch")
        self.assertNotIn(self.setting_value.encode(), objects)
        self.assertEqual(self.git("log", "-1", "--format=%an <%ae>|%cn <%ce>").decode().strip(),
                         "hsb1-home-config <root@hsb1>|hsb1-home-config <root@hsb1>")
        message = self.git("log", "-1", "--format=%B").decode()
        self.assertIn("snapshot homeassistant,nodered:", message)
        for name in self.expected:
            self.assertIn(name, message)
        self.assertEqual(self.source_state(), before)
        self.assertFalse(self.git("remote"))
        self.assertEqual(self.git("config", "core.sharedRepository").strip(), b"0640")
        self.assertEqual(self.repo.stat().st_mode & 0o7777, 0o2750)
        self.assertEqual(self.git("rev-parse", "--is-bare-repository").strip(), b"true")
        self.assertFalse((self.repo / ".git/index").exists())
        self.assert_history_permissions()

    def test_planted_index_hook_is_disabled_even_with_local_hooks_override(self):
        self.run_snapshot()
        hooks = self.repo / ".git/hooks"
        marker = self.root / "hook-ran"
        put(hooks, "post-index-change", "#!/bin/sh\ntouch '" + str(marker) + "'\n")
        (hooks / "post-index-change").chmod(0o750)
        for configured in (False, True):
            with self.subTest(configured=configured):
                if configured:
                    self.git("config", "core.hooksPath", str(hooks))
                put(self.ha, "automations.yaml", "# hook fixture " + str(configured) + "\n[]\n")
                first = self.head()
                self.run_snapshot()
                self.assertNotEqual(self.head(), first)
                self.assertFalse(marker.exists(), "snapshot Git executed a planted hook")
        # Prove that this executable hook really fires when the override is absent.
        subprocess.run([GIT, "-C", str(self.repo), "read-tree", "HEAD"], check=True, capture_output=True,
                       env=implementation.private_environment(self.runtime) | {"GIT_INDEX_FILE": str(self.runtime / "control-index")},
                       timeout=10)
        self.assertTrue(marker.exists(), "control did not exercise the planted hook")

    def test_every_git_operation_fsyncs_objects_and_references_despite_local_config(self):
        wrapper = self.root / "git-fsync-check"
        record = self.root / "git-operations"
        wrapper.write_text("#!" + sys.executable + "\nimport os, subprocess, sys\n"
                           "arguments = sys.argv[1:]\nend = arguments.index('-C') + 2\n"
                           + "result = subprocess.run([" + repr(GIT) + "] + arguments[:end] + ['config', '--get', 'core.fsync'], capture_output=True)\n"
                           "if result.returncode or result.stdout.strip() != b'loose-object,reference':\n    sys.exit(18)\n"
                           + "with open(" + repr(str(record)) + ", 'a') as log:\n    log.write(arguments[end] + '\\n')\n"
                           + "os.execv(" + repr(GIT) + ", [" + repr(GIT) + "] + arguments)\n")
        wrapper.chmod(0o700)
        self.run_snapshot(git=str(wrapper))
        self.git("config", "core.fsync", "none")
        put(self.ha, "automations.yaml", "# fsync fixture\n[]\n")
        self.run_snapshot(git=str(wrapper))
        self.run_snapshot(git=str(wrapper), verify_only=True)
        self.run_snapshot(git=str(wrapper), gc_only=True)
        self.assertTrue({"init", "hash-object", "commit-tree", "gc"} <= set(record.read_text().splitlines()))

    def test_group_writable_config_is_refused_before_git_for_every_mode(self):
        self.run_snapshot()
        first = self.head()
        config = self.repo / ".git/config"
        config.chmod(0o660)
        before = (config.read_bytes(), config.stat().st_mtime_ns)
        stamp = self.repo / ".git/snapshot-success"
        stamp_time = stamp.stat().st_mtime_ns
        for mode in ({}, {"verify_only": True}, {"gc_only": True}):
            with self.subTest(mode=mode), mock.patch.object(implementation, "git", wraps=implementation.git) as commands:
                self.assertIn("Git config must be a service-owned regular file with mode 0640", self.run_snapshot(ok=False, **mode))
                commands.assert_not_called()
        self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o660)
        self.assertEqual((config.read_bytes(), config.stat().st_mtime_ns), before)
        self.assertEqual(stamp.stat().st_mtime_ns, stamp_time)
        self.assertEqual(self.head(), first)

    def test_config_symlink_and_wrong_owner_are_refused_before_git(self):
        self.run_snapshot()
        config = self.repo / ".git/config"
        original_lstat = Path.lstat

        def wrong_owner(path, *args, **kwargs):
            info = original_lstat(path, *args, **kwargs)
            if path == config:
                fields = list(info)
                fields[4] = os.geteuid() + 1
                return os.stat_result(fields)
            return info

        with (mock.patch.object(Path, "lstat", wrong_owner),
              mock.patch.object(implementation, "git", wraps=implementation.git) as commands):
            self.assertIn("Git config must be a service-owned regular file", self.run_snapshot(ok=False))
            commands.assert_not_called()
        saved = self.root / "saved-config"
        config.rename(saved)
        config.symlink_to(saved)
        before = saved.read_bytes()
        with mock.patch.object(implementation, "git", wraps=implementation.git) as commands:
            self.assertIn("Git config must be a service-owned regular file", self.run_snapshot(ok=False))
            commands.assert_not_called()
        self.assertTrue(config.is_symlink())
        self.assertEqual(saved.read_bytes(), before)

    def test_empty_initialized_repository_can_publish_its_first_root(self):
        configuration = implementation.Settings(repo=self.repo, runtime=self.runtime, git=GIT)
        implementation.prepare_repo(configuration, False)
        self.assertFalse(self.head())
        self.assertFalse((self.repo / ".git/snapshot-success").exists())
        self.assertFalse(self.git("cat-file", "--batch-all-objects", "--batch-check"))
        self.run_snapshot()
        self.assertEqual(len(self.git("rev-list", "--parents", "HEAD").split()), 1)
        self.assertTrue((self.repo / ".git/snapshot-success").is_file())

    def test_unborn_head_with_objects_but_no_success_stamp_is_refused(self):
        configuration = implementation.Settings(repo=self.repo, runtime=self.runtime, git=GIT)
        implementation.prepare_repo(configuration, False)
        self.git("hash-object", "-w", "--stdin", data=b"synthetic interrupted first snapshot\n")
        objects = self.git("cat-file", "--batch-all-objects", "--batch")
        with mock.patch.object(implementation, "candidate", wraps=implementation.candidate) as sources:
            self.assertIn("snapshot HEAD missing from existing history", self.run_snapshot(ok=False))
            sources.assert_not_called()
        self.assertFalse(self.head())
        self.assertFalse((self.repo / ".git/snapshot-success").exists())
        self.assertEqual(self.git("cat-file", "--batch-all-objects", "--batch"), objects)

    def test_unborn_head_with_success_stamp_but_no_objects_is_refused(self):
        configuration = implementation.Settings(repo=self.repo, runtime=self.runtime, git=GIT)
        implementation.prepare_repo(configuration, False)
        stamp = self.repo / ".git/snapshot-success"
        stamp.touch(mode=0o640)
        before = stamp.stat().st_mtime_ns
        self.assertIn("snapshot HEAD missing from existing history", self.run_snapshot(ok=False))
        self.assertFalse(self.head())
        self.assertFalse(self.git("cat-file", "--batch-all-objects", "--batch-check"))
        self.assertEqual(stamp.stat().st_mtime_ns, before)

    def test_lost_loose_or_packed_main_refuses_and_pages_without_replacing_history(self):
        engine, witness = alert_modules()
        self.run_snapshot()
        for packed in (False, True):
            with self.subTest(packed=packed):
                if packed:
                    self.run_snapshot(gc_only=True)
                    self.assertFalse((self.repo / ".git/refs/heads/main").exists())
                    self.assertIn(b"refs/heads/main", (self.repo / ".git/packed-refs").read_bytes())
                first = self.head().decode().strip()
                objects = self.git("cat-file", "--batch-all-objects", "--batch")
                self.git("update-ref", "-d", "refs/heads/main")
                stamp = self.repo / ".git/snapshot-success"
                now = time.time()
                os.utime(stamp, (now - witness.MAX_AGE - 1,) * 2)
                before = stamp.stat().st_mtime_ns
                for mode in ({}, {"verify_only": True}, {"gc_only": True}):
                    with self.subTest(mode=mode):
                        self.assertIn("snapshot HEAD missing from existing history", self.run_snapshot(ok=False, **mode))
                self.assertFalse(self.head())
                self.assertEqual(stamp.stat().st_mtime_ns, before)
                self.assertEqual(self.git("cat-file", "--batch-all-objects", "--batch"), objects)
                sent = []

                def sender(text, event_id):
                    sent.append(text)
                    return True

                state = str(self.root / ("lost-head-alert-" + str(packed) + ".json"))
                with mock.patch.object(witness, "SUCCESS", stamp), mock.patch.object(witness.time, "time", return_value=now):
                    self.assertEqual([problem.key for problem in witness.collect()], ["home-config:stale"])
                    for observed in (now, now + 1, now + 2):
                        engine.run_cycle(state, observed, witness.collect, witness.render, sender)
                    self.assertEqual(len(sent), 1)
                    # Explicit fixture-only operator recovery, never automatic service repair.
                    self.git("update-ref", "refs/heads/main", first)
                    self.run_snapshot()
                with mock.patch.object(witness, "SUCCESS", stamp), mock.patch.object(witness.time, "time", return_value=now + 3):
                    engine.run_cycle(state, now + 3, witness.collect, witness.render, sender)
                self.assertEqual(self.head().decode().strip(), first)
                self.assertEqual(len(sent), 2)
                self.assertIn("Cleared:", sent[1])

    def test_no_commit_when_unchanged_and_single_source_message(self):
        self.run_snapshot()
        first = self.head()
        with (mock.patch.object(implementation, "scan_tree", wraps=implementation.scan_tree) as scanner,
              mock.patch.object(implementation, "git", wraps=implementation.git) as commands):
            self.assertIn("unchanged; no commit", self.run_snapshot())
            scanner.assert_not_called()
            self.assertFalse(any(call.args[1] in {"hash-object", "update-index", "commit-tree"} for call in commands.call_args_list))
        self.assertEqual(self.head(), first)
        put(self.ha, "automations.yaml", "# changed fixture\n[]\n")
        with mock.patch.object(implementation, "git", wraps=implementation.git) as commands:
            self.run_snapshot()
            self.assertEqual(sum(call.args[1] == "hash-object" for call in commands.call_args_list), 1)
        self.assertNotEqual(self.head(), first)
        self.assertEqual(self.git("rev-list", "--count", "HEAD").strip(), b"2")
        self.assertEqual(self.git("log", "-1", "--format=%B").decode().strip(),
                         "snapshot homeassistant: homeassistant/automations.yaml")

    def test_planted_secret_aborts_before_any_git_blob_or_source_write(self):
        self.run_snapshot()
        first = self.head()
        put(self.ha, "automations.yaml", 'api_key: "' + self.planted_value + '" # gitleaks:allow\n')
        before = self.source_state()
        output = self.run_snapshot(ok=False)
        self.assertRegex(output, r"rule=[a-z0-9-]+ file=homeassistant/automations.yaml line=1")
        self.assertEqual(self.head(), first)
        self.assertNotIn(self.planted_value.encode(), self.git("cat-file", "--batch-all-objects", "--batch"))
        self.assertFalse((self.repo / ".git/index").exists())
        self.assertEqual(self.source_state(), before)

    def test_remote_guard_also_runs_when_sources_unchanged(self):
        self.run_snapshot()
        first = self.head()
        self.git("remote", "add", "forbidden", "https://example.invalid/never-contacted")
        self.assertIn("remote configured", self.run_snapshot(ok=False))
        put(self.ha, "scripts.yaml", "# changed\n[]\n")
        self.run_snapshot(ok=False)
        self.assertEqual(self.head(), first)

    def test_large_flows_and_hidden_registry_are_scanned(self):
        for root, name in ((self.nr, "flows.json"), (self.ha, ".storage/core.device_registry")):
            with self.subTest(name=name):
                previous = (root / name).read_text()
                # Larger than the live 4.2 MB flows file: no scanner size skip.
                content = {"padding": " " * 4_300_000, "api_key": self.planted_value}
                put(root, name, json.dumps(content))
                output = self.run_snapshot(ok=False)
                self.assertIn("file=" + ("nodered/" if root == self.nr else "homeassistant/") + name, output)
                self.assertFalse(self.head())
                put(root, name, previous)

    def test_candidate_and_exact_index_export_are_both_scanned(self):
        wrapper = self.root / "scanner-wrapper"
        record = self.root / "scanner-targets"
        wrapper.write_text("#!" + sys.executable + "\nimport os, sys\n"
                           + "with open(" + repr(str(record)) + ", 'a') as log:\n    log.write(sys.argv[2] + '\\n')\n"
                           + "os.execv(" + repr(GITLEAKS) + ", [" + repr(GITLEAKS) + "] + sys.argv[1:])\n")
        wrapper.chmod(0o700)
        self.run_snapshot(gitleaks=str(wrapper))
        targets = [Path(name) for name in record.read_text().splitlines()]
        self.assertEqual(len(targets), 2)
        self.assertTrue(targets[0].name.startswith("snapshot-"))
        self.assertTrue(targets[1].parent.name.startswith("index-"))
        self.assertEqual(targets[1].name, "tree")

    def test_optional_deletion_is_versioned_required_absence_fails_closed(self):
        self.run_snapshot()
        (self.ha / "scripts.yaml").unlink()
        self.run_snapshot()
        self.assertNotIn("homeassistant/scripts.yaml", self.tree())
        first = self.head()
        (self.nr / "flows.json").unlink()
        self.assertIn("required source file missing", self.run_snapshot(ok=False))
        self.assertEqual(self.head(), first)

    def test_symlinks_and_hardlinks_fail_without_reading_their_target(self):
        for kind in ("symlink", "hardlink"):
            with self.subTest(kind=kind):
                selected = self.ha / "automations.yaml"
                selected.unlink()
                target = self.root / "outside-file"
                target.write_text(self.planted_value)
                if kind == "symlink":
                    selected.symlink_to(target)
                else:
                    os.link(target, selected)
                with mock.patch.object(implementation, "read_source", wraps=implementation.read_source) as reader:
                    output = self.run_snapshot(ok=False)
                    self.assertIn("source must be a regular, single-link file", output)
                    self.assertIn("homeassistant/automations.yaml", output)
                    self.assertNotIn("homeassistant/automations.yaml", [call.args[1] for call in reader.call_args_list])
                self.assertFalse(self.head())
                selected.unlink()
                selected.write_text("[]\n")

    def test_unknown_files_are_not_even_opened(self):
        forbidden = self.nr / "unknown.json"
        forbidden.unlink()
        forbidden.symlink_to(self.root / "does-not-exist")
        self.run_snapshot()
        self.assertEqual(self.tree(), self.expected)

    def test_pending_operator_work_is_preserved(self):
        self.run_snapshot()
        first = self.head()
        put(self.repo, "operator-note.txt", "leave this alone\n")
        self.assertIn("pending changes", self.run_snapshot(ok=False))
        self.assertEqual((self.repo / "operator-note.txt").read_text(), "leave this alone\n")
        self.assertEqual(self.head(), first)

    def test_tracked_unknown_path_is_rejected(self):
        self.run_snapshot()
        blob = self.git("hash-object", "-w", "--stdin", data=b"fixture\n").strip()
        tree = self.git("mktree", data=self.git("ls-tree", "HEAD") + b"100644 blob " + blob + b"\tunknown.txt\n").strip()
        commit = self.git("commit-tree", tree.decode(), "-p", self.head().decode().strip(), data=b"fixture operator change\n").strip()
        self.git("update-ref", "refs/heads/main", commit.decode())
        first = self.head()
        self.assertIn("non-allowlisted", self.run_snapshot(ok=False))
        self.assertEqual(self.head(), first)

    def test_scanner_failure_never_echoes_output(self):
        scanner = self.root / "broken-scanner"
        scanner.write_text("#!/bin/sh\nprintf '%s\\n' '" + self.planted_value + "' >&2\nexit 2\n")
        scanner.chmod(0o700)
        self.assertIn("secret scanner failed", self.run_snapshot(gitleaks=str(scanner), ok=False))
        self.assertFalse(self.head())

    def test_exact_staged_tree_cannot_differ_from_scanned_candidate(self):
        # Simulate a Git filter/index writer changing the staged bytes after pre-scan.
        wrapper = self.root / "git-wrapper"
        wrapper.write_text("#!" + sys.executable + "\nimport os, subprocess, sys\n"
                           + "command = [" + repr(GIT) + "] + sys.argv[1:]\n"
                           + "result = subprocess.run(command)\n"
                           + "if 'update-index' in sys.argv and result.returncode == 0:\n"
                           + "    base = [" + repr(GIT) + ", '-C', " + repr(str(self.repo)) + "]\n"
                           + "    blob = subprocess.run(base + ['hash-object', '-w', '--stdin'], input="
                           + repr(('api_key: "' + self.planted_value + '"\n').encode()) + ", capture_output=True, check=True).stdout.decode().strip()\n"
                           + "    subprocess.run(base + ['update-index', '--cacheinfo', '100644,' + blob + ',homeassistant/automations.yaml'], check=True)\n"
                           + "sys.exit(result.returncode)\n")
        wrapper.chmod(0o700)
        self.assertIn("staged tree differs", self.run_snapshot(git=str(wrapper), ok=False))
        self.assertFalse(self.head())

    def test_verify_only_scans_head_and_hash_checks_live_credential(self):
        self.run_snapshot()
        first = self.head()
        before = self.source_state()
        metadata = {str(path.relative_to(self.repo)): (path.stat().st_mode, path.stat().st_gid, path.stat().st_mtime_ns, path.read_bytes())
                    for path in self.repo.rglob("*") if path.is_file()}
        self.assertIn("verified HEAD", self.run_snapshot(verify_only=True))
        self.assertEqual(self.head(), first)
        self.assertEqual(self.source_state(), before)
        self.assertEqual({str(path.relative_to(self.repo)): (path.stat().st_mode, path.stat().st_gid, path.stat().st_mtime_ns, path.read_bytes())
                          for path in self.repo.rglob("*") if path.is_file()}, metadata)
        self.assertEqual(self.repo.stat().st_mode & 0o7777, 0o2750)
        self.assert_history_permissions()

    def test_harmless_non_directory_entries_are_skipped_and_counted(self):
        put(self.ha, "themes/catppuccin/catppuccin-accents.zip", "synthetic ZIP payload\n")
        put(self.ha, "themes/LICENSE", "synthetic license\n")
        (self.ha / "themes/linked-theme").symlink_to(self.root / "missing-directory")
        output = self.run_snapshot()
        self.assertEqual(self.tree(), self.expected)
        self.assertRegex(output, r"ignored entries=\d+ skipped_yaml=\d+")

    def test_source_io_failure_names_the_path_without_error_body(self):
        original = implementation.os.open

        def fail_selected(path, *args, **kwargs):
            if path == "automations.yaml":
                raise PermissionError(13, self.planted_value)
            return original(path, *args, **kwargs)

        with mock.patch.object(implementation.os, "open", side_effect=fail_selected):
            self.assertIn("I/O failure: path=homeassistant/automations.yaml errno=13", self.run_snapshot(ok=False))

    def test_new_scanner_rules_each_reject_a_planted_value(self):
        bcrypt = "$" + "2b$08$" + "A" * 53
        probes = {
            "bcrypt": "fixture: '" + bcrypt + "'\n",
            "url-credentials": "url: https://fixture:short-pass@example.invalid/path\n",
            "yaml-credential": "password: short!with symbols $@\n",
            "query-token": "url: https://example.invalid/?token=short-token&x=1\n",
        }
        for rule, payload in probes.items():
            with self.subTest(rule=rule):
                put(self.ha, "automations.yaml", payload)
                self.assertIn("rule=home-config-" + rule + " ", self.run_snapshot(ok=False))
                self.assertFalse(self.head())

    def test_yaml_credential_keys_and_reference_exclusions(self):
        for key in ("password", "passwd", "pass", "token", "api_key", "secret", "wifi_password",
                    "client_secret", "api_password", "access_token", "wifi-password", "clientSecret"):
            with self.subTest(key=key):
                put(self.ha, "automations.yaml", key + ": very short!\n")
                self.assertIn("rule=home-config-yaml-credential ", self.run_snapshot(ok=False))
        for payload in ("{password: x}\n", "wifi: {wifi_password: x}\n",
                        "wifi: {password: !secret fixture_password, access_token: x}\n",
                        "- wifi_password: x\n", "credentials: {client_secret: x, api_password: y}\n"):
            with self.subTest(payload=payload):
                put(self.ha, "automations.yaml", payload)
                self.assertIn("rule=home-config-yaml-credential ", self.run_snapshot(ok=False))
        put(self.ha, "automations.yaml", "wifi_password: !secret fixture_password\naccess_token: !env_var FIXTURE_TOKEN\n"
            "wifi: {password: !secret fixture_password, client_secret: !env_var FIXTURE_SECRET}\n")
        self.run_snapshot()

    def test_known_settings_template_comments_and_ha_include_shapes_pass(self):
        bcrypt = "$" + "2b$08$" + "A" * 53
        put(self.nr, "settings.js", 'module.exports = {\ncredentialSecret: "' + self.setting_value + '",\n'
            '// adminAuth: {users: [{username: "admin", password: "' + bcrypt + '"}]},\n'
            '// httpNodeAuth: {user: "user", pass: "' + bcrypt + '"},\n'
            '// httpStaticAuth: {user: "user", pass: "' + bcrypt + '"},\n};\n')
        put(self.ha, "configuration.yaml", "automation: !include automations.yaml\nscript: !include scripts.yaml\n"
            "scene: !include scenes.yaml\nhomeassistant:\n  customize: !include customize.yaml\n"
            "frontend:\n  themes: !include_dir_merge_named themes\n")
        self.run_snapshot()
        self.run_snapshot(verify_only=True)
        self.assertNotIn(bcrypt.encode(), self.git("cat-file", "--batch-all-objects", "--batch"))

    def test_node_red_function_credential_expressions_pass_real_scanner(self):
        expressions = ('node.send({payload: msg.payload, token: msg.token})',
                       '{grant_type: "refresh_token", refresh_token: flow.get("rt")}',
                       '{user: u, pass: p}', '{password: env.get("PW")}')
        flows = json.dumps([{"id": str(index), "type": "function", "func": expression}
                            for index, expression in enumerate(expressions)]) + "\n"
        put(self.nr, "flows.json", flows)
        self.run_snapshot()
        self.assertEqual(self.git("show", "HEAD:nodered/flows.json"), flows.encode())
        self.run_snapshot(verify_only=True)

    def test_redacted_auth_passwords_and_comment_bcrypt_pass_real_scanner(self):
        bcrypt = "$" + "2b$08$" + "A" * 53
        for key in ("adminAuth", "httpNodeAuth", "httpStaticAuth"):
            with self.subTest(key=key):
                put(self.nr, "settings.js", 'module.exports = {credentialSecret: "' + self.setting_value
                    + '", ' + key + ': {users: [{password: "' + bcrypt + '", pass: "auth-fixture-value"}]}};\n'
                    + '// template password: "' + bcrypt + '"\n')
                self.run_snapshot()
                objects = self.git("cat-file", "--batch-all-objects", "--batch")
                self.assertNotIn(bcrypt.encode(), objects)
                self.assertNotIn(b"auth-fixture-value", objects)

    def test_full_run_outside_unit_is_refused_before_any_state_change(self):
        configuration = implementation.Settings(repo=self.repo, runtime=self.runtime, nodered=self.nr,
                                               homeassistant=self.ha, git=GIT, gitleaks=GITLEAKS,
                                               scanner_config=SCANNER_CONFIG)
        for gc_only in (False, True):
            for invocation in ("", "0" * 32):
                with (mock.patch.dict(os.environ, {"INVOCATION_ID": invocation}),
                      mock.patch.object(implementation.Path, "read_text", return_value="0::/user.slice/manual.scope\n"),
                      contextlib.redirect_stdout(io.StringIO()) as output):
                    self.assertEqual(implementation.run(configuration, gc_only=gc_only, debounce_seconds=0), 1)
                    self.assertIn("require the systemd unit", output.getvalue())
        self.assertFalse((self.repo / ".git").exists())
        self.assertEqual(list(self.runtime.iterdir()), [])

    def test_unit_guard_requires_the_correct_complete_cgroup_component(self):
        for gc_only in (False, True):
            unit = "hsb1-home-config-gc.service" if gc_only else "hsb1-home-config.service"
            other = "hsb1-home-config.service" if gc_only else "hsb1-home-config-gc.service"
            for prefix in ("0::", "7:memory:"):
                for path, expected in (("/system.slice/" + unit, True), ("/system.slice/" + unit + "/child", True),
                                       ("/system.slice/" + other, False), ("/system.slice/prefix-" + unit, False),
                                       ("/system.slice/" + unit + "-suffix", False), ("/user.slice/manual.scope", False)):
                    with self.subTest(gc_only=gc_only, prefix=prefix, path=path):
                        with mock.patch.object(implementation.Path, "read_text", return_value=prefix + path + "\n"):
                            self.assertEqual(implementation.in_service_unit(gc_only), expected)
        with mock.patch.object(implementation.Path, "read_text", side_effect=FileNotFoundError):
            self.assertFalse(implementation.in_service_unit(False))

    def test_sigkill_during_scan_or_ref_publication_does_not_block_next_run(self):
        for phase in ("init", "scan", "publish"):
            with self.subTest(phase=phase):
                first = self.head()
                put(self.ha, "automations.yaml", "# interrupted phase " + phase + "\n[]\n")
                ready = self.root / ("ready-" + phase)
                program = (
                    "import importlib.util, os, signal, sys\nfrom pathlib import Path\n"
                    "spec = importlib.util.spec_from_file_location('home_config', " + repr(str(SCRIPT)) + ")\n"
                    "module = importlib.util.module_from_spec(spec)\nsys.modules[spec.name] = module\nspec.loader.exec_module(module)\n"
                    "module.in_service_unit = lambda gc_only: True\n"
                    "original_scan, original_replace, original_git = module.scan_tree, module.os.replace, module.git\ncount = 0\n"
                    "def pause():\n    Path(" + repr(str(ready)) + ").touch()\n    signal.pause()\n"
                    "def git(*args, **kwargs):\n    result = original_git(*args, **kwargs)\n"
                    "    if args[1] == 'init' and " + repr(phase) + " == 'init':\n        pause()\n    return result\n"
                    "def scan(args, tree):\n    global count\n    original_scan(args, tree)\n    count += 1\n"
                    "    if count == 2 and " + repr(phase) + " == 'scan':\n        pause()\n"
                    "def replace(source, destination):\n    if Path(destination).name == 'main' and " + repr(phase)
                    + " == 'publish':\n        pause()\n    original_replace(source, destination)\n"
                    "module.scan_tree, module.os.replace, module.git = scan, replace, git\n"
                    "args = module.Settings(repo=Path(" + repr(str(self.repo)) + "), runtime=Path(" + repr(str(self.runtime))
                    + "), nodered=Path(" + repr(str(self.nr)) + "), homeassistant=Path(" + repr(str(self.ha))
                    + "), scanner_config=Path(" + repr(str(SCANNER_CONFIG)) + "), git=" + repr(GIT) + ", gitleaks=" + repr(GITLEAKS) + ")\n"
                    "sys.exit(module.run(args, debounce_seconds=0))\n"
                )
                child = subprocess.Popen([sys.executable, "-c", program], stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                try:
                    deadline = time.monotonic() + 15
                    while not ready.exists() and child.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(ready.exists(), "child did not reach the interruption point")
                finally:
                    if child.poll() is None:
                        os.killpg(child.pid, signal.SIGKILL)
                    child.communicate(timeout=5)
                self.assertEqual(self.head(), first)
                self.assertFalse((self.repo / ".git/index").exists())
                self.assertIn("removed stale service", self.run_snapshot())
                self.assertNotEqual(self.head(), first)
                self.assertFalse(any(path.name.startswith(("snapshot-", "index-", "scan-")) for path in self.runtime.iterdir()))

    def test_verify_preserves_an_unexpected_shared_index(self):
        self.run_snapshot()
        index = self.repo / ".git/index"
        index.write_bytes(b"synthetic operator-owned index sentinel")
        before = (index.read_bytes(), index.stat().st_mode, index.stat().st_gid, index.stat().st_mtime_ns)
        self.assertIn("unexpected index or ref lock", self.run_snapshot(verify_only=True, ok=False))
        self.assertEqual((index.read_bytes(), index.stat().st_mode, index.stat().st_gid, index.stat().st_mtime_ns), before)

    def test_stale_scratch_is_cleared_even_when_repository_checks_refuse(self):
        self.run_snapshot()
        outside = self.root / "preserve-me"
        outside.mkdir()
        put(outside, "sentinel", "preserve synthetic outside data\n")
        for prefix in ("snapshot", "index"):
            put(self.runtime, prefix + "-deadbeef/raw", "synthetic abandoned candidate\n")
        (self.runtime / "scan-deadbeef").symlink_to(outside, target_is_directory=True)
        put(self.repo, "operator-note.txt", "preserve this too\n")
        self.assertIn("pending changes", self.run_snapshot(ok=False))
        self.assertFalse(any(path.name.endswith("deadbeef") for path in self.runtime.iterdir()))
        self.assertTrue((outside / "sentinel").is_file())
        self.assertTrue((self.repo / "operator-note.txt").is_file())

    def test_burst_waits_for_one_quiet_interval_and_uses_latest_bytes(self):
        changes = ["# first burst\n[]\n", "# second burst\n[]\n"]
        sleeps = []

        def change_during_wait(seconds):
            sleeps.append(seconds)
            if changes:
                put(self.ha, "automations.yaml", changes.pop(0))

        with mock.patch.object(implementation.time, "sleep", side_effect=change_during_wait):
            contents, _ = implementation.candidate({"nodered": self.nr, "homeassistant": self.ha}, 20)
        self.assertEqual(sleeps, [20, 20, 20])
        self.assertEqual(contents["homeassistant/automations.yaml"], b"# second burst\n[]\n")

    def test_invalid_json_is_not_committed(self):
        put(self.nr, "flows.json", '[{"incomplete":')
        self.assertIn("invalid JSON in nodered/flows.json", self.run_snapshot(ok=False))
        self.assertFalse(self.head())

    def test_lock_serializes_timer_path_and_manual_runs(self):
        with (self.runtime / "snapshot.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertIn("already running", self.run_snapshot())
            self.assertIn("verification busy", self.run_snapshot(verify_only=True, ok=False))
            self.assertFalse((self.repo / ".git").exists())

    def test_periodic_gc_is_separate_and_preserves_snapshot_head(self):
        self.run_snapshot()
        first = self.head()
        self.assertFalse((self.repo / ".git/gc-success").exists())
        self.run_snapshot(gc_only=True)
        self.assertTrue((self.repo / ".git/gc-success").is_file())
        self.assertEqual(self.head(), first)
        self.assertTrue((self.repo / ".git/objects/pack").is_dir())
        put(self.ha, "automations.yaml", "# after packed refs\n[]\n")
        self.run_snapshot()
        self.run_snapshot(verify_only=True)
        self.assert_history_permissions()

    def test_failed_gc_and_successful_snapshots_never_refresh_gc_witness(self):
        self.run_snapshot()
        self.run_snapshot(gc_only=True)
        put(self.ha, "automations.yaml", "# create a loose ref that GC must pack\n[]\n")
        self.run_snapshot()
        stamp = self.repo / ".git/gc-success"
        os.utime(stamp, (100, 100))
        put(self.repo, ".git/packed-refs.lock", "synthetic abandoned GC lock\n")
        before = (stamp.read_bytes(), stamp.stat().st_mtime_ns)
        wrapper = self.root / "failing-gc"
        wrapper.write_text("#!" + sys.executable + "\nimport os, sys\n"
                           "if 'gc' in sys.argv[1:]:\n    sys.exit(17)\n"
                           + "os.execv(" + repr(GIT) + ", [" + repr(GIT) + "] + sys.argv[1:])\n")
        wrapper.chmod(0o700)
        self.assertIn("Git operation failed: gc", self.run_snapshot(git=str(wrapper), gc_only=True, ok=False))
        self.assertEqual((stamp.read_bytes(), stamp.stat().st_mtime_ns), before)
        self.run_snapshot()
        self.assertEqual((stamp.read_bytes(), stamp.stat().st_mtime_ns), before)
        self.assertTrue((self.repo / ".git/packed-refs.lock").is_file())


class SettingsTests(unittest.TestCase):
    def test_literal_quoting_escapes_and_comments(self):
        for literal in ('"fixture-credential-long"', "'fixture-credential-long'", r'"fixture\x2dcredential\u002dlong"'):
            with self.subTest(literal=literal):
                content = ('// credentialSecret: "comment",\nmodule.exports = {\n"credentialSecret": '
                           + literal + ', // retained comment\n};\n').encode()
                filtered, guard = implementation.redact_settings(content)
                self.assertIn(b'"credentialSecret": "[REDACTED]"', filtered)
                implementation.check_settings(filtered, guard)

    def test_unknown_expression_duplicate_and_absence_fail_closed(self):
        for declaration in ('credentialSecret: process.env.SECRET,', 'credentialSecret: `template`,',
                            'credentialSecret: "first-string", credentialSecret: "second-string",', 'flowFile: "flows.json",'):
            with self.subTest(declaration=declaration), self.assertRaises(implementation.Refused):
                implementation.redact_settings(('module.exports = {' + declaration + '};').encode())

    def test_hash_gate_detects_other_copy_and_escaped_source_spelling(self):
        for value in ('"fixture-credential-long"', r'"fixture\x2dcredential-long"'):
            with self.subTest(value=value), self.assertRaises(implementation.Refused):
                implementation.redact_settings(('module.exports = {credentialSecret: ' + value + ', another: ' + value + '};').encode())

    def test_hash_gate_also_decodes_differently_escaped_duplicate(self):
        with self.assertRaises(implementation.Refused):
            implementation.redact_settings(b'module.exports = {credentialSecret: "fixture-credential-long", another: "fixture\\x2dcredential-long"};')

    def test_auth_expressions_fail_closed(self):
        for auth in ('{password: process.env.PASSWORD}', '{password: `template`}', 'makeAuth()', '{password: "unterminated'):
            with self.subTest(auth=auth), self.assertRaises(implementation.Refused):
                implementation.redact_settings(('module.exports = {credentialSecret: "fixture-credential-long", adminAuth: ' + auth + '};').encode())

    def test_every_bcrypt_spelling_and_commented_example_is_redacted(self):
        for variant in ("", "a", "b", "x", "y"):
            with self.subTest(variant=variant):
                bcrypt = "$2" + variant + "$08$" + "A" * 53
                source = ('// template: ' + bcrypt + '\nmodule.exports = {credentialSecret: "fixture-credential-long",'
                          + ' sample: "' + bcrypt.replace("$", r"\x24") + '"};').encode()
                filtered, guard = implementation.redact_settings(source)
                self.assertNotIn(bcrypt.encode(), filtered)
                self.assertEqual(filtered.count(b"[REDACTED]"), 3)
                implementation.check_settings(filtered, guard)


class WitnessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.engine, cls.witness = alert_modules()

    def test_fresh_missing_stale_future_and_symlink_witness(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "success"
            self.assertEqual(self.witness.check_freshness(path, 10)[0].key, "home-config:missing")
            path.touch()
            os.utime(path, (100, 100))
            self.assertEqual(self.witness.check_freshness(path, 101), [])
            for now in (99, 100 + self.witness.MAX_AGE + 1):
                self.assertEqual(self.witness.check_freshness(path, now)[0].key, "home-config:stale")
            link = path.with_name("linked")
            link.symlink_to(path)
            self.assertEqual(self.witness.check_freshness(link, 101)[0].key, "home-config:stale")

    def test_gc_witness_grace_expiry_success_and_invalid_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            git_dir = Path(temporary)
            self.assertEqual(self.witness.check_gc(git_dir, 101)[0].key, "home-config:gc-missing")
            config = git_dir / "config"
            config.touch()
            os.utime(config, (100, 100))
            self.assertEqual(self.witness.check_gc(git_dir, 101), [])
            self.assertEqual(self.witness.check_gc(git_dir, 100 + self.witness.GC_MAX_AGE), [])
            self.assertEqual(self.witness.check_gc(git_dir, 101 + self.witness.GC_MAX_AGE)[0].key, "home-config:gc-stale")
            success = git_dir / "gc-success"
            success.touch()
            os.utime(success, (100 + self.witness.GC_MAX_AGE, 100 + self.witness.GC_MAX_AGE))
            self.assertEqual(self.witness.check_gc(git_dir, 101 + self.witness.GC_MAX_AGE), [])
            self.assertEqual(self.witness.check_gc(git_dir, 99)[0].key, "home-config:gc-stale")
            success.unlink()
            success.symlink_to(config)
            self.assertEqual(self.witness.check_gc(git_dir, 101)[0].key, "home-config:gc-stale")

    def test_stale_gc_locks_alert_without_deleting_or_reading_them(self):
        for name in self.witness.GC_LOCKS:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                git_dir = Path(temporary)
                success = git_dir / "gc-success"
                success.touch()
                os.utime(success, (100, 100))
                put(git_dir, name, "synthetic lock preserved for operator inspection\n")
                lock = git_dir / name
                os.utime(lock, (100, 100))
                self.assertEqual(self.witness.check_gc(git_dir, 101), [])
                metadata = (lock.stat().st_ino, lock.stat().st_size, lock.stat().st_mtime_ns)
                with mock.patch.object(Path, "read_bytes", side_effect=AssertionError("metadata-only witness")):
                    self.assertEqual([problem.key for problem in self.witness.check_gc(git_dir, 101 + self.witness.GC_LOCK_MAX_AGE)],
                                     ["home-config:gc-lock:" + name])
                self.assertEqual((lock.stat().st_ino, lock.stat().st_size, lock.stat().st_mtime_ns), metadata)
                lock.unlink()
                lock.symlink_to(success)
                self.assertEqual(self.witness.check_gc(git_dir, 101)[0].key, "home-config:gc-lock:" + name)

    def test_gc_problems_page_and_clear_through_the_real_alert_engine(self):
        for problem in ("gc-stale", "gc-lock:packed-refs.lock"):
            with self.subTest(problem=problem), tempfile.TemporaryDirectory() as temporary:
                git_dir = Path(temporary)
                snapshot = git_dir / "snapshot-success"
                success = git_dir / "gc-success"
                snapshot.touch()
                success.touch()
                now = 100 + self.witness.GC_MAX_AGE + 1
                os.utime(snapshot, (now, now))
                os.utime(success, (100 if problem == "gc-stale" else now,) * 2)
                lock = git_dir / "packed-refs.lock"
                if problem.startswith("gc-lock"):
                    lock.touch()
                    os.utime(lock, (100, 100))
                state = str(git_dir / "state.json")
                sent = []

                def sender(text, event_id):
                    sent.append(text)
                    return True

                with mock.patch.object(self.witness, "SUCCESS", snapshot), mock.patch.object(self.witness.time, "time", return_value=now):
                    self.assertEqual([item.key for item in self.witness.collect()], ["home-config:" + problem])
                    for observed in (now, now + 1, now + 2):
                        self.engine.run_cycle(state, observed, self.witness.collect, self.witness.render, sender)
                    self.assertEqual(len(sent), 1)
                    if lock.exists():
                        lock.unlink()
                    os.utime(success, (now, now))
                    self.engine.run_cycle(state, now + 3, self.witness.collect, self.witness.render, sender)
                self.assertEqual(len(sent), 2)
                self.assertIn("Cleared:", sent[1])

    def test_real_engine_confirms_alert_and_announces_recovery(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "success"
            state = str(Path(temporary) / "state.json")
            sent = []

            def sender(text, event_id):
                sent.append(text)
                return True

            collect = lambda: self.witness.check_freshness(path, 100)
            for now in (100, 101):
                self.engine.run_cycle(state, now, collect, self.witness.render, sender)
            self.assertEqual(len(sent), 1)
            self.assertIn("missing", sent[0])
            path.touch()
            os.utime(path, (100, 100))
            self.engine.run_cycle(state, 102, collect, self.witness.render, sender)
            self.assertEqual(len(sent), 2)
            self.assertIn("Cleared:", sent[1])


def mutation_checks():
    source = (REPO / "hosts/hsb1/home-config-snapshot.py").read_text()
    mutations = {
        "drop-redaction": ('filtered = BCRYPT.sub(PLACEHOLDER, filtered)', 'filtered = text'),
        "switch-to-blocklist": ('parts = PurePosixPath(name).parts\n    if len(parts) == 2:',
                                'return name not in {"nodered/flows_cred.json", "homeassistant/secrets.yaml"}\n    parts = PurePosixPath(name).parts\n    if len(parts) == 2:'),
        "drop-scanner": ('def scan_tree(args, tree):\n', 'def scan_tree(args, tree):\n    return\n'),
        "drop-remote-guard": ('if git(args, "remote").stdout.strip():', 'if False:'),
        "drop-hash-gate": ('for value in values:', 'for value in []:'),
        "drop-second-scan": ('scan_tree(args, exported)', 'pass'),
        "follow-selected-symlinks": ('follow_symlinks=False', 'follow_symlinks=True'),
        "enable-git-hooks": ('"-c", "core.hooksPath=/dev/null", ', ''),
        "drop-unit-guard": ('if not verify_only and not in_service_unit(gc_only):', 'if False:'),
        "drop-reference-fsync": ('core.fsync=loose-object,reference', 'core.fsync=loose-object'),
        "allow-unborn-existing-history": ('if success.exists() or success.is_symlink() or populated:', 'if False:'),
        "allow-unsafe-git-config": ('if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()\n'
                                    '                or stat.S_IMODE(info.st_mode) != 0o640):', 'if False:'),
        "restore-setgid-chmod": ('            os.replace(initializing, git_dir)',
                                '            initializing.chmod(0o2750)\n            os.replace(initializing, git_dir)'),
    }
    checks = ["SnapshotTests.test_allowlist_redaction_author_and_read_only_sources", "SnapshotTests.test_planted_secret_aborts_before_any_git_blob_or_source_write",
              "SnapshotTests.test_remote_guard_also_runs_when_sources_unchanged",
              "SnapshotTests.test_candidate_and_exact_index_export_are_both_scanned",
              "SnapshotTests.test_symlinks_and_hardlinks_fail_without_reading_their_target",
              "SnapshotTests.test_planted_index_hook_is_disabled_even_with_local_hooks_override",
              "SnapshotTests.test_full_run_outside_unit_is_refused_before_any_state_change",
              "SnapshotTests.test_every_git_operation_fsyncs_objects_and_references_despite_local_config",
              "SnapshotTests.test_group_writable_config_is_refused_before_git_for_every_mode",
              "SnapshotTests.test_unborn_head_with_objects_but_no_success_stamp_is_refused",
              "SnapshotTests.test_restrict_suid_sgid_covers_first_repeat_changed_gc_and_verify",
              "SettingsTests.test_hash_gate_detects_other_copy_and_escaped_source_spelling",
              "SettingsTests.test_hash_gate_also_decodes_differently_escaped_duplicate"]
    with tempfile.TemporaryDirectory(prefix="ops158-mutants-") as temporary:
        for name, (old, new) in mutations.items():
            if source.count(old) != 1:
                raise SystemExit("mutation did not apply exactly once: " + name)
            mutant_root = Path(temporary) / name
            mutant = mutant_root / "hosts/hsb1/home-config-snapshot.py"
            mutant.parent.mkdir(parents=True)
            mutated_source = source.replace(old, new, 1)
            compile(mutated_source, str(mutant), "exec")
            mutant.write_text(mutated_source)
            mutant_test = mutant_root / "tests/test_home_config.py"
            mutant_test.parent.mkdir()
            shutil.copyfile(__file__, mutant_test)
            shutil.copyfile(SCANNER_CONFIG, mutant.parent / SCANNER_CONFIG.name)
            result = subprocess.run([sys.executable, str(mutant_test), *checks], capture_output=True, timeout=60)
            if result.returncode == 0:
                raise SystemExit("must-fail mutant survived: " + name)
            if b"FAILED (" not in result.stderr:
                raise SystemExit("mutant failed outside the acceptance assertions: " + name)
            print("T121: must-fail mutant rejected: " + name, flush=True)


if __name__ == "__main__":
    if sys.argv[1:] == ["--mutants"]:
        mutation_checks()
    elif sys.argv[1:] == ["--seccomp-flow"]:
        if sys.platform != "linux":
            raise SystemExit("seccomp fixture requires Linux")
        fixture = SnapshotTests()
        try:
            fixture.setUp()  # Provision the setgid repository before entering the sandbox.
            install_linux_suid_sgid_filter()
            # Negative controls prove native calls, not Python mocks, are denied.
            target = fixture.root / "seccomp-control"
            target.touch()
            with target.open("rb") as handle:
                for bit in (stat.S_ISUID, stat.S_ISGID):
                    for function, arguments in ((os.chmod, (target, bit | 0o640)),
                                                (os.fchmod, (handle.fileno(), bit | 0o640)),
                                                (os.mkdir, (fixture.root / "forbidden-dir", bit | 0o750)),
                                                (os.open, (fixture.root / "forbidden-file", os.O_CREAT | os.O_WRONLY, bit | 0o640))):
                        with fixture.assertRaises(PermissionError) as raised:
                            function(*arguments)
                        fixture.assertEqual(raised.exception.errno, errno.EPERM)
            fixture.restricted_permission_flow()
            print("T121: real Git first/repeat/changed/GC/post-GC/verify passed under seccomp")
        finally:
            fixture.doCleanups()
    else:
        unittest.main(verbosity=2)
