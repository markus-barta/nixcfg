"""NIX-600: mode-B admission, the job-started hook, pf rules and the controller loop."""

import importlib.util
import grp
import io
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("aeon_builder", ROOT / "modules/aeon-builder/aeon_builder.py")
ab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ab)

REPO = "inspr-at/paimos"
SHA = "a" * 40
TEST_TMP = tempfile.TemporaryDirectory(prefix="aeon-builder-tests-")
unittest.addModuleCleanup(TEST_TMP.cleanup)

CFG = {
    "repo": REPO,
    "label": "mbp2606",
    "runnerLabels": ["self-hosted", "Linux", "ARM64", "mbp2606"],
    "classLabels": {"push": "mbp2606-push", "workflow_dispatch": "mbp2606-dispatch",
                    "pull_request": "mbp2606-pr", "merge_group": "mbp2606-mq"},
    "events": ["push", "workflow_dispatch", "pull_request", "merge_group"],
    "workflows": [".github/workflows/ci.yml", ".github/workflows/test-runner-smoke.yml"],
    "branch": "main",
    "cacheWriteEvents": ["push"],
    "slots": 4,
    "loadHigh": 12.0,
    "loadLow": 8.0,
    "claimSpacingSeconds": 180,
    "memFreeLow": 35,
    "memFreeHigh": 45,
    "memHoldSeconds": 600,
    "busyFile": str(Path(TEST_TMP.name) / "ci-pool-busy"),
    "busyFileGroup": grp.getgrgid(os.getgid()).gr_name,
    "slotCpus": 4,
    "slotMemoryGiB": 6,
    "slotDiskGiB": 60,
    "cacheDiskGiB": 60,
    "sshPortBase": 41020,
    "blockedNetworks": ["10.0.0.0/8", "192.168.0.0/16", "100.64.0.0/10", "127.0.0.0/8"],
    "requireNetworkBlock": False,
    "proofMinutes": 10,
    "ruleset": {"id": 24240960, "expected": json.loads((ROOT / "modules/aeon-builder/paimos-main-ruleset.json").read_text())},
}

LIVE_RULESET = json.loads((ROOT / "modules/aeon-builder/paimos-main-ruleset.json").read_text())

def run(**overrides):
    base = {
        "id": 101,
        "event": "push",
        "path": ".github/workflows/ci.yml",
        "head_branch": "main",
        "head_sha": SHA,
        "repository": {"full_name": REPO},
        "head_repository": {"full_name": REPO},
    }
    base.update(overrides)
    return base


class AdmissionTests(unittest.TestCase):
    def verify(self, r, on_branch=True):
        return ab.verify_run(r, CFG, lambda sha: on_branch)

    def test_main_push_and_dispatch_are_admitted(self):
        self.assertEqual(self.verify(run()), (True, "ok"))
        self.assertTrue(self.verify(run(event="workflow_dispatch", path=".github/workflows/test-runner-smoke.yml"))[0])

    def test_fork_pull_request_is_rejected_even_with_copied_labels(self):
        fork = run(event="pull_request", head_branch="main", head_repository={"full_name": "evil/paimos"})
        ok, reason = self.verify(fork)
        self.assertFalse(ok)
        self.assertIn("head repository", reason)

    def test_pr_and_merge_group_skip_branch_and_reachability_checks(self):
        for event, branch in (("pull_request", "work/x"), ("merge_group", "gh-readonly-queue/main/pr-9-test")):
            with self.subTest(event=event):
                reachability = Mock(side_effect=AssertionError("must not check reachability"))
                self.assertEqual(ab.verify_run(run(event=event, head_branch=branch), CFG, reachability), (True, "ok"))
                reachability.assert_not_called()

    def test_unconfigured_events_and_other_workflows_are_rejected(self):
        for event in ("pull_request_target", "schedule", "unknown"):
            self.assertFalse(self.verify(run(event=event))[0], event)
        self.assertFalse(self.verify(run(path=".github/workflows/release.yml"))[0])

    def test_push_and_dispatch_still_require_branch_and_reachability(self):
        for event in ("push", "workflow_dispatch"):
            with self.subTest(event=event):
                self.assertEqual(self.verify(run(event=event, head_branch="work/x")), (False, "branch work/x"))
                self.assertEqual(self.verify(run(event=event), on_branch=False), (False, "head sha not reachable from branch"))
                reachability = Mock(return_value=True)
                self.assertEqual(ab.verify_run(run(event=event), CFG, reachability), (True, "ok"))
                reachability.assert_called_once_with(SHA)

    def test_pr_and_merge_group_keep_other_admission_checks(self):
        for event in ("pull_request", "merge_group"):
            for override in ({"repository": {"full_name": "evil/paimos"}},
                             {"head_repository": {"full_name": "evil/paimos"}},
                             {"repository": None}, {"head_repository": None},
                             {"path": ".github/workflows/release.yml"}, {"path": None},
                             {"head_sha": "z" * 40}, {"head_sha": "a" * 39}, {"head_sha": None}):
                with self.subTest(event=event, override=override):
                    self.assertFalse(self.verify(run(event=event, head_branch="work/x", **override))[0])
            cfg = {**CFG, "events": ["push", "workflow_dispatch"]}
            self.assertFalse(ab.verify_run(run(event=event), cfg, lambda sha: True)[0])

    def test_missing_metadata_rejects(self):
        for key in ("repository", "head_repository", "event", "path", "head_branch", "head_sha"):
            r = run()
            r.pop(key)
            self.assertFalse(self.verify(r)[0], key)
        self.assertFalse(self.verify(run(head_repository=None))[0])

    def test_workflow_path_ref_suffix_is_ignored(self):
        self.assertTrue(self.verify(run(path=".github/workflows/ci.yml@refs/heads/main"))[0])

    def test_label_match_is_case_insensitive(self):
        self.assertTrue(ab.wants_label({"labels": ["self-hosted", "MBP2606"]}, "mbp2606"))
        self.assertFalse(ab.wants_label({"labels": ["ubuntu-latest"]}, "mbp2606"))

    def test_only_pushes_get_the_trusted_cache(self):
        self.assertTrue(ab.uses_cache_disk(run(), CFG))
        for event in ("workflow_dispatch", "pull_request", "merge_group"):
            self.assertFalse(ab.uses_cache_disk(run(event=event), CFG), event)


@unittest.skipUnless(shutil.which("nix-instantiate"), "Nix is needed to check the host policy")
class HostConfigTests(unittest.TestCase):
    def test_host_policy_and_module_labels_match_the_exercised_config(self):
        # Evaluate just the explicit host policy and module defaults offline;
        # no flake inputs, Home Manager activation, or NixOS build is needed.
        expr = '''let
          root = builtins.toPath %s;
          host = import (root + "/hosts/mbp2606/home-ci.nix") { pkgs = {}; };
          module = import (root + "/modules/aeon-builder") {
            config = {}; pkgs = {}; lib.mkOption = x: x;
          };
          options = module.options.services.aeonBuilder;
        in {
          inherit (host.services.aeonBuilder) enable events cacheWriteEvents slots slotCpus slotMemoryGiB;
          classLabels = options.classLabels.default;
          runnerLabels = options.runnerLabels.default;
          repo = options.repo.default;
          branch = options.branch.default;
          loadHigh = options.loadHigh.default;
          loadLow = options.loadLow.default;
          claimSpacingSeconds = options.claimSpacingSeconds.default;
          memFreeLow = options.memFreeLow.default;
          memFreeHigh = options.memFreeHigh.default;
          memHoldSeconds = options.memHoldSeconds.default;
          busyFile = options.busyFile.default;
          busyFileGroup = options.busyFileGroup.default;
        }''' % json.dumps(str(ROOT))
        proc = subprocess.run(["nix-instantiate", "--eval", "--strict", "--json", "--expr", expr],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        cfg = json.loads(proc.stdout)
        self.assertTrue(cfg.pop("enable"))
        expected = {key: CFG[key] for key in cfg}
        expected["busyFile"] = "/Users/Shared/ci-pool-busy"
        expected["busyFileGroup"] = "staff"
        self.assertEqual(cfg, expected)

    def test_load_options_assertion_and_json_settings(self):
        # Use the module's real defaults and JSON generation, with only the
        # Home Manager/Nixpkgs wrappers stubbed; this remains an offline eval.
        expr = '''let
          root = builtins.toPath %s;
          lib = {
            mkOption = x: x;
            mkEnableOption = _: { default = false; };
            mkPackageOption = _: _: _: { default = { outPath = "/lima"; version = "test"; }; };
            mkIf = condition: value: if condition then value else {};
            optionalAttrs = condition: value: if condition then value else {};
            types.number = "number";
            types.int = "int";
            types.ints.unsigned = { type = "int"; check = value: builtins.isInt value && value >= 0; };
            types.str = "str";
            types.bool = "bool";
            types.addCheck = type: check: { inherit type check; };
            mapAttrs = builtins.mapAttrs;
            importJSON = path: builtins.fromJSON (builtins.readFile path);
            escapeShellArg = value: value;
            hm.dag.entryBetween = before: after: data: { inherit before after data; };
            hm.dag.entryAfter = after: data: { before = []; inherit after data; };
          };
          evaluate = overrides: let
            module = import (root + "/modules/aeon-builder") {
              inherit lib;
              pkgs = {
                python3 = "/python";
                coreutils = "/coreutils";
                writeText = _: text: text;
                writeShellApplication = x: x // { outPath = "/aeon-builder"; };
              };
              config = {
                home.homeDirectory = "/test";
                services.aeonBuilder = builtins.mapAttrs (_: option: option.default)
                  module.options.services.aeonBuilder // { enable = true; } // overrides;
              };
            };
          in module;
          module = evaluate {};
          low = module.options.services.aeonBuilder.loadLow;
        in {
          assertions = map (overrides: (builtins.head (evaluate overrides).config.assertions).assertion)
            [ {} { loadHigh = 14; loadLow = 10; } { loadHigh = 8.0; } { loadHigh = 7; } ];
          memoryAssertions = map (overrides: (builtins.elemAt (evaluate overrides).config.assertions 1).assertion)
            [ {} { memFreeHigh = 50.5; memFreeLow = 40.5; } { memFreeHigh = 35; } { memFreeHigh = 34.5; } ];
          memoryTypes = map (name: module.options.services.aeonBuilder.${name}.type.type) [ "memFreeLow" "memFreeHigh" ];
          memoryBounds = map (name: map module.options.services.aeonBuilder.${name}.type.check
            [ (-1) (-0.5) 0 0.5 35 99.5 100 100.5 101 ]) [ "memFreeLow" "memFreeHigh" ];
          spacingType = module.options.services.aeonBuilder.claimSpacingSeconds.type.type;
          spacingBounds = map module.options.services.aeonBuilder.claimSpacingSeconds.type.check [ (-1) 0 180 0.5 ];
          holdType = module.options.services.aeonBuilder.memHoldSeconds.type.type;
          holdBounds = map module.options.services.aeonBuilder.memHoldSeconds.type.check [ (-1) 0 600 0.5 ];
          busyFileType = module.options.services.aeonBuilder.busyFile.type;
          busyFileGroupType = module.options.services.aeonBuilder.busyFileGroup.type;
          busyFileRefreshType = module.options.services.aeonBuilder.busyFileRefresh.type;
          busyFileRefreshDefault = module.options.services.aeonBuilder.busyFileRefresh.default;
          busyAgent = module.config.launchd.agents.aeon-builder-busy;
          builderBinary = "${builtins.head module.config.home.packages}/bin/aeon-builder";
          refreshDisabledHasAgent = ((evaluate { busyFileRefresh = false; }).config.launchd.agents or {}) ? aeon-builder-busy;
          moduleDisabledHasAgent = ((evaluate { enable = false; }).config.launchd.agents or {}) ? aeon-builder-busy;
          busyStateActivation = module.config.home.activation.aeonBuilderBusyState;
          timeMachineExcludeType = module.options.services.aeonBuilder.timeMachineExclude.type;
          timeMachineExcludeDefault = module.options.services.aeonBuilder.timeMachineExclude.default;
          timeMachineActivation = module.config.home.activation.aeonBuilderTimeMachineExclude;
          exclusionDisabledHasActivation = ((evaluate { timeMachineExclude = false; }).config.home.activation or {}) ? aeonBuilderTimeMachineExclude;
          moduleDisabledHasExclusion = ((evaluate { enable = false; }).config.home.activation or {}) ? aeonBuilderTimeMachineExclude;
          refreshDisabledHasExclusion = ((evaluate { busyFileRefresh = false; }).config.home.activation or {}) ? aeonBuilderTimeMachineExclude;
          highType = module.options.services.aeonBuilder.loadHigh.type;
          lowType = low.type.type;
          nonnegative = map low.type.check [ (-1.0) (-1) 0.0 0 8.0 8 ];
          command = (builtins.head module.config.home.packages).text;
          overrideCommand = (builtins.head (evaluate {
            claimSpacingSeconds = 240; memFreeLow = 25.5; memFreeHigh = 40.5; busyFile = "/tmp/test-busy";
            busyFileGroup = "test-group";
            memHoldSeconds = 120;
          }).config.home.packages).text;
        }''' % json.dumps(str(ROOT))
        proc = subprocess.run(["nix-instantiate", "--eval", "--strict", "--json", "--expr", expr],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = json.loads(proc.stdout)
        self.assertEqual(result["assertions"], [True, True, False, False])
        self.assertEqual(result["memoryAssertions"], [True, True, False, False])
        self.assertEqual(result["memoryTypes"], ["number", "number"])
        self.assertEqual(result["memoryBounds"], [[False, False, True, True, True, True, True, False, False]] * 2)
        self.assertEqual(result["spacingType"], "int")
        self.assertEqual(result["spacingBounds"], [False, True, True, False])
        self.assertEqual(result["holdType"], "int")
        self.assertEqual(result["holdBounds"], [False, True, True, False])
        self.assertEqual(result["busyFileType"], "str")
        self.assertEqual(result["busyFileGroupType"], "str")
        self.assertEqual(result["busyFileRefreshType"], "bool")
        self.assertTrue(result["busyFileRefreshDefault"])
        self.assertFalse(result["refreshDisabledHasAgent"])
        self.assertFalse(result["moduleDisabledHasAgent"])
        self.assertTrue(result["busyAgent"]["enable"])
        service = result["busyAgent"]["config"]
        self.assertEqual(service["StartInterval"], 60)
        self.assertTrue(service["RunAtLoad"])
        self.assertEqual(service["ProgramArguments"], [result["builderBinary"], "busy-file"])
        self.assertEqual(service["StandardOutPath"], "/test/.local/state/aeon-builder/busy-file.out")
        self.assertEqual(service["StandardErrorPath"], "/test/.local/state/aeon-builder/busy-file.err")
        activation = result["busyStateActivation"]
        self.assertEqual(activation["before"], ["setupLaunchAgents"])
        self.assertEqual(activation["after"], ["writeBoundary"])
        self.assertIn("run /coreutils/bin/mkdir -p -m 700 /test/.local/state/aeon-builder", activation["data"])
        self.assertEqual(result["timeMachineExcludeType"], "bool")
        self.assertTrue(result["timeMachineExcludeDefault"])
        self.assertFalse(result["exclusionDisabledHasActivation"])
        self.assertFalse(result["moduleDisabledHasExclusion"])
        self.assertTrue(result["refreshDisabledHasExclusion"])
        exclusion = result["timeMachineActivation"]
        self.assertEqual(exclusion["after"], ["writeBoundary"])
        self.assertIn("for dir in /test/.lima /test/.local/state/aeon-builder; do", exclusion["data"])
        self.assertIn('run /coreutils/bin/mkdir -p -m 700 "$dir"', exclusion["data"])
        self.assertIn('run /usr/bin/tmutil addexclusion "$dir"', exclusion["data"])
        self.assertIn('|| echo "aeon-builder: tmutil addexclusion failed for $dir (continuing)"', exclusion["data"])
        self.assertEqual(result["highType"], "number")
        self.assertEqual(result["lowType"], "number")
        self.assertEqual(result["nonnegative"], [False, False, True, True, True, True])
        settings = json.loads(result["command"].split("--config ", 1)[1].split(' "$@"', 1)[0])
        self.assertEqual(settings["loadHigh"], CFG["loadHigh"])
        self.assertEqual(settings["loadLow"], CFG["loadLow"])
        for key in ("claimSpacingSeconds", "memFreeLow", "memFreeHigh", "memHoldSeconds"):
            self.assertEqual(settings[key], CFG[key])
        self.assertEqual(settings["busyFile"], "/Users/Shared/ci-pool-busy")
        self.assertEqual(settings["busyFileGroup"], "staff")
        overrides = json.loads(result["overrideCommand"].split("--config ", 1)[1].split(' "$@"', 1)[0])
        self.assertEqual({key: overrides[key] for key in ("claimSpacingSeconds", "memFreeLow", "memFreeHigh", "busyFile")},
                         {"claimSpacingSeconds": 240, "memFreeLow": 25.5, "memFreeHigh": 40.5, "busyFile": "/tmp/test-busy"})
        self.assertEqual(overrides["busyFileGroup"], "test-group")
        self.assertEqual(overrides["memHoldSeconds"], 120)


class LoadGateTests(unittest.TestCase):
    def test_hysteresis_and_equal_thresholds(self):
        gated = False
        for load1, expected in ((8.0, False), (10.0, False), (12.0, False),
                                (12.1, True), (12.0, True), (10.0, True),
                                (8.0, True), (7.9, False)):
            with self.subTest(load1=load1, previous=gated):
                gated = ab.load_gate(gated, load1, 12.0, 8.0)
                self.assertEqual(gated, expected)


class MemoryGateTests(unittest.TestCase):
    def test_hysteresis_releases_at_high_and_unreadable_does_not_gate(self):
        gated = False
        for free, expected in ((35, False), (40, False), (34.9, True), (35, True),
                               (44.9, True), (45, False), (34, True), (None, False)):
            with self.subTest(free=free, previous=gated):
                gated = ab.memory_gate(gated, free, 45, 35)
                self.assertEqual(gated, expected)

    def test_memory_pressure_percentage_is_parsed(self):
        for free in (0, 34.5, 45, 100):
            proc = subprocess.CompletedProcess([], 0, f"memory details\nSystem-wide memory free percentage: {free}%\n", "")
            with patch.object(ab.subprocess, "run", return_value=proc) as command:
                self.assertEqual(ab.get_memory_free(), free)
            command.assert_called_once_with(["/usr/bin/memory_pressure", "-Q"], capture_output=True, text=True,
                                            check=True, timeout=5)

    def test_unparseable_memory_pressure_is_rejected(self):
        for text in ("", "memory details", "System-wide memory free percentage: 101%"):
            with patch.object(ab.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, text, "")):
                with self.assertRaises(ValueError):
                    ab.get_memory_free()


class RulesetTests(unittest.TestCase):
    def expected(self):
        return CFG["ruleset"]["expected"]

    def test_pinned_ruleset_covers_the_contract(self):
        pinned = self.expected()
        self.assertEqual(pinned["enforcement"], "active")
        types = {r["type"] for r in pinned["rules"]}
        self.assertLessEqual({"deletion", "non_fast_forward", "pull_request", "required_status_checks", "merge_queue"}, types)
        checks = next(r for r in pinned["rules"] if r["type"] == "required_status_checks")["parameters"]
        self.assertLessEqual({"go", "web", "release-check", "e2e", "migration-compat"},
                             {c["context"] for c in checks["required_status_checks"] if c["integration_id"] == 15368})
        self.assertFalse(checks["do_not_enforce_on_create"])
        self.assertEqual(pinned["target"], "branch")
        self.assertEqual(pinned["conditions"]["ref_name"], {"include": ["~DEFAULT_BRANCH"], "exclude": []})

    def test_pinned_bypass_actors_cannot_exceed_the_reviewed_baseline(self):
        # OPS-264: both the old pin and the supplied live ruleset retain this
        # PR-only role bypass. Exact live equality precludes an empty pin today;
        # removing it is a tightening, adding actors or widening it is not.
        actors = self.expected()["bypass_actors"]
        self.assertLessEqual(len(actors), 1)
        for actor in actors:
            self.assertEqual(actor, {"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request"})

    def test_live_equal_passes_regardless_of_list_order(self):
        live = json.loads(json.dumps(LIVE_RULESET))
        live["rules"].reverse()
        live["id"] = 24240960
        self.assertEqual(ab.ruleset_problems(live, self.expected()), [])

    def test_any_drift_is_reported(self):
        def changed(fn):
            live = json.loads(json.dumps(LIVE_RULESET))
            fn(live)
            return ab.ruleset_problems(live, self.expected())
        self.assertIn("enforcement is evaluate", changed(lambda d: d.update(enforcement="evaluate")))
        self.assertIn("rules changed", changed(lambda d: d["rules"].pop()))
        self.assertIn("bypass_actors changed", changed(lambda d: d["bypass_actors"].append(
            {"actor_id": 1, "actor_type": "Integration", "bypass_mode": "always"})))
        self.assertIn("conditions changed", changed(lambda d: d["conditions"]["ref_name"]["exclude"].append("refs/heads/main")))

        def loosen(d):
            for rule in d["rules"]:
                if rule["type"] == "required_status_checks":
                    rule["parameters"]["required_status_checks"].pop()
        self.assertIn("rules changed", changed(loosen))
        self.assertEqual(ab.ruleset_problems(None, self.expected()), ["ruleset missing"])


class LockTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)

    def test_concurrent_updates_are_not_lost(self):
        state = ab.State(self.tmp)
        state.update(lambda d: d.__setitem__("n", 0))

        def bump():
            for _ in range(50):
                state.update(lambda d: d.__setitem__("n", d["n"] + 1))
        threads = [threading.Thread(target=bump) for _ in range(4)]
        [t.start() for t in threads]
        [t.join() for t in threads]
        self.assertEqual(state.load()["n"], 200)

    def test_nested_update_is_refused_not_silently_lost(self):
        state = ab.State(self.tmp)
        with self.assertRaises(RuntimeError):
            state.update(lambda d: state.update(lambda e: e.__setitem__("inner", 1)))
        state.update(lambda d: d.__setitem__("after", 1))
        self.assertEqual(state.load()["after"], 1, "the lock is released after the refusal")

    def test_then_runs_under_the_lock(self):
        state = ab.State(self.tmp)
        seen = []
        state.update(lambda d: d.update(mode="paused"), then=lambda d: seen.append(d["mode"]))
        self.assertEqual(seen, ["paused"])

    def test_one_controller_lock(self):
        old = ab.STATE_DIR
        ab.STATE_DIR = self.tmp
        self.addCleanup(setattr, ab, "STATE_DIR", old)
        first = ab.acquire_controller_lock()
        self.assertIsNotNone(first)
        self.assertIsNone(ab.acquire_controller_lock(), "a second controller must not start")
        self.assertTrue(ab.controller_pid())
        first.close()
        self.assertIsNone(ab.controller_pid())


class AtomicWriteTests(unittest.TestCase):
    def test_private_content_and_permissions_are_ready_before_publication(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp) / "existing"
            parent.mkdir(mode=0o755)
            parent.chmod(0o755)
            path = parent / "private"
            path.write_text("old\n")
            path.chmod(0o644)
            real_replace = ab.os.replace

            def replace(src, dst):
                self.assertEqual(path.read_text(), "old\n")
                self.assertEqual(Path(src).read_text(), "private\n")
                self.assertEqual(Path(src).stat().st_mode & 0o777, 0o600)
                real_replace(src, dst)

            with patch.object(ab.os, "replace", side_effect=replace):
                ab.atomic_write(path, "private\n", mode=0o600)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(parent.stat().st_mode & 0o777, 0o755)
            created = Path(tmp) / "created" / "private"
            ab.atomic_write(created, "private\n")
            self.assertEqual(created.parent.stat().st_mode & 0o777, 0o700)

    def test_pf_install_atomically_publishes_private_files_before_launchctl(self):
        anchor = Path("/etc/pf.anchors/at.inspr.aeon-builder")
        plist = Path("/Library/LaunchDaemons/at.inspr.aeon-builder-pf.plist")
        events = []
        with patch.object(ab.os, "geteuid", return_value=0), \
                patch.object(ab, "atomic_write", side_effect=lambda *args, **kwargs: events.append((args, kwargs))), \
                patch.object(ab.subprocess, "run", side_effect=lambda *args, **kwargs:
                             (events.append((args, kwargs)), Mock(stdout="rules"))[1]), \
                patch.object(ab.time, "sleep"), patch("sys.stdout", new_callable=io.StringIO):
            ab.cmd_pf_install(CFG, Mock(user="ci"))
        self.assertEqual(events[0], ((anchor, ab.pf_rules(CFG, "ci")), {"mode": 0o600}))
        self.assertEqual(events[1][0][0], plist)
        self.assertIn("<key>RunAtLoad</key><true/>", events[1][0][1])
        self.assertIn(f"/sbin/pfctl -E; /sbin/pfctl -a com.apple/aeon-builder -f {anchor}", events[1][0][1])
        self.assertEqual(events[1][1], {"mode": 0o600})
        self.assertEqual(events[2], ((["/bin/launchctl", "bootout", "system", str(plist)],), {"capture_output": True}))
        self.assertEqual(events[3], ((["/bin/launchctl", "bootstrap", "system", str(plist)],), {"check": True}))
        self.assertEqual(events[4], ((["/sbin/pfctl", "-a", "com.apple/aeon-builder", "-sr"],),
                                     {"capture_output": True, "text": True}))


class GitHubRetryTests(unittest.TestCase):
    def setUp(self):
        # Exercise the real HTTP client without opening App credentials.
        self.gh = ab.GitHub.__new__(ab.GitHub)
        self.gh.cfg = CFG
        self.gh.etags = {}
        self.gh.sleep = Mock()
        self.gh.token = Mock(return_value="t")

    def response(self, etag=None):
        response = io.BytesIO(b'{"ok": true}')
        response.headers = {"ETag": etag} if etag else {}
        return response

    def http_error(self, code):
        return ab.urllib.error.HTTPError(ab.API + "/x", code, "test", {}, io.BytesIO(b"test failure"))

    def test_get_retries_transient_transport_errors_then_succeeds(self):
        errors = [ab.http.client.RemoteDisconnected("closed"), ab.http.client.HTTPException("bad response"),
                  ab.http.client.IncompleteRead(b"x"), ConnectionResetError("reset"), OSError("network"),
                  TimeoutError("timeout"), ab.urllib.error.URLError(ConnectionResetError("reset")),
                  ab.urllib.error.URLError(ab.http.client.RemoteDisconnected("closed")),
                  ab.urllib.error.URLError(TimeoutError("timeout")),
                  ab.urllib.error.URLError(socket.gaierror(socket.EAI_NONAME, "name lookup failed"))]
        for error in errors:
            with self.subTest(error=type(error).__name__, reason=str(error)):
                self.gh.sleep.reset_mock()
                with patch.object(ab.urllib.request, "urlopen", side_effect=[error, self.response()]) as opened:
                    self.assertEqual(self.gh._raw("GET", "/x", bearer="t"), {"ok": True})
                self.assertEqual(opened.call_count, 2)
                self.gh.sleep.assert_called_once_with(1)

    def test_get_retries_5xx_then_succeeds(self):
        for code in (500, 502, 503, 504, 599):
            with self.subTest(code=code):
                self.gh.sleep.reset_mock()
                error = self.http_error(code)
                with patch.object(ab.urllib.request, "urlopen", side_effect=[error, self.response()]) as opened:
                    self.assertEqual(self.gh._raw("GET", "/x", bearer="t"), {"ok": True})
                self.assertEqual(opened.call_count, 2)
                self.gh.sleep.assert_called_once_with(1)
                self.assertTrue(error.closed)

    def test_get_retry_budget_is_three_attempts_with_bounded_backoff(self):
        cases = [[ab.http.client.RemoteDisconnected("closed")] * 3,
                 [self.http_error(503) for _ in range(3)],
                 [ab.urllib.error.URLError(OSError("network"))] * 3]
        for errors in cases:
            error = errors[0]
            with self.subTest(error=type(error).__name__, reason=str(error)):
                self.gh.sleep.reset_mock()
                with patch.object(ab.urllib.request, "urlopen", side_effect=errors) as opened:
                    with self.assertRaisesRegex(ab.TransientGitHubError, "GET /x:"):
                        self.gh._raw("GET", "/x", bearer="t")
                self.assertEqual(opened.call_count, 3)
                self.assertEqual(self.gh.sleep.call_args_list, [unittest.mock.call(1), unittest.mock.call(2)])

    def test_get_succeeds_on_the_last_attempt(self):
        with patch.object(ab.urllib.request, "urlopen",
                          side_effect=[self.http_error(503), TimeoutError("timeout"), self.response()]) as opened:
            self.assertEqual(self.gh._raw("GET", "/x", bearer="t"), {"ok": True})
        self.assertEqual(opened.call_count, 3)
        self.assertEqual(self.gh.sleep.call_args_list, [unittest.mock.call(1), unittest.mock.call(2)])

    def test_writes_never_retry_transient_failures(self):
        for method in ("POST", "PATCH", "PUT", "DELETE"):
            for error in (self.http_error(503), self.http_error(429), self.http_error(404),
                          self.http_error(422), ConnectionResetError("reset")):
                with self.subTest(method=method, error=str(error)):
                    with patch.object(ab.urllib.request, "urlopen", side_effect=error) as opened:
                        with self.assertRaises(ab.BuilderError):
                            self.gh._raw(method, "/x", bearer="t")
                    opened.assert_called_once()
        self.gh.sleep.assert_not_called()

    def test_get_4xx_including_429_never_retry(self):
        for code in (400, 401, 403, 404, 422, 429):
            with self.subTest(code=code):
                error = self.http_error(code)
                with patch.object(ab.urllib.request, "urlopen", side_effect=error) as opened:
                    with self.assertRaises(ab.BuilderError) as raised:
                        self.gh._raw("GET", "/x", bearer="t")
                self.assertNotIsInstance(raised.exception, ab.TransientGitHubError)
                self.assertIn(f"HTTP {code}", str(raised.exception))
                opened.assert_called_once()
                self.assertTrue(error.closed)
        self.gh.sleep.assert_not_called()

    def test_non_transient_url_errors_and_invalid_json_never_retry(self):
        cases = [("string-reason URLError", ab.urllib.error.URLError("string-reason URLError")),
                 ("invalid JSON", io.BytesIO(b"invalid json"))]
        for label, result in cases:
            with self.subTest(result=label):
                with patch.object(ab.urllib.request, "urlopen", side_effect=[result]) as opened:
                    with self.assertRaises(ab.BuilderError) as raised:
                        self.gh._raw("GET", "/x", bearer="t")
                self.assertNotIsInstance(raised.exception, ab.TransientGitHubError)
                opened.assert_called_once()
        self.gh.sleep.assert_not_called()

    def test_conditional_get_keeps_etag_and_cached_304_result_across_retries(self):
        with patch.object(ab.urllib.request, "urlopen", return_value=self.response('"old"')):
            cached = self.gh.call("GET", "/x", ab.READ, cache=True)
        errors = [self.http_error(503), self.http_error(304)]
        with patch.object(ab.urllib.request, "urlopen",
                          side_effect=errors) as opened:
            self.assertIs(self.gh.call("GET", "/x", ab.READ, cache=True), cached)
        self.assertEqual(opened.call_count, 2)
        for request in opened.call_args_list:
            self.assertEqual(request.args[0].get_header("If-none-match"), '"old"')
        self.assertEqual(self.gh.etags, {"/x": ('"old"', cached)})
        self.gh.sleep.assert_called_once_with(1)
        self.assertTrue(all(error.closed for error in errors))

    def test_http_error_is_closed_even_when_reading_its_detail_fails(self):
        error = self.http_error(400)
        with patch.object(error, "read", side_effect=OSError("body read failed")), \
                patch.object(ab.urllib.request, "urlopen", side_effect=error):
            with self.assertRaisesRegex(ab.BuilderError, "HTTP 400"):
                self.gh._raw("GET", "/x", bearer="t")
        self.assertTrue(error.closed)
        self.gh.sleep.assert_not_called()

    def test_uncached_304_is_closed_and_remains_fatal(self):
        error = self.http_error(304)
        with patch.object(ab.urllib.request, "urlopen", side_effect=error) as opened:
            with self.assertRaises(ab.BuilderError) as raised:
                self.gh._raw("GET", "/x", bearer="t", etag_key="/x")
        self.assertNotIsInstance(raised.exception, ab.TransientGitHubError)
        self.assertTrue(error.closed)
        opened.assert_called_once()
        self.gh.sleep.assert_not_called()

    def test_token_mint_remains_single_shot_when_a_get_needs_a_token(self):
        del self.gh.token  # use the real permission-scoped token mint
        self.gh.tokens = {}
        self.gh.lock = threading.Lock()
        self.gh.installation_id = "1"
        self.gh._jwt = Mock(return_value="t")
        with patch.object(ab.urllib.request, "urlopen", side_effect=self.http_error(503)) as opened:
            with self.assertRaises(ab.TransientGitHubError):
                self.gh.call("GET", "/x", ab.READ)
        opened.assert_called_once()
        self.assertEqual(opened.call_args.args[0].method, "POST")
        self.assertTrue(opened.call_args.args[0].full_url.endswith("/app/installations/1/access_tokens"))
        self.gh.sleep.assert_not_called()

    def test_job_and_run_reads_use_the_client_retry(self):
        for read in (self.gh.job, self.gh.run):
            with self.subTest(read=read.__name__):
                self.gh.sleep.reset_mock()
                with patch.object(ab.urllib.request, "urlopen",
                                  side_effect=[ab.http.client.RemoteDisconnected("closed"), self.response()]) as opened:
                    self.assertEqual(read(9), {"ok": True})
                self.assertEqual(opened.call_count, 2)
                self.gh.sleep.assert_called_once_with(1)


class PagingTests(unittest.TestCase):
    def test_paged_follows_full_pages_and_refuses_partial_lists(self):
        gh = ab.GitHub.__new__(ab.GitHub)
        pages = {1: list(range(100)), 2: list(range(100, 150))}
        gh.call = lambda method, path, perms, cache=False: {"jobs": pages.get(int(path.rsplit("page=", 1)[1]), [])}
        self.assertEqual(len(gh.paged("/x?filter=all", "jobs", {})), 150)
        gh.call = lambda method, path, perms, cache=False: {"jobs": list(range(100))}
        with self.assertRaises(ab.BuilderError):
            gh.paged("/x", "jobs", {})

    def test_active_statuses_cover_every_waiting_state(self):
        self.assertEqual(set(ab.ACTIVE_STATUSES), {"queued", "in_progress", "waiting", "pending", "requested"})


class BaseProvisionTests(unittest.TestCase):
    units = ("unattended-upgrades.service", "apt-daily.timer", "apt-daily-upgrade.timer",
             "apt-daily.service", "apt-daily-upgrade.service")

    def provision_commands(self, units=None, package_status="installed", fail=""):
        # Execute only the package setup with shell functions replacing every
        # external command. Never run runner setup or touch the host's services.
        script = (ROOT / "modules/aeon-builder/provision-base.sh").read_text()
        setup, separator, _ = script.partition("# Runner user:")
        self.assertTrue(separator, "package setup boundary missing")
        stubs = """
exec 3>&1
record() { printf '%s' "$1" >&3; shift; printf '\\t%s' "$@" >&3; printf '\\n' >&3; }
systemctl() {
  record systemctl "$@"
  if [[ "$TEST_FAIL" == "systemctl $1" ]]; then return 5; fi
  if [[ "$1" == list-unit-files ]]; then
    case " $TEST_UNITS " in
      *" $4 "*) printf '%s enabled\\n' "$4" ;;
    esac
  fi
  return 0
}
dpkg-query() {
  record dpkg-query "$@"
  if [[ "$TEST_FAIL" == dpkg-query ]]; then return 2; fi
  if [[ "$TEST_PACKAGE_STATUS" == absent ]]; then return 1; fi
  printf '%s' "$TEST_PACKAGE_STATUS"
}
apt-get() {
  record apt-get "$@"
  if [[ " $* " == *" $TEST_FAIL "* ]]; then return 100; fi
  return 0
}
"""
        test_env = {**os.environ, "TEST_UNITS": " ".join(self.units if units is None else units),
                    "TEST_PACKAGE_STATUS": package_status, "TEST_FAIL": fail}
        proc = subprocess.run(["bash", "-c", stubs + setup, "provision-test", "test-version", "test-sha"],
                              capture_output=True, text=True, env=test_env)
        return proc, [line.split("\t") for line in proc.stdout.splitlines()]

    def operations(self, commands):
        return [cmd for cmd in commands if cmd[0] != "dpkg-query" and cmd[1] != "list-unit-files"]

    def test_base_stops_and_masks_automatic_apt_before_installing_ci_shells(self):
        proc, commands = self.provision_commands()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        operations = self.operations(commands)
        expected = [["systemctl", "disable", "--now", unit] for unit in self.units[:3]]
        expected += [["systemctl", "stop", unit] for unit in self.units[3:]]
        expected += [["apt-get", "-o", "DPkg::Lock::Timeout=300", "purge", "-y", "-q", "unattended-upgrades"],
                     ["systemctl", "mask", *self.units], ["apt-get", "update", "-q"]]
        self.assertEqual(operations[:-1], expected)
        self.assertEqual(operations[-1][:3], ["apt-get", "install", "-y"])
        self.assertTrue({"fish", "zsh"} <= set(operations[-1]))

    def test_missing_package_and_units_still_mask_and_install(self):
        for package_status in ("absent", "config-files", "not-installed"):
            with self.subTest(package_status=package_status):
                proc, commands = self.provision_commands(units=(), package_status=package_status)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                operations = self.operations(commands)
                self.assertEqual(operations[:-1], [["systemctl", "mask", *self.units],
                                                  ["apt-get", "update", "-q"]])
                self.assertEqual(operations[-1][:3], ["apt-get", "install", "-y"])
                self.assertTrue({"fish", "zsh"} <= set(operations[-1]))

    def test_cleanup_only_targets_present_units(self):
        present = ("apt-daily.timer", "apt-daily-upgrade.service")
        proc, commands = self.provision_commands(units=present, package_status="absent")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        operations = self.operations(commands)
        self.assertEqual(operations[:3], [["systemctl", "disable", "--now", present[0]],
                                         ["systemctl", "stop", present[1]],
                                         ["systemctl", "mask", *self.units]])

    def test_real_errors_abort_provisioning(self):
        for failure, failed_command, status in (("systemctl list-unit-files", ["systemctl", "list-unit-files"], 5),
                                                ("systemctl disable", ["systemctl", "disable"], 5),
                                                ("systemctl stop", ["systemctl", "stop"], 5),
                                                ("dpkg-query", ["dpkg-query"], 2),
                                                ("purge", ["apt-get", "-o"], 100),
                                                ("systemctl mask", ["systemctl", "mask"], 5),
                                                ("update", ["apt-get", "update"], 100),
                                                ("install", ["apt-get", "install"], 100)):
            with self.subTest(failure=failure):
                proc, commands = self.provision_commands(fail=failure)
                self.assertEqual(proc.returncode, status, proc.stderr)
                self.assertEqual(commands[-1][:len(failed_command)], failed_command,
                                 "must stop at the failing command")


class RenderTests(unittest.TestCase):
    def test_availability_record_matches_schema_2(self):
        import datetime as dt
        now = dt.datetime(2026, 9, 30, 10, 0, tzinfo=dt.timezone.utc)
        rec = ab.availability_record(CFG, 3, now)
        self.assertEqual(rec, {"schema": 2, "repository": REPO, "os": "linux", "arch": "arm64", "online": True,
                               "busy": False, "observed_at": "2026-09-30T10:00:00Z", "idle_runners": 3,
                               "events": ["merge_group", "pull_request", "push", "workflow_dispatch"]})
        self.assertTrue(ab.availability_record(CFG, 0, now)["busy"])
        self.assertEqual(ab.availability_record(CFG, -1, now)["idle_runners"], 0)

    def test_availability_record_advertises_only_configured_events(self):
        for events, expected in ((["push"], ["push"]),
                                 (["workflow_dispatch", "push"], ["push", "workflow_dispatch"]),
                                 ([], [])):
            with self.subTest(events=events):
                cfg = {**CFG, "events": events.copy()}
                self.assertEqual(ab.availability_record(cfg, 3)["events"], expected)
                self.assertEqual(cfg["events"], events)

    def test_base_has_no_mounts_and_no_port_forwards(self):
        expr = ab.base_expression(CFG)
        self.assertIn(".mounts = []", expr)
        self.assertIn('"ignore": true', expr)
        self.assertIn(".ssh.localPort = 41019", expr)

    def test_clone_uses_slot_port_and_disk(self):
        expr = ab.clone_expression(CFG, 2, "aeon-cache-2")
        self.assertIn(".ssh.localPort = 41022", expr)
        self.assertIn('"name": "aeon-cache-2"', expr)
        self.assertIn(".additionalDisks = []", ab.clone_expression(CFG, 0, None))
        self.assertIn(".cpus = 4", expr)
        self.assertIn('.memory = "6GiB"', expr)

    def test_pf_rules_block_private_ranges_for_ci_only(self):
        rules = ab.pf_rules(CFG, "ci")
        self.assertIn("block return out quick from any to <aeon_private> user ci", rules)
        self.assertIn("to 127.0.0.1 port 41019:41023 user ci no state", rules)
        self.assertIn("from 127.0.0.1 port 41019:41023 to 127.0.0.1 user ci no state", rules)
        self.assertIn("100.64.0.0/10", rules)
        self.assertLess(rules.index("pass out quick on lo0"), rules.index("block return"))
        self.assertNotIn("port 53", rules, "no DNS exception for ci (AEON-438 ruling)")

    @unittest.skipUnless(shutil.which("pfctl"), "pfctl not available")
    def test_pf_rules_parse(self):
        with tempfile.NamedTemporaryFile("w", suffix=".conf") as handle:
            handle.write(ab.pf_rules(CFG, "nobody"))
            handle.flush()
            proc = subprocess.run(["pfctl", "-n", "-f", handle.name], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_allowlist_pins_workflow_refs(self):
        doc = ab.allowlist_document(CFG)
        self.assertEqual(doc["ref"], "refs/heads/main")
        self.assertIn("inspr-at/paimos/.github/workflows/ci.yml@refs/heads/main", doc["workflowRefs"])

    def test_hook_log_parsing(self):
        allows, denies = ab.parse_hook_log("aeon-hook allow run=7 attempt=1 job=go event=push sha=x\naeon-hook deny run=8 reason=event\n")
        self.assertEqual(allows[0]["run"], "7")
        self.assertEqual(len(denies), 1)


@unittest.skipUnless(shutil.which("jq") and shutil.which("bash"), "hook needs bash and jq")
class HookTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        (self.tmp / "allow.json").write_text(json.dumps(ab.allowlist_document(CFG)))
        self.log = self.tmp / "hook.log"
        self.log.write_text("")

    def hook(self, payload=None, **env):
        event = self.tmp / "event.json"
        event.write_text(json.dumps(payload if payload is not None else {"repository": {"full_name": REPO}}))
        base = {
            "PATH": os.environ["PATH"],
            "AEON_ALLOWLIST": str(self.tmp / "allow.json"),
            "AEON_STATE_DIR": str(self.tmp),
            "AEON_TEST_DENY": "1",
            "AEON_CACHE_WAIT": "2",
            "GITHUB_REPOSITORY": REPO,
            "GITHUB_EVENT_NAME": "push",
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_WORKFLOW_REF": f"{REPO}/.github/workflows/ci.yml@refs/heads/main",
            "GITHUB_EVENT_PATH": str(event),
            "GITHUB_SHA": SHA,
            "GITHUB_RUN_ID": "42",
            "GITHUB_JOB": "go",
        }
        base.update(env)
        return subprocess.run(["bash", str(ROOT / "modules/aeon-builder/job-started.sh")], env=base, capture_output=True, text=True)

    def test_allowed_job_waits_for_the_controller_then_passes(self):
        (self.tmp / "cache-ready").write_text("")
        proc = self.hook()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("aeon-hook allow run=42", self.log.read_text())
        self.assertIn("run=42", (self.tmp / "admitted").read_text())

    def test_pr_and_merge_queue_refs_are_admitted(self):
        (self.tmp / "cache-ready").write_text("")
        for event, ref in (("pull_request", "refs/pull/9/merge"),
                           ("merge_group", "refs/heads/gh-readonly-queue/main/pr-9-test")):
            with self.subTest(event=event):
                payload = {"repository": {"full_name": REPO}}
                if event == "pull_request":
                    payload["pull_request"] = {"head": {"repo": {"full_name": REPO}}}
                proc = self.hook(payload=payload, GITHUB_EVENT_NAME=event, GITHUB_REF=ref,
                                 GITHUB_WORKFLOW_REF=f"{REPO}/.github/workflows/ci.yml@{ref}")
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertIn(f"event={event}", (self.tmp / "admitted").read_text())

    def test_pr_and_merge_queue_keep_workflow_and_payload_checks(self):
        (self.tmp / "cache-ready").write_text("")
        for event in ("pull_request", "merge_group"):
            for override in (
                {"GITHUB_WORKFLOW_REF": f"{REPO}/.github/workflows/release.yml@refs/pull/9/merge"},
                {"GITHUB_WORKFLOW_REF": "evil/paimos/.github/workflows/ci.yml@refs/pull/9/merge"},
                {"GITHUB_WORKFLOW_REF": f"{REPO}/.github/workflows/ci.yml"},
                {"GITHUB_REPOSITORY": "evil/paimos"}, {"GITHUB_SHA": "not-a-sha"},
                {"payload": {"repository": {"full_name": "evil/paimos"}}},
            ):
                with self.subTest(event=event, override=override):
                    args = {"GITHUB_EVENT_NAME": event, "payload": {"repository": {"full_name": REPO}}}
                    if event == "pull_request":
                        args["payload"]["pull_request"] = {"head": {"repo": {"full_name": REPO}}}
                    proc = self.hook(**(args | override))
                    self.assertEqual(proc.returncode, 97, proc.stderr)

    def test_fork_pr_payload_is_rejected_even_when_cache_is_ready(self):
        (self.tmp / "cache-ready").write_text("")
        for head in ({"repo": {"full_name": "evil/paimos"}}, {"repo": None}, {}):
            payload = {"repository": {"full_name": REPO}, "pull_request": {"head": head}}
            proc = self.hook(payload=payload, GITHUB_EVENT_NAME="pull_request", GITHUB_REF="refs/pull/9/merge",
                             GITHUB_WORKFLOW_REF=f"{REPO}/.github/workflows/ci.yml@refs/pull/9/merge")
            self.assertEqual(proc.returncode, 97, proc.stderr)

    def test_dispatch_still_requires_main_refs(self):
        (self.tmp / "cache-ready").write_text("")
        self.assertEqual(self.hook(GITHUB_EVENT_NAME="workflow_dispatch").returncode, 0)
        for override in ({"GITHUB_REF": "refs/heads/work/x"},
                         {"GITHUB_WORKFLOW_REF": f"{REPO}/.github/workflows/ci.yml@refs/heads/work/x"}):
            self.assertEqual(self.hook(GITHUB_EVENT_NAME="workflow_dispatch", **override).returncode, 97)

    def test_pr_still_waits_for_controller_confirmation(self):
        payload = {"repository": {"full_name": REPO}, "pull_request": {"head": {"repo": {"full_name": REPO}}}}
        proc = self.hook(payload=payload, GITHUB_EVENT_NAME="pull_request", GITHUB_REF="refs/pull/9/merge",
                         GITHUB_WORKFLOW_REF=f"{REPO}/.github/workflows/ci.yml@refs/pull/9/merge")
        self.assertEqual(proc.returncode, 97)
        self.assertIn("did not confirm admission", self.log.read_text())

    def test_admitted_job_without_controller_confirmation_is_killed(self):
        proc = self.hook()
        self.assertEqual(proc.returncode, 97, "deny path (kill + poweroff in the VM)")
        self.assertIn("did not confirm admission", self.log.read_text())

    def test_deny_path_kills_and_powers_off_before_returning(self):
        text = (ROOT / "modules/aeon-builder/job-started.sh").read_text()
        deny = text[text.index("deny() {"):text.index("\n}\n", text.index("deny() {"))]
        self.assertLess(deny.index("pkill -STOP"), deny.index("poweroff -ff"), "freeze, never kill, before poweroff")
        self.assertNotIn("pkill -9", deny)
        self.assertLess(deny.index("poweroff -ff"), deny.index("sleep infinity"))
        self.assertLess(deny.index(">>\"$LOG\""), deny.index("pkill"), "the deny is logged first")

    def test_crafted_jobs_fail_closed(self):
        cases = [
            dict(GITHUB_REPOSITORY="evil/paimos"),
            dict(GITHUB_EVENT_NAME="pull_request"),
            dict(GITHUB_REF="refs/pull/9/merge"),
            dict(GITHUB_WORKFLOW_REF="evil/paimos/.github/workflows/ci.yml@refs/heads/main"),
            dict(GITHUB_WORKFLOW_REF=f"{REPO}/.github/workflows/ci.yml@refs/heads/work/x"),
            dict(GITHUB_WORKFLOW_REF=f"{REPO}/.github/workflows/release.yml@refs/heads/main"),
            dict(GITHUB_SHA="not-a-sha"),
            dict(GITHUB_EVENT_PATH="/nonexistent"),
            dict(GITHUB_REPOSITORY=""),
        ]
        for env in cases:
            with self.subTest(env=env):
                self.assertEqual(self.hook(**env).returncode, 97)
        self.assertNotEqual(self.hook(payload={"repository": {"full_name": REPO}, "pull_request": {"number": 9}}).returncode, 0)
        self.assertNotEqual(self.hook(payload={"repository": {"full_name": "evil/paimos"}}).returncode, 0)
        self.assertNotIn("allow", self.log.read_text())

    def test_missing_allowlist_fails_closed(self):
        self.assertNotEqual(self.hook(AEON_ALLOWLIST=str(self.tmp / "missing.json")).returncode, 0)


class FakeGitHub:
    def __init__(self, runs, jobs):
        self._runs = runs
        self._jobs = jobs
        self.cancelled = []
        self.published = []

    def runs(self, status):
        return [r for r in self._runs if r.get("status", "queued") == status]

    def jobs(self, run_id):
        return self._jobs.get(run_id, [])

    def active_runs(self):
        return [r for r in self._runs if r.get("status", "queued") in ab.ACTIVE_STATUSES]

    def all_jobs(self, run_id):
        return self._jobs.get(run_id, [])

    def job(self, job_id):
        return next(j for jobs in self._jobs.values() for j in jobs if j["id"] == job_id)

    def recent_runs(self):
        return self._runs

    def run(self, run_id):
        return next(r for r in self._runs if r["id"] == run_id)

    def runners(self):
        return []

    def sha_on_branch(self, sha):
        return True

    def cancel(self, run_id):
        self.cancelled.append(run_id)

    def ruleset(self):
        return LIVE_RULESET

    def publish(self, record):
        self.published.append(record)

    def clear(self):
        self.published.append(None)


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.state = ab.State(self.tmp)
        self.state.update(lambda d: d.update(mode="on"))
        self.cfg = {**CFG, "busyFile": str(self.tmp / "ci-pool-busy")}
        self.clock = Mock(return_value=1000)
        clock = patch.object(ab.time, "time", self.clock)
        clock.start()
        self.addCleanup(clock.stop)
        self._log = ab.log
        ab.log = lambda message: None
        self.addCleanup(setattr, ab, "log", self._log)
        errors = patch.object(ab, "_busy_file_errors", {})
        errors.start()
        self.addCleanup(errors.stop)
        state_dir = patch.object(ab, "STATE_DIR", self.tmp)
        state_dir.start()
        self.addCleanup(state_dir.stop)

    def controller(self, gh, getloadavg=None, getmemoryfree=None):
        ctl = ab.Controller(self.cfg, gh=gh, lima=object(), state=self.state,
                            getloadavg=getloadavg or (lambda: (0.0, 0.0, 0.0)),
                            getmemoryfree=getmemoryfree or (lambda: 60.0))
        self.served = []
        gate = threading.Event()

        def serve(slot, r, job):
            self.served.append((slot, r["id"], job["id"]))
            gate.wait(2)
        ctl.serve = serve
        self.addCleanup(gate.set)
        return ctl

    def test_load_gate_leaves_jobs_queued_and_claims_after_release(self):
        r = run(id=9)
        job = {"id": 90, "status": "queued", "labels": ab.mint_labels(CFG, r)}
        gh = FakeGitHub([r], {9: [job]})
        getloadavg = Mock(side_effect=[(13.0, 0, 0), (10.0, 0, 0), (8.0, 0, 0), (7.0, 0, 0)])
        ctl = self.controller(gh, getloadavg)
        with patch.object(ctl, "claim_slot", wraps=ctl.claim_slot) as claim:
            for _ in range(3):
                self.assertEqual(ctl.tick(), "on")
                self.assertTrue(ctl.load_gated)
                self.assertEqual(self.state.load()["slots"], {})
                self.assertEqual(ctl.pending, 1)
                self.assertEqual(gh.cancelled, [])
                self.assertEqual(job["status"], "queued")
            self.assertEqual(claim.call_count, 3)
            claim.assert_called_with(job, r)
            self.assertEqual(ctl.workers, {})
            claim.reset_mock()
            ctl.tick()
            claim.assert_called_once_with(job, r)
        self.assertFalse(ctl.load_gated)
        self.assertEqual(self.state.load()["slots"]["0"]["jobId"], 90)
        self.assertEqual(getloadavg.call_count, 4)

    def test_gated_empty_pool_finishes_draining(self):
        ctl = self.controller(FakeGitHub([], {}), lambda: (13.0, 0, 0))
        self.state.update(lambda d: d.update(mode="draining"))
        ctl.pending = 3
        self.assertEqual(ctl.tick(), "off")
        self.assertTrue(ctl.load_gated)
        self.assertEqual(self.state.load()["mode"], "off")
        self.assertEqual(ctl.pending, 0)

    def test_paused_and_stopping_modes_still_reap_while_gated(self):
        for mode in ("paused", "stopping"):
            with self.subTest(mode=mode):
                gh = FakeGitHub([], {})
                gh.active_runs = Mock(side_effect=AssertionError("must not poll jobs"))
                ctl = self.controller(gh, lambda: (13.0, 0, 0))
                finished = Mock()
                finished.is_alive.return_value = False
                ctl.workers[1] = finished
                self.state.update(lambda d: d.update(mode=mode))
                with patch.object(ctl, "maybe_prove") as prove:
                    self.assertEqual(ctl.tick(), mode)
                prove.assert_not_called()
                self.assertTrue(ctl.load_gated)
                self.assertEqual(self.state.load()["mode"], mode)
                self.assertEqual(ctl.workers, {})
                self.assertFalse(ctl.publish_once())
                self.assertEqual(gh.published, [])

    def test_gated_tick_sweeps_prunes_and_skips_proof(self):
        ctl = self.controller(FakeGitHub([], {}), lambda: (13.0, 0, 0))
        ctl.pending = 3
        self.state.update(lambda d: d.update(verifiedRuns=list(range(501)), cancelledRuns=list(range(501))))
        with patch.object(ctl, "maybe_prove") as prove, patch.object(ctl, "sweep_stale_runners") as sweep:
            self.assertEqual(ctl.tick(), "on")
        self.assertTrue(ctl.load_gated)
        prove.assert_not_called()
        sweep.assert_called_once_with()
        self.assertEqual(ctl.pending, 0)
        for key in ("verifiedRuns", "cancelledRuns"):
            self.assertEqual(self.state.load()[key], list(range(201, 501)))

    def test_ruleset_drift_pauses_and_cancels_while_gated(self):
        r = run(id=9)
        job = {"id": 90, "status": "queued", "labels": ab.mint_labels(CFG, r)}
        gh = FakeGitHub([r], {9: [job]})
        gh.ruleset = lambda: dict(LIVE_RULESET, enforcement="evaluate")
        ctl = self.controller(gh, lambda: (13.0, 0, 0))
        self.assertEqual(ctl.tick(), "paused")
        self.assertTrue(ctl.load_gated)
        self.assertEqual(self.state.load()["slots"], {})
        self.assertEqual(ctl.workers, {})
        self.assertEqual(gh.cancelled, [9])
        self.assertEqual(gh.published, [None])

    def test_load_at_or_above_low_claims_one_slot_per_tick(self):
        for load1 in (8.0, 10.0, 12.0):
            with self.subTest(load1=load1):
                self.state.update(lambda d: (d.update(slots={}), d.pop("lastClaimAt", None)))
                r = run(id=9)
                jobs = [{"id": 90 + i, "status": "queued", "labels": ab.mint_labels(CFG, r)} for i in range(4)]
                ctl = self.controller(FakeGitHub([r], {9: jobs}), lambda: (load1, 0, 0))
                for count in range(1, 5):
                    self.clock.return_value = 1000 + (count - 1) * 180
                    self.assertEqual(ctl.tick(), "on")
                    self.assertFalse(ctl.load_gated)
                    self.assertEqual(len(self.state.load()["slots"]), count)
                    self.assertEqual(ctl.pending, 4 - count)

    def test_load_below_low_claims_at_most_one_slot_per_tick(self):
        self.cfg["claimSpacingSeconds"] = 0  # prove the per-tick limit independently of spacing
        r = run(id=9)
        jobs = [{"id": 90 + i, "status": "queued", "labels": ab.mint_labels(CFG, r)} for i in range(4)]
        ctl = self.controller(FakeGitHub([r], {9: jobs}), lambda: (7.9, 0, 0))
        ctl.tick()
        self.assertFalse(ctl.load_gated)
        self.assertEqual(len(self.state.load()["slots"]), 1)
        self.assertEqual(ctl.pending, 3)
        ctl.tick()
        self.assertEqual(len(self.state.load()["slots"]), 2)

    def test_claim_spacing_keeps_jobs_queued_until_exactly_180_seconds(self):
        r = run(id=9)
        jobs = [{"id": 90 + i, "status": "queued", "labels": ab.mint_labels(CFG, r)} for i in range(2)]
        gh = FakeGitHub([r], {9: jobs})
        ctl = self.controller(gh)
        ctl.tick()
        self.assertEqual(self.state.load()["lastClaimAt"], 1000)
        for now in (1000, 1179.9):
            self.clock.return_value = now
            ctl.tick()
            self.assertEqual(len(self.state.load()["slots"]), 1)
            self.assertEqual(self.state.load()["lastClaimAt"], 1000)
            self.assertEqual(ctl.pending, 1)
        self.assertTrue(ctl.publish_once())
        self.assertEqual(gh.published[-1]["idle_runners"], 2, "spacing does not mask normal free-slot publishing")
        self.assertFalse(gh.published[-1]["busy"])
        self.clock.return_value = 1180
        ctl.tick()
        self.assertEqual(len(self.state.load()["slots"]), 2)
        self.assertEqual(self.state.load()["lastClaimAt"], 1180)
        self.assertEqual(gh.cancelled, [])
        self.assertEqual([j["status"] for j in jobs], ["queued", "queued"])

    def test_claim_spacing_survives_restart_even_after_slot_release(self):
        r = run(id=9)
        job = {"id": 90, "status": "queued", "labels": ab.mint_labels(CFG, r)}
        gh = FakeGitHub([r], {9: [job]})
        ctl = self.controller(gh)
        self.assertEqual(ctl.claim_slot(job, r), 0)
        ctl.release_slot(0)
        self.state = ab.State(self.tmp)
        restarted = self.controller(gh)
        self.clock.return_value = 1179
        self.assertIsNone(restarted.claim_slot(job, r))
        self.clock.return_value = 1180
        self.assertEqual(restarted.claim_slot(job, r), 0)

    def test_blocked_queue_makes_at_most_one_claim_and_ruleset_fetch_per_tick(self):
        r = run(id=9)
        jobs = [{"id": 90 + i, "status": "queued", "labels": ab.mint_labels(CFG, r)} for i in range(10)]
        occupied = {str(i): {"jobId": i} for i in range(self.cfg["slots"])}
        for blocked in ("spacing", "load", "memory", "full"):
            with self.subTest(blocked=blocked):
                self.state.save({"mode": "on", "slots": occupied if blocked == "full" else {},
                                 "lastClaimAt": 999 if blocked == "spacing" else None})
                gh = FakeGitHub([r], {9: jobs})
                gh.ruleset = Mock(return_value=LIVE_RULESET)
                ctl = self.controller(gh, lambda: (13 if blocked == "load" else 0, 0, 0),
                                      lambda: 34 if blocked == "memory" else 60)
                with patch.object(ctl, "claim_slot", wraps=ctl.claim_slot) as claim:
                    for _ in range(2):
                        gh.ruleset.reset_mock()
                        claim.reset_mock()
                        self.assertEqual(ctl.tick(), "on")
                        claim.assert_called_once_with(jobs[0], r)
                        gh.ruleset.assert_called_once_with()
                        self.assertEqual(ctl.pending, len(jobs))
                        self.assertEqual(self.state.load()["slots"], occupied if blocked == "full" else {})
                        self.assertEqual(ctl.workers, {})
                        self.assertEqual(gh.cancelled, [])
                        self.assertTrue(all(job["status"] == "queued" for job in jobs))

    def test_concurrent_claims_share_the_persisted_spacing_limit(self):
        r = run(id=9)
        gh = FakeGitHub([], {})
        controllers = [self.controller(gh), self.controller(gh)]
        claimed = []
        threads = [threading.Thread(target=lambda ctl=ctl, i=i: claimed.append(ctl.claim_slot({"id": i}, r)))
                   for i, ctl in enumerate(controllers)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertCountEqual(claimed, [0, None])
        self.assertEqual(len(self.state.load()["slots"]), 1)

    def test_claim_spacing_allows_a_backwards_clock_jump_then_restarts_spacing(self):
        r = run(id=9)
        ctl = self.controller(FakeGitHub([], {}))
        self.assertEqual(ctl.claim_slot({"id": 90}, r), 0)
        self.clock.return_value = 900
        self.assertEqual(ctl.claim_slot({"id": 91}, r), 1)
        self.assertEqual(self.state.load()["lastClaimAt"], 900)
        self.assertIsNone(ctl.claim_slot({"id": 92}, r))
        self.clock.return_value = 1079.9
        self.assertIsNone(ctl.claim_slot({"id": 92}, r))
        self.clock.return_value = 1080
        self.assertEqual(ctl.claim_slot({"id": 92}, r), 2)

    def test_memory_gate_keeps_jobs_queued_and_running_work_untouched(self):
        r = run(id=9)
        job = {"id": 90, "status": "queued", "labels": ab.mint_labels(CFG, r)}
        gh = FakeGitHub([r], {9: [job]})
        ctl = self.controller(gh, getmemoryfree=Mock(side_effect=[34, 35, 44.9, 45]))
        slot = {"jobId": 1, "phase": "running", "vm": "aeon-job-0"}
        worker = Mock()
        worker.is_alive.return_value = True
        ctl.workers[1] = worker
        self.state.update(lambda d: d["slots"].update({"0": slot}))
        with patch.object(ctl, "maybe_prove") as prove:
            for _ in range(3):
                self.assertEqual(ctl.tick(), "on")
                self.assertTrue(ctl.mem_gated)
                self.assertTrue(ctl.host_gated)
                self.assertEqual(self.state.load()["slots"], {"0": slot})
                self.assertEqual(ctl.workers, {1: worker})
                self.assertEqual(ctl.pending, 1)
                self.assertEqual(gh.cancelled, [])
                self.assertEqual(job["status"], "queued")
            prove.assert_not_called()
            ctl.tick()
        self.assertFalse(ctl.host_gated)
        self.assertEqual(self.state.load()["slots"]["1"]["jobId"], 90)
        worker.join.assert_not_called()

    def test_publish_memory_gate_reports_busy_until_high_threshold(self):
        gh = FakeGitHub([], {})
        ctl = self.controller(gh, getmemoryfree=Mock(side_effect=[34, 40, 45]))
        for expected_idle in (0, 0, 4):
            self.assertTrue(ctl.publish_once())
            self.assertEqual(gh.published[-1]["idle_runners"], expected_idle)
            self.assertEqual(gh.published[-1]["busy"], expected_idle == 0)
        self.assertEqual(gh.cancelled, [])

    def test_host_gate_tracks_both_reasons_and_logs_each_transition_once(self):
        gh = FakeGitHub([], {})
        ctl = self.controller(gh, Mock(side_effect=[(13, 0, 0), (13, 0, 0), (7, 0, 0), (7, 0, 0)]),
                              Mock(side_effect=[34, 40, 40, 45]))
        with patch.object(ab, "log") as log:
            for reason in ("load+memory", "load+memory", "memory", ""):
                ctl.publish_once()
                self.assertEqual(self.state.load()["hostGateReason"], reason)
                self.assertEqual(self.state.load()["hostGated"], bool(reason))
        self.assertEqual(log.call_count, 3)
        self.assertIn("ON (load+memory)", log.call_args_list[0].args[0])
        self.assertIn("ON (memory)", log.call_args_list[1].args[0])
        self.assertIn("OFF", log.call_args_list[2].args[0])

    def test_unreadable_memory_pressure_does_not_gate_and_logs_once(self):
        for error in (FileNotFoundError("missing"), subprocess.CalledProcessError(1, "memory_pressure"),
                      subprocess.TimeoutExpired("memory_pressure", 5), ValueError("missing percentage")):
            with self.subTest(error=type(error).__name__):
                self.state.update(lambda d: d.update(memGated=True, hostGated=True, hostGateReason="memory",
                                                     memSampled=False, memUnreadableSince=None))
                gh = FakeGitHub([], {})
                ctl = self.controller(gh, getmemoryfree=Mock(side_effect=error))
                with patch.object(ab, "log") as log:
                    for _ in range(2):
                        self.assertTrue(ctl.publish_once())
                        self.assertFalse(ctl.mem_gated)
                        self.assertFalse(ctl.host_gated)
                        self.assertIsNone(self.state.load()["memFreePercent"])
                        self.assertEqual(gh.published[-1]["idle_runners"], 4)
                    warnings = [call.args[0] for call in log.call_args_list if "memory_pressure unreadable" in call.args[0]]
                    self.assertEqual(len(warnings), 1)
                    self.assertEqual(self.state.load()["memUnreadableSince"], 1000)

    def test_unreadable_memory_pressure_preserves_the_load_gate(self):
        gh = FakeGitHub([], {})
        ctl = self.controller(gh, lambda: (13, 0, 0), Mock(side_effect=OSError("unreadable")))
        self.assertTrue(ctl.publish_once())
        self.assertEqual(self.state.load()["hostGateReason"], "load")
        self.assertFalse(ctl.mem_gated)
        self.assertTrue(gh.published[-1]["busy"])

    def test_transient_memory_failures_preserve_both_gate_states_until_readable(self):
        for initial in (34, 60):
            with self.subTest(initial=initial):
                gh = FakeGitHub([], {})
                ctl = self.controller(gh, getmemoryfree=Mock(side_effect=[
                    initial, subprocess.TimeoutExpired("memory_pressure", 5),
                    OSError("unreadable"), ValueError("missing percentage"), 45,
                ]))
                with patch.object(ab, "log") as log:
                    for index in range(5):
                        self.assertTrue(ctl.publish_once())
                        gated = initial == 34 and index < 4
                        self.assertEqual(ctl.mem_gated, gated)
                        self.assertEqual(gh.published[-1]["idle_runners"], 0 if gated else 4)
                        self.assertTrue(self.state.load()["memSampled"])
                    self.assertFalse(any("memory gate disabled" in call.args[0] for call in log.call_args_list))
                    holds = [call.args[0] for call in log.call_args_list if "holding memory gate" in call.args[0]]
                    self.assertEqual(holds, [f"memory_pressure unreadable (Command 'memory_pressure' timed out after 5 seconds); holding memory gate {'ON' if initial == 34 else 'OFF'}"])
                    recoveries = [call.args[0] for call in log.call_args_list if "readable again" in call.args[0]]
                    self.assertEqual(recoveries, ["memory_pressure readable again; memory gate re-enabled"])
                    self.assertIsNone(self.state.load()["memUnreadableSince"])

    def test_memory_failure_after_restart_keeps_a_previously_readable_gate(self):
        gh = FakeGitHub([], {})
        ctl = self.controller(gh, getmemoryfree=Mock(side_effect=[34, OSError("unreadable")]))
        ctl.sample_host()
        self.clock.return_value = 1005
        ctl.sample_host()
        self.state = ab.State(self.tmp)
        self.clock.return_value = 1300
        restarted = self.controller(gh, getmemoryfree=Mock(side_effect=OSError("still unreadable")))
        with patch.object(ab, "log") as log:
            self.assertTrue(restarted.publish_once())
        log.assert_not_called()
        self.assertTrue(self.state.load()["memGated"])
        self.assertEqual(self.state.load()["memUnreadableSince"], 1005)
        self.assertTrue(gh.published[-1]["busy"])

    def test_memory_hold_expires_releases_and_stays_disabled_across_restart(self):
        for initial in (34, 60):
            with self.subTest(initial=initial):
                self.clock.return_value = 1000
                gh = FakeGitHub([], {})
                ctl = self.controller(gh, getmemoryfree=Mock(side_effect=[initial] + [OSError("unreadable")] * 4))
                ctl.sample_host()
                with patch.object(ab, "log") as log:
                    for now in (1005, 1604):
                        self.clock.return_value = now
                        self.assertTrue(ctl.publish_once())
                        self.assertEqual(ctl.mem_gated, initial == 34)
                        self.assertEqual(gh.published[-1]["idle_runners"], 0 if initial == 34 else 4)
                        self.assertEqual(self.state.load()["memUnreadableSince"], 1005)
                    for now in (1605, 3000):
                        self.clock.return_value = now
                        self.assertTrue(ctl.publish_once())
                        self.assertFalse(ctl.mem_gated)
                        self.assertFalse(self.state.load()["memSampled"])
                        self.assertEqual(gh.published[-1]["idle_runners"], 4)
                    warnings = [call.args[0] for call in log.call_args_list if "memory_pressure unreadable" in call.args[0]]
                    self.assertEqual(warnings, [f"memory_pressure unreadable (unreadable); holding memory gate {'ON' if initial == 34 else 'OFF'}",
                                                "memory_pressure unreadable; memory gate disabled: unreadable"])
                self.state = ab.State(self.tmp)
                restarted = self.controller(gh, getmemoryfree=Mock(side_effect=[OSError("still unreadable"), 40, 34]))
                with patch.object(ab, "log") as log:
                    restarted.sample_host()
                    log.assert_not_called()
                    self.assertFalse(restarted.mem_gated)
                    self.assertEqual(self.state.load()["memUnreadableSince"], 1005)
                    restarted.sample_host()
                    self.assertFalse(restarted.mem_gated, "recovery restores hysteresis from the released gate")
                    self.assertIsNone(self.state.load()["memUnreadableSince"])
                    self.assertTrue(self.state.load()["memSampled"])
                    restarted.sample_host()
                    self.assertTrue(restarted.mem_gated)

    def test_memory_hold_recovery_resets_the_next_outage_deadline(self):
        ctl = self.controller(FakeGitHub([], {}), getmemoryfree=Mock(side_effect=[
            34, OSError("unreadable"), 40, OSError("unreadable"), OSError("unreadable"),
        ]))
        with patch.object(ab, "log") as log:
            ctl.sample_host()
            self.clock.return_value = 1010
            ctl.sample_host()
            self.assertEqual(self.state.load()["memUnreadableSince"], 1010)
            self.clock.return_value = 1500
            ctl.sample_host()
            self.assertIsNone(self.state.load()["memUnreadableSince"])
            self.assertTrue(ctl.mem_gated, "recovery in the hysteresis band preserves the gate")
            self.clock.return_value = 1600
            ctl.sample_host()
            self.assertEqual(self.state.load()["memUnreadableSince"], 1600)
            self.clock.return_value = 1610
            ctl.sample_host()
            self.assertTrue(ctl.mem_gated, "the previous outage does not shorten the new hold")
        self.assertEqual(sum("holding memory gate" in call.args[0] for call in log.call_args_list), 2)
        self.assertEqual(sum("readable again" in call.args[0] for call in log.call_args_list), 1)
        self.assertFalse(any("memory gate disabled" in call.args[0] for call in log.call_args_list))

    def test_custom_memory_hold_and_zero_hold_preserve_the_load_gate(self):
        for hold in (0, 30):
            with self.subTest(hold=hold):
                self.cfg["memHoldSeconds"] = hold
                self.clock.return_value = 1000
                ctl = self.controller(FakeGitHub([], {}), lambda: (13, 0, 0),
                                      Mock(side_effect=[34, OSError("unreadable"), OSError("unreadable")]))
                ctl.sample_host()
                self.clock.return_value = 1010
                ctl.sample_host()
                self.assertEqual(ctl.mem_gated, hold > 0)
                self.clock.return_value = 1040
                ctl.sample_host()
                self.assertFalse(ctl.mem_gated)
                self.assertEqual(self.state.load()["hostGateReason"], "load")

    def test_host_samples_do_not_hold_the_state_lock_and_use_latest_gate_state(self):
        def load():
            self.state.update(lambda d: d.update(loadGated=True))
            return (10, 0, 0)

        def memory():
            self.state.update(lambda d: d.update(memGated=True, hostGateReason="load+memory"))
            return 40

        ctl = self.controller(FakeGitHub([], {}), load, memory)
        with patch.object(ab, "log") as log:
            sampled = ctl.sample_host()
        log.assert_not_called()
        self.assertTrue(sampled["loadGated"])
        self.assertTrue(sampled["memGated"])
        self.assertEqual(sampled["hostGateReason"], "load+memory")

    def test_old_load_gated_state_upgrades_without_a_spurious_transition(self):
        self.state.file.write_text(json.dumps({"mode": "on", "loadGated": True}))
        self.state = ab.State(self.tmp)
        r = run(id=9)
        job = {"id": 90, "status": "queued", "labels": ab.mint_labels(CFG, r)}
        gh = FakeGitHub([r], {9: [job]})
        ctl = self.controller(gh, Mock(side_effect=[(10, 0, 0), (10, 0, 0), (7, 0, 0)]))
        with patch.object(ab, "log") as log:
            self.assertEqual(ctl.tick(), "on")
            self.assertTrue(ctl.publish_once())
            log.assert_not_called()
            data = self.state.load()
            self.assertTrue(data["loadGated"])
            self.assertTrue(data["hostGated"])
            self.assertEqual(data["hostGateReason"], "load")
            self.assertFalse(data["memGated"])
            self.assertNotIn("lastClaimAt", data)
            self.assertEqual(data["slots"], {})
            self.assertEqual(ctl.pending, 1)
            self.assertTrue(gh.published[-1]["busy"])
            self.assertEqual(ctl.tick(), "on")
            self.assertEqual(log.call_count, 1)
            self.assertIn("host gate OFF", log.call_args.args[0])
        self.assertEqual(self.state.load()["slots"]["0"]["jobId"], 90)
        self.assertEqual(self.state.load()["lastClaimAt"], 1000)
        self.assertEqual(gh.cancelled, [])

    def test_unverified_and_wrong_class_runs_are_cancelled_while_gated(self):
        fork = run(id=7, event="pull_request", head_repository={"full_name": "evil/paimos"})
        wrong_class = run(id=8)
        jobs = {
            7: [{"id": 70, "status": "queued", "labels": ab.mint_labels(CFG, fork)}],
            8: [{"id": 80, "status": "queued", "labels": ["mbp2606", "mbp2606-pr"]}],
        }
        gh = FakeGitHub([fork, wrong_class], jobs)
        ctl = self.controller(gh, lambda: (13.0, 0, 0))
        self.assertEqual(ctl.tick(), "on")
        self.assertTrue(ctl.load_gated)
        self.assertEqual(gh.cancelled, [7, 8])
        self.assertEqual(self.state.load()["slots"], {})
        self.assertEqual(ctl.workers, {})
        ctl.tick()
        self.assertEqual(gh.cancelled, [7, 8], "cancel once")

    def test_controller_converts_integer_thresholds_to_floats(self):
        ctl = ab.Controller({**self.cfg, "loadHigh": 14, "loadLow": 10}, gh=FakeGitHub([], {}),
                            lima=object(), state=self.state, getloadavg=lambda: (13.0, 0, 0), getmemoryfree=lambda: 60)
        self.assertIsInstance(ctl.cfg["loadHigh"], float)
        self.assertIsInstance(ctl.cfg["loadLow"], float)
        self.assertEqual(ctl.cfg["loadHigh"], 14.0)
        self.assertEqual(ctl.cfg["loadLow"], 10.0)
        ctl.tick()
        self.assertFalse(ctl.load_gated)

    def test_publish_load_gate_advertises_busy_then_normal_free_slots(self):
        gh = FakeGitHub([], {})
        getloadavg = Mock(side_effect=[(5.0, 0, 0), (13.0, 0, 0), (10.0, 0, 0), (7.0, 0, 0)])
        ctl = self.controller(gh, getloadavg)
        slot = {"jobId": 1, "phase": "running", "vm": "aeon-job-0"}
        self.state.update(lambda d: d["slots"].update({"0": slot}))
        ctl.pending = 1
        for idle, busy in ((2, False), (0, True), (0, True), (2, False)):
            self.assertTrue(ctl.publish_once())
            self.assertEqual(gh.published[-1]["idle_runners"], idle)
            self.assertEqual(gh.published[-1]["busy"], busy)
            self.assertEqual(self.state.load()["slots"], {"0": slot})
            self.assertEqual(self.state.load()["mode"], "on")
        self.assertEqual(gh.cancelled, [])
        self.assertEqual(getloadavg.call_count, 4)

    def test_tick_gate_preserves_running_slots_and_workers(self):
        gh = FakeGitHub([], {})
        ctl = self.controller(gh, lambda: (13.0, 0, 0))
        worker = Mock()
        worker.is_alive.return_value = True
        ctl.workers[1] = worker
        slot = {"jobId": 1, "phase": "running", "vm": "aeon-job-0"}
        self.state.update(lambda d: d["slots"].update({"0": slot}))
        ctl.lima = Mock()
        self.assertEqual(ctl.tick(), "on")
        self.assertEqual(ctl.workers, {1: worker})
        self.assertEqual(self.state.load()["slots"], {"0": slot})
        self.assertEqual(ctl.lima.mock_calls, [])
        worker.join.assert_not_called()

    def test_gate_transitions_are_shared_between_tick_and_publisher(self):
        gh = FakeGitHub([], {})
        getloadavg = Mock(side_effect=[(13.0, 0, 0), (13.0, 0, 0), (10.0, 0, 0), (7.0, 0, 0), (7.0, 0, 0)])
        ctl = self.controller(gh, getloadavg)
        with patch.object(ab, "log") as log:
            ctl.tick()
            ctl.publish_once()
            ctl.tick()
            ctl.publish_once()
            ctl.tick()
        self.assertEqual(log.call_args_list, [
            unittest.mock.call("host gate ON (load): 1-min load 13.0, memory free 60.0%; not taking new jobs"),
            unittest.mock.call("host gate OFF: 1-min load 7.0, memory free 60.0%"),
        ])
        self.assertFalse(self.state.load()["loadGated"])
        self.assertEqual(self.state.load()["load1"], 7.0)
        self.assertEqual(getloadavg.call_count, 5)

    def test_publisher_engaging_gate_during_tick_blocks_slot_claim(self):
        r = run(id=9)
        job = {"id": 90, "status": "queued", "labels": ab.mint_labels(CFG, r)}
        gh = FakeGitHub([r], {9: [job]})
        ctl = self.controller(gh, Mock(side_effect=[(5.0, 0, 0), (13.0, 0, 0)]))
        # Engage from the independent publisher after tick's initial sample,
        # during the last API check before a slot would be claimed.
        gh.ruleset = Mock(side_effect=[ctl.cfg["ruleset"]["expected"], ctl.cfg["ruleset"]["expected"]])
        original_check = ctl.check_ruleset
        def check_ruleset():
            ctl.check_ruleset = original_check
            self.assertTrue(ctl.publish_once())
            return original_check()
        ctl.check_ruleset = check_ruleset
        ctl.tick()
        self.assertTrue(ctl.load_gated)
        self.assertEqual(self.state.load()["slots"], {})
        self.assertEqual(gh.cancelled, [])
        self.assertTrue(gh.published[-1]["busy"])

    def test_publisher_engaging_memory_gate_during_tick_blocks_slot_claim(self):
        r = run(id=9)
        job = {"id": 90, "status": "queued", "labels": ab.mint_labels(CFG, r)}
        gh = FakeGitHub([r], {9: [job]})
        ctl = self.controller(gh, getmemoryfree=Mock(side_effect=[60, 34]))
        original_check = ctl.check_ruleset

        def check_ruleset():
            ctl.check_ruleset = original_check
            self.assertTrue(ctl.publish_once())
            return original_check()
        ctl.check_ruleset = check_ruleset
        ctl.tick()
        self.assertTrue(ctl.mem_gated)
        self.assertEqual(self.state.load()["slots"], {})
        self.assertEqual(gh.cancelled, [])
        self.assertTrue(gh.published[-1]["busy"])

    def test_busy_file_is_replaced_atomically_with_occupied_slots_mode_and_group(self):
        gh = FakeGitHub([], {})
        ctl = self.controller(gh, getmemoryfree=lambda: 34)
        self.state.update(lambda d: d["slots"].update({"0": {"jobId": 1}, "1": {"jobId": 2}}))
        path = Path(self.cfg["busyFile"])
        path.write_text("old\n")
        replaced = []
        real_replace = ab.os.replace

        def replace(src, dst):
            if Path(dst) == path:
                self.assertEqual(path.read_text(), "old\n", "previous content is intact until rename")
                self.assertEqual(Path(src).parent, path.parent)
                self.assertNotEqual(Path(src), path)
                self.assertTrue(Path(src).name.startswith(f".{path.name}."))
                self.assertEqual(Path(src).read_text(), "2/4 1000\n")
                self.assertEqual(Path(src).stat().st_mode & 0o777, 0o640)
                self.assertEqual(Path(src).stat().st_gid, os.getgid())
                self.assertEqual(chown.call_count, 1)
                self.assertEqual(chown.call_args.args[1:], (-1, os.getgid()))
                replaced.append(src)
            real_replace(src, dst)

        def fchown(fd, uid, gid):
            self.assertIsInstance(fd, int)
            self.assertEqual(os.fstat(fd).st_size, 0, "permissions precede writing content")
            self.assertEqual(os.fstat(fd).st_mode & 0o777, 0o640)
            real_fchown(fd, uid, gid)

        real_fchown = ab.os.fchown
        with patch.object(ab.os, "fchown", side_effect=fchown) as chown, \
                patch.object(ab.os, "replace", side_effect=replace), patch.object(Path, "unlink") as unlink:
            self.assertTrue(ctl.publish_once())
        unlink.assert_not_called()
        self.assertEqual(len(replaced), 1)
        self.assertEqual(path.read_text(), "2/4 1000\n", "the file counts occupied slots even while host-gated")
        self.assertEqual(path.stat().st_mode & 0o777, 0o640)
        self.assertEqual(path.stat().st_gid, os.getgid())
        self.assertEqual(self.state.file.stat().st_mode & 0o777, 0o600)
        self.clock.return_value = 1005
        ctl.publish_once()
        self.assertEqual(path.read_text(), "2/4 1005\n", "each publish refreshes the timestamp")

    def test_unknown_busy_file_group_logs_once_without_creating_a_temp_file(self):
        self.cfg["busyFileGroup"] = "aeon-builder-no-such-test-group"
        path = Path(self.cfg["busyFile"])
        original_files = set(self.tmp.iterdir())
        with patch.object(ab.grp, "getgrnam", side_effect=KeyError(self.cfg["busyFileGroup"])), \
                patch.object(ab.tempfile, "mkstemp", wraps=ab.tempfile.mkstemp) as mkstemp, \
                patch.object(ab, "log") as log:
            for _ in range(2):
                ab.write_busy_file(self.cfg, self.state.load())
        self.assertFalse(any(call.kwargs["prefix"] == f".{path.name}." for call in mkstemp.call_args_list))
        log.assert_called_once()
        self.assertIn("busy file write failed:", log.call_args.args[0])
        self.assertIn(self.cfg["busyFileGroup"], log.call_args.args[0])
        self.assertFalse(path.exists())
        self.assertEqual(set(self.tmp.iterdir()), original_files | {self.tmp / "busy-file.lasterror"},
                         "group lookup failures leave only the persisted error")

    def test_busy_file_chown_failure_logs_once_and_keeps_previous_file(self):
        ctl = self.controller(FakeGitHub([], {}))
        path = Path(self.cfg["busyFile"])
        path.write_text("previous\n")
        original_files = set(self.tmp.iterdir())

        def chown(target, uid, gid):
            self.assertEqual((uid, gid), (-1, os.getgid()))
            raise PermissionError(1, "busy file group denied", str(target))

        with patch.object(ab.os, "fchown", side_effect=chown), patch.object(ab, "log") as log:
            for _ in range(2):
                self.assertTrue(ctl.publish_once())
        log.assert_called_once()
        self.assertIn("busy file write failed: [Errno 1] busy file group denied:", log.call_args.args[0])
        self.assertEqual(path.read_text(), "previous\n")
        self.assertEqual(set(self.tmp.iterdir()), original_files | {self.tmp / "busy-file.lasterror"},
                         "chown failures leave no temp files")

    def test_busy_file_preserves_occupied_slots_and_epoch_in_every_mode(self):
        gh = FakeGitHub([], {})
        ctl = self.controller(gh)
        for slots in ({}, {"0": {"jobId": 1, "phase": "running", "vm": "aeon-job-0"}}):
            for mode in ("on", "off", "paused", "draining", "stopping"):
                with self.subTest(mode=mode, occupied=len(slots)):
                    self.state.update(lambda d: d.update(mode=mode, slots=slots.copy()))
                    self.assertEqual(ctl.publish_once(), mode == "on")
                    self.assertEqual(Path(self.cfg["busyFile"]).read_text(), f"{len(slots)}/4 1000\n")
                    self.assertEqual(self.state.load()["slots"], slots)

    def test_pause_writes_busy_file_before_clearing_availability(self):
        gh = FakeGitHub([], {})
        ctl = self.controller(gh)
        ctl.publish_once()
        gh.clear = Mock(side_effect=lambda: self.assertEqual(Path(self.cfg["busyFile"]).read_text(), "0/4 1000\n"))
        ctl.pause("test")
        gh.clear.assert_called_once_with()

    def test_busy_file_write_errors_are_nonfatal_and_keep_the_previous_file(self):
        gh = FakeGitHub([], {})
        ctl = self.controller(gh)
        path = Path(self.cfg["busyFile"])
        path.write_text("previous\n")
        original_files = set(self.tmp.iterdir())
        real_replace = ab.os.replace

        def replace(src, dst):
            if Path(dst) == path:
                raise PermissionError(1, "busy file denied", str(src))
            real_replace(src, dst)
        with patch.object(ab.os, "replace", side_effect=replace), patch.object(ab, "log") as log:
            for _ in range(2):
                self.assertTrue(ctl.publish_once())
            self.assertEqual(path.read_text(), "previous\n")
            self.assertEqual(set(self.tmp.iterdir()), original_files | {self.tmp / "busy-file.lasterror"},
                             "failed writes leave no temporary files")
            self.assertEqual(log.call_count, 1, "changing temp filenames do not repeat the same error")
            self.assertIn("busy file write failed: [Errno 1] busy file denied:", log.call_args.args[0])
        self.assertEqual(gh.published[-1]["idle_runners"], 4)

    def test_busy_file_logs_only_changed_errors_and_resets_after_recovery(self):
        gh = FakeGitHub([], {})
        ctl = self.controller(gh)
        errors = [PermissionError("denied"), PermissionError("denied"), OSError("disk full"),
                  OSError("disk full"), None, OSError("disk full")]
        real_write = ab.atomic_write
        path = Path(self.cfg["busyFile"])

        def write(target, text, mode=0o600, group=None):
            if target == path:
                error = errors.pop(0)
                if error:
                    raise error
            real_write(target, text, mode, group)

        with patch.object(ab, "atomic_write", side_effect=write), patch.object(ab, "log") as log:
            for index in range(6):
                self.assertTrue(ctl.publish_once())
                marker = self.tmp / "busy-file.lasterror"
                self.assertEqual(marker.stat().st_mode & 0o777, 0o600)
                if index == 4:
                    self.assertEqual(marker.read_text(), "", "success clears the persisted error")
        self.assertEqual(log.call_args_list, [unittest.mock.call(f"busy file write failed: {error}")
                                             for error in ("denied", "disk full", "disk full")])
        self.assertEqual(path.read_text(), "0/4 1000\n")

    def test_second_busy_file_process_does_not_log_the_same_error(self):
        self.cfg["busyFileGroup"] = "aeon-builder-no-such-test-group"
        script = '''import importlib.util, json, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("aeon_builder", sys.argv[1])
ab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ab)
ab.STATE_DIR = Path(sys.argv[2])
ab.write_busy_file(json.loads(sys.argv[3]), {"slots": {}})
'''
        command = [sys.executable, "-c", script, str(ROOT / "modules/aeon-builder/aeon_builder.py"),
                   str(self.tmp), json.dumps(self.cfg)]
        first = subprocess.run(command, capture_output=True, text=True)
        second = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("busy file write failed:", first.stdout)
        self.assertEqual(second.stdout, "")
        self.assertEqual(second.stderr, "")
        self.assertEqual((self.tmp / "controller.log").read_text().count("busy file write failed:"), 1)

    def test_busy_file_error_persistence_failure_is_nonfatal_and_deduplicated_locally(self):
        real_write = ab.atomic_write

        def write(target, *args, **kwargs):
            if target == self.tmp / "busy-file.lasterror":
                raise PermissionError("state directory denied")
            return real_write(target, *args, **kwargs)

        self.cfg["busyFileGroup"] = "aeon-builder-no-such-test-group"
        with patch.object(ab, "atomic_write", side_effect=write), patch.object(ab, "log") as log:
            ab.write_busy_file(self.cfg, self.state.load())
            ab.write_busy_file(self.cfg, self.state.load())
        log.assert_called_once()

    def test_off_command_writes_busy_file_when_controller_is_not_running(self):
        gh = FakeGitHub([], {})
        real_init = ab.State.__init__
        with patch.object(ab.State, "__init__", lambda state: real_init(state, self.tmp)), \
                patch.object(ab, "controller_pid", return_value=None), \
                patch.object(ab, "GitHub", return_value=gh), \
                patch.object(ab, "Lima") as lima, \
                patch("sys.stdout", new_callable=io.StringIO):
            lima.return_value.instances.return_value = {}
            self.assertEqual(ab.cmd_off(self.cfg, Mock(now=False, wait=0)), 0)
        self.assertEqual(Path(self.cfg["busyFile"]).read_text(), "0/4 1000\n")
        self.assertEqual(self.state.load()["mode"], "off")

    def test_busy_file_command_refreshes_without_locking_or_changing_state(self):
        config = self.tmp / "config.json"
        config.write_text(json.dumps(self.cfg))
        for mode in ("off", "paused"):
            with self.subTest(mode=mode):
                slots = {} if mode == "off" else {"0": {"jobId": 1, "phase": "running"}}
                self.state.update(lambda d: d.update(mode=mode, slots=slots))
                previous = self.state.file.read_bytes()
                with patch.object(ab, "State", return_value=self.state) as state, \
                        patch.object(self.state, "locked", side_effect=AssertionError("read-only command must not lock")), \
                        patch.object(self.state, "save", side_effect=AssertionError("read-only command must not save")), \
                        patch.object(ab, "Controller") as controller, \
                        patch.object(ab, "GitHub") as github, patch.object(ab, "Lima") as lima:
                    for now in (1000, 1700):
                        self.clock.return_value = now
                        self.assertEqual(ab.main(["--config", str(config), "busy-file"]), 0)
                        self.assertEqual(Path(self.cfg["busyFile"]).read_text(), f"{len(slots)}/4 {now}\n")
                        self.assertEqual(self.state.file.read_bytes(), previous)
                    self.assertEqual(state.call_count, 2)
                    state.assert_called_with()
                    controller.assert_not_called()
                    github.assert_not_called()
                    lima.assert_not_called()

    def test_busy_file_command_returns_zero_on_write_and_log_failure(self):
        config = self.tmp / "config.json"
        config.write_text(json.dumps(self.cfg))
        path = Path(self.cfg["busyFile"])
        path.write_text("previous\n")
        previous_state = self.state.file.read_bytes()
        real_replace = ab.os.replace

        def replace(src, dst):
            if Path(dst) == path:
                raise PermissionError("busy file denied")
            real_replace(src, dst)
        for log_error in (None, PermissionError("log denied")):
            marker = self.tmp / "busy-file.lasterror"
            if marker.exists():
                marker.write_text("")
            with self.subTest(log_error=log_error), \
                    patch.object(ab, "_busy_file_errors", {}), \
                    patch.object(ab, "State", return_value=self.state), \
                    patch.object(ab.os, "replace", side_effect=replace), \
                    patch.object(ab, "log", side_effect=log_error) as log, \
                    patch("sys.stderr", new_callable=io.StringIO) as stderr:
                original_files = set(self.tmp.iterdir())
                self.assertEqual(ab.main(["--config", str(config), "busy-file"]), 0)
                log.assert_called_once_with("busy file write failed: busy file denied")
                if log_error:
                    self.assertIn("busy file write failed: busy file denied", stderr.getvalue())
                self.assertEqual(path.read_text(), "previous\n")
                self.assertEqual(self.state.file.read_bytes(), previous_state)
                self.assertEqual(set(self.tmp.iterdir()), original_files | {marker})

    def test_busy_file_command_is_hidden_from_help(self):
        with patch("sys.stdout", new_callable=io.StringIO) as output, self.assertRaises(SystemExit) as exit:
            ab.main(["--help"])
        self.assertEqual(exit.exception.code, 0)
        self.assertNotIn("busy-file", output.getvalue())

    def test_status_shows_controller_gate_and_sampled_load(self):
        ctl = self.controller(FakeGitHub([], {}), lambda: (13.0, 0, 0))
        ctl.tick()
        with patch.object(ab, "State", return_value=self.state), \
                patch.object(ab, "controller_pid", return_value=123), \
                patch.object(ab, "Lima") as lima, \
                patch.object(ab, "lab_vms", return_value=[]), \
                patch.object(ab.subprocess, "run", return_value=Mock(stdout="")), \
                patch("sys.stdout", new_callable=io.StringIO) as output:
            lima.return_value.instances.return_value = {}
            ab.cmd_status(CFG, None)
        self.assertIn("load gate:   ON  1-min load 13.0", output.getvalue())
        self.assertIn("high 12.0, low 8.0", output.getvalue())
        self.assertIn("memory gate: OFF  free 60.0%", output.getvalue())
        self.assertIn("host gate:   ON (load)", output.getvalue())
        self.assertIn("last claim:  never", output.getvalue())

    def test_status_shows_sampled_memory_gate_and_seconds_since_last_claim(self):
        ctl = self.controller(FakeGitHub([], {}), getmemoryfree=lambda: 34.5)
        self.state.update(lambda d: d.update(lastClaimAt=880))
        ctl.tick()
        with patch.object(ab, "State", return_value=self.state), \
                patch.object(ab, "controller_pid", return_value=123), \
                patch.object(ab, "Lima") as lima, \
                patch.object(ab, "lab_vms", return_value=[]), \
                patch.object(ab.subprocess, "run", return_value=Mock(stdout="")), \
                patch("sys.stdout", new_callable=io.StringIO) as output:
            lima.return_value.instances.return_value = {}
            ab.cmd_status(CFG, None)
        self.assertIn("memory gate: ON  free 34.5%", output.getvalue())
        self.assertIn("low 35, high 45", output.getvalue())
        self.assertIn("host gate:   ON (memory)", output.getvalue())
        self.assertIn("last claim:  120 s ago", output.getvalue())

    def test_status_shows_memory_hold_and_unreadable_disable_timestamps(self):
        for sampled, gated, expected in ((True, True, "ON  held since 1970-01-01T00:16:40Z"),
                                         (True, False, "OFF  held since 1970-01-01T00:16:40Z"),
                                         (False, False, "disabled (unreadable since 1970-01-01T00:16:40Z)")):
            with self.subTest(sampled=sampled, gated=gated):
                self.state.update(lambda d: d.update(memSampled=sampled, memGated=gated, memUnreadableSince=1000))
                with patch.object(ab, "State", return_value=self.state), \
                        patch.object(ab, "controller_pid", return_value=None), \
                        patch.object(ab, "Lima") as lima, patch.object(ab, "lab_vms", return_value=[]), \
                        patch.object(ab.subprocess, "run", return_value=Mock(stdout="")), \
                        patch("sys.stdout", new_callable=io.StringIO) as output:
                    lima.return_value.instances.return_value = {}
                    ab.cmd_status(CFG, None)
                self.assertIn(f"memory gate: {expected}", output.getvalue())

    def test_unverified_run_is_cancelled_and_never_served(self):
        fork = run(id=7, event="pull_request", head_repository={"full_name": "evil/paimos"})
        gh = FakeGitHub([fork], {7: [{"id": 70, "status": "queued", "labels": ab.mint_labels(CFG, fork)}]})
        ctl = self.controller(gh)
        ctl.tick()
        self.assertEqual(gh.cancelled, [7])
        self.assertEqual(self.served, [])
        ctl.tick()
        self.assertEqual(gh.cancelled, [7], "cancel once")

    def test_verified_jobs_get_slots_and_availability_counts_down(self):
        jobs = [{"id": 900 + i, "status": "queued", "labels": ["self-hosted", "Linux", "ARM64", "mbp2606", "mbp2606-push"]} for i in range(5)]
        gh = FakeGitHub([run(id=9)], {9: jobs})
        ctl = self.controller(gh)
        for i in range(4):
            self.clock.return_value = 1000 + i * 180
            ctl.tick()
        self.assertEqual(sorted(s for s, _, _ in self.served), [0, 1, 2, 3])
        self.assertTrue(ctl.publish_once())
        self.assertEqual(gh.published[-1]["idle_runners"], 0)
        self.assertTrue(gh.published[-1]["busy"])

    def test_all_event_classes_can_fill_the_pool_together(self):
        runs = [run(id=i, event=event, head_branch="work/x" if event in ("pull_request", "merge_group") else "main")
                for i, event in enumerate(CFG["events"], start=1)]
        jobs = {r["id"]: [{"id": r["id"] * 10, "status": "queued", "labels": ab.mint_labels(CFG, r)}] for r in runs}
        gh = FakeGitHub(runs, jobs)
        ctl = self.controller(gh)
        for i in range(4):
            self.clock.return_value = 1000 + i * 180
            ctl.tick()
        self.assertEqual(sorted(self.served), [(i, i + 1, (i + 1) * 10) for i in range(4)])
        self.assertEqual(gh.cancelled, [])
        self.assertTrue(ctl.publish_once())
        self.assertEqual(gh.published[-1]["idle_runners"], 0)

    def test_jit_registration_uses_labels_matching_each_event_job(self):
        for event in CFG["events"]:
            with self.subTest(event=event):
                self.state.update(lambda d: d.pop("lastClaimAt", None))
                r = run(id=9, event=event, head_branch="work/x" if event in ("pull_request", "merge_group") else "main")
                labels = CFG["runnerLabels"] + [CFG["classLabels"][event]]
                job = {"id": 90, "status": "queued", "labels": labels}
                gh = FakeGitHub([r], {9: [job]})
                gh.jit = Mock(return_value={"runner": {"id": 123}, "encoded_jit_config": "test-jit"})
                gh.delete_runner = Mock()
                ctl = ab.Controller(CFG, gh=gh, lima=Mock(), state=self.state, getmemoryfree=lambda: 60)
                ctl.prepare_disk = Mock(return_value=("aeon-cache-0" if event == "push" else "aeon-scratch-0", False))
                ctl.retire_slot = Mock()
                ctl.wait_for_runner = Mock(return_value="idle")
                slot = ctl.claim_slot(job, r)
                self.assertEqual(slot, 0)
                ctl.serve(slot, r, job)
                gh.jit.assert_called_once()
                self.assertEqual(gh.jit.call_args.args[1], labels)
                self.assertTrue(ab.could_take(job, gh.jit.call_args.args[1]))
                gh.delete_runner.assert_called_once_with(123)
                ctl.retire_slot.assert_called_once()
                ctl.release_slot(slot)

    def test_non_push_jobs_prepare_disposable_clones_of_known_good_cache(self):
        good = self.tmp / "known-good.datadisk"
        good.write_text("test cache")
        for event in ("workflow_dispatch", "pull_request", "merge_group"):
            with self.subTest(event=event):
                lima = Mock()
                lima.disks.return_value = []
                ctl = ab.Controller(CFG, gh=FakeGitHub([], {}), lima=lima, state=self.state, getmemoryfree=lambda: 60)
                ctl.good_copy = Mock(return_value=good)
                ctl.disk_file = lambda name: self.tmp / name
                with patch.object(ab.subprocess, "run") as copy:
                    self.assertEqual(ctl.prepare_disk(0, run(event=event)), ("aeon-scratch-0", False))
                lima.run.assert_called_once_with("disk", "create", "aeon-scratch-0", "--size", "60GiB", "--format", "raw")
                copy.assert_called_once_with(["/bin/cp", "-c", str(good), str(self.tmp / "aeon-scratch-0")], check=True)

    def test_hosted_jobs_are_ignored(self):
        gh = FakeGitHub([run(id=9)], {9: [{"id": 1, "status": "queued", "labels": ["ubuntu-latest"]}]})
        ctl = self.controller(gh)
        ctl.tick()
        self.assertEqual(self.served, [])
        self.assertTrue(ctl.publish_once())
        self.assertEqual(gh.published[-1]["idle_runners"], 4)

    def test_off_publishes_nothing_and_drain_ends_off(self):
        gh = FakeGitHub([], {})
        ctl = self.controller(gh)
        self.state.update(lambda d: d.update(mode="draining"))
        self.assertEqual(ctl.tick(), "off")
        self.assertEqual(gh.published, [])
        self.assertEqual(ctl.tick(), "off")

    def test_publish_never_lands_after_a_pause(self):
        gh = FakeGitHub([], {})
        ctl = self.controller(gh)
        ctl.pause("test")
        self.assertFalse(ctl.publish_once())
        self.assertEqual(gh.published, [None], "only the clear")

    def test_transport_errors_become_builder_errors(self):
        gh = ab.GitHub.__new__(ab.GitHub)
        gh.etags = {}
        import urllib.error
        real = ab.urllib.request.urlopen
        ab.urllib.request.urlopen = lambda *a, **k: (_ for _ in ()).throw(urllib.error.URLError("string-reason URLError"))
        self.addCleanup(setattr, ab.urllib.request, "urlopen", real)
        with self.assertRaises(ab.BuilderError):
            gh._raw("GET", "/x", bearer="t")

    def test_failed_vm_deletion_holds_the_slot(self):
        gh = FakeGitHub([], {})
        ctl = self.controller(gh)
        self.state.update(lambda d: d["slots"].__setitem__("2", {"jobId": 1, "disk": "aeon-cache-2"}))

        class StuckLima:
            def delete(self, name):
                return False
        ctl.lima = StuckLima()
        restored = []
        ctl.finish_disk = lambda slot, disk: restored.append(slot)
        self.assertFalse(ctl.retire_slot(2, "aeon-job-2", "aeon-cache-2"))
        data = self.state.load()
        self.assertEqual(data["slots"]["2"]["phase"], "stuck")
        self.assertEqual(restored, [], "a surviving VM's disk is never restored underneath it")
        self.assertEqual(data["mode"], "paused")

    def test_tainted_disk_that_cannot_be_deleted_holds_the_slot(self):
        ctl = self.controller(FakeGitHub([], {}))
        self.state.update(lambda d: d["slots"].__setitem__("1", {"jobId": 1, "disk": "aeon-cache-1"}))
        old_state = ab.STATE_DIR
        ab.STATE_DIR = self.tmp
        self.addCleanup(setattr, ab, "STATE_DIR", old_state)

        class Lima:
            def delete(self, name):
                return True

            def delete_disk(self, name):
                raise ab.BuilderError("disk busy")
        ctl.lima = Lima()
        ctl.tainted.add(1)
        self.assertFalse(ctl.retire_slot(1, "aeon-job-1", "aeon-cache-1"))
        self.assertEqual(self.state.load()["slots"]["1"]["phase"], "stuck")
        self.assertIn(1, ctl.tainted, "still tainted until the disk is really gone")

    def test_unknown_vm_inventory_is_an_error_not_empty(self):
        lima = ab.Lima.__new__(ab.Lima)
        lima.run = lambda *a, **k: subprocess.CompletedProcess([], 1, "", "boom")
        with self.assertRaises(ab.BuilderError):
            lima.instances()

    def test_truncated_http_response_becomes_builder_error(self):
        import http.client
        gh = ab.GitHub.__new__(ab.GitHub)
        gh.etags = {}
        gh.sleep = Mock()
        real = ab.urllib.request.urlopen
        ab.urllib.request.urlopen = lambda *a, **k: (_ for _ in ()).throw(http.client.IncompleteRead(b"x"))
        self.addCleanup(setattr, ab.urllib.request, "urlopen", real)
        with self.assertRaises(ab.BuilderError):
            gh._raw("GET", "/x", bearer="t")
        self.assertEqual(gh.sleep.call_args_list, [unittest.mock.call(1), unittest.mock.call(2)])

    def test_ruleset_drift_pauses_and_clears(self):
        gh = FakeGitHub([run(id=9)], {9: [{"id": 1, "status": "queued", "labels": ["mbp2606", "mbp2606-push"]}]})
        gh.ruleset = lambda: dict(LIVE_RULESET, enforcement="evaluate")
        ctl = self.controller(gh)
        ctl.tick()
        self.assertEqual(self.served, [])
        self.assertEqual(self.state.load()["mode"], "paused")
        self.assertIn(None, gh.published)

    class Lima:
        def __init__(self, took):
            self.took = took

        def shell(self, vm, cmd, check=True):
            return subprocess.CompletedProcess([], 0 if self.took else 1, "", "")

    def post_job(self, jobs, runs, took=True):
        gh = FakeGitHub(runs, jobs)
        ctl = self.controller(gh)
        self.state.update(lambda d: d["verifiedRuns"].append(9))
        ctl.lima = self.Lima(took)
        ctl.post_job_check(0, "aeon-job-0", "mbp2606-s0-90-abc", {"id": 90})
        return self.state.load()["mode"], gh

    def test_post_job_ok_when_the_runner_took_a_sibling_job_of_a_verified_run(self):
        jobs = {9: [{"id": 90, "run_id": 9, "runner_name": "mbp2606-s1-91-def", "labels": ["mbp2606"], "status": "completed"},
                    {"id": 91, "run_id": 9, "runner_name": "mbp2606-s0-90-abc", "labels": ["mbp2606"], "status": "completed"}]}
        mode, _ = self.post_job(jobs, [run(id=9, status="completed")])
        self.assertEqual(mode, "on")

    def test_post_job_pauses_when_the_runner_ran_an_unverified_run(self):
        jobs = {9: [{"id": 90, "run_id": 9, "runner_name": "", "labels": ["mbp2606"], "status": "queued"}],
                66: [{"id": 660, "run_id": 66, "runner_name": "mbp2606-s0-90-abc", "labels": ["mbp2606"], "status": "queued"}]}
        mode, gh = self.post_job(jobs, [run(id=9), run(id=66, event="pull_request")])
        self.assertEqual(mode, "paused")
        self.assertIn(None, gh.published)
        self.assertEqual(sorted(gh.cancelled), [9, 66], "a pause cancels queued mbp2606 runs")

    def test_post_job_pauses_on_unattributable_work(self):
        jobs = {9: [{"id": 90, "run_id": 9, "runner_name": "", "labels": ["mbp2606"], "status": "completed"}]}
        self.assertEqual(self.post_job(jobs, [run(id=9, status="completed")])[0], "paused")

    disk = "aeon-cache-0"

    def admit(self, jobs, runs):
        gh = FakeGitHub(runs, jobs)
        ctl = self.controller(gh)
        self.state.update(lambda d: (d["verifiedRuns"].append(9), d["slots"].__setitem__("0", {"jobId": 90, "disk": self.disk})))
        calls = []

        class Lima:
            def run(self, *args, input=None, check=True):
                calls.append((args, input))
                return subprocess.CompletedProcess([], 0, "", "")
        ctl.lima = Lima()
        ctl.slot_key = lambda slot: "k" * 128
        ctl.slot_fresh = {0: False}
        sleep = ab.time.sleep
        ab.time.sleep = Mock()
        self.addCleanup(setattr, ab.time, "sleep", sleep)
        return ctl.admit(0, "aeon-job-0", "mbp2606-s0-90-abc", {"id": 90}), calls, gh

    def test_cache_unlocks_only_after_api_attribution_to_a_verified_run(self):
        jobs = {9: [{"id": 90, "run_id": 9, "run_attempt": 1, "runner_name": "mbp2606-s0-90-abc", "labels": ["mbp2606"]}]}
        verdict, calls, _ = self.admit(jobs, [run(id=9)])
        self.assertEqual(verdict, "ok")
        self.assertIn("unlock", calls[0][0])
        self.assertNotIn("--init", calls[0][0], "an existing disk is never re-initialised")
        self.assertEqual(calls[0][1], "k" * 128)

    def test_admit_recovers_from_one_transient_attribution_error(self):
        jobs = {9: [{"id": 90, "run_id": 9, "runner_name": "mbp2606-s0-90-abc", "labels": ["mbp2606"]}]}
        found = jobs[9][0]
        error = ab.TransientGitHubError("GET /x: disconnected")
        with patch.object(ab.Controller, "find_runner_job", side_effect=[error, found]) as find, \
                patch.object(ab, "log") as log:
            verdict, calls, _ = self.admit(jobs, [run(id=9)])
        self.assertEqual(verdict, "ok")
        self.assertEqual(find.call_count, 2)
        ab.time.sleep.assert_called_once_with(2)
        self.assertEqual(len(calls), 1)
        self.assertIn("unlock", calls[0][0])
        self.assertEqual(self.state.load()["mode"], "on")
        transient_logs = [call for call in log.call_args_list if "transient GitHub error" in call.args[0]]
        self.assertEqual(len(transient_logs), 1)

    def test_admit_transient_window_exhaustion_pauses_without_unlocking(self):
        jobs = {9: [{"id": 90, "run_id": 9, "runner_name": "", "labels": ["mbp2606"]}]}
        error = ab.TransientGitHubError("GET /x: disconnected")
        with patch.object(ab.Controller, "find_runner_job", side_effect=error) as find, \
                patch.object(ab, "log") as log:
            verdict, calls, _ = self.admit(jobs, [run(id=9)])
        self.assertEqual(verdict, "unattributed")
        self.assertEqual(find.call_count, 10)
        self.assertEqual(ab.time.sleep.call_args_list, [unittest.mock.call(2)] * 9)
        self.assertEqual(calls, [], "no unlock without API attribution")
        self.assertEqual(self.state.load()["mode"], "paused")
        transient_logs = [call for call in log.call_args_list if "transient GitHub error" in call.args[0]]
        self.assertEqual(len(transient_logs), 10)

    def test_admit_deadline_exhaustion_pauses_without_unlocking(self):
        clock = Mock(return_value=0)

        def unavailable(*_):
            clock.return_value += ab.ADMISSION_WAIT_SECONDS / 3 + 1
            raise ab.TransientGitHubError("GET /x: timeout")

        with patch.object(ab.time, "monotonic", clock), \
                patch.object(ab.Controller, "find_runner_job", side_effect=unavailable) as find:
            verdict, calls, _ = self.admit({}, [run(id=9)])
        self.assertEqual(verdict, "unattributed")
        self.assertEqual(find.call_count, 3, "the deadline ends admission before ten attempts")
        self.assertEqual(ab.time.sleep.call_args_list, [unittest.mock.call(2)] * 2)
        self.assertEqual(calls, [], "no unlock after the admission deadline")
        self.assertEqual(self.state.load()["mode"], "paused")

    def test_admit_does_not_read_run_metadata_after_attribution_deadline(self):
        clock = Mock(return_value=0)
        found = {"id": 90, "run_id": 9, "runner_name": "mbp2606-s0-90-abc"}

        def late_attribution(*_):
            clock.return_value = ab.ADMISSION_WAIT_SECONDS
            return found

        with patch.object(ab.time, "monotonic", clock), \
                patch.object(ab.Controller, "find_runner_job", side_effect=late_attribution), \
                patch.object(FakeGitHub, "run") as read:
            verdict, calls, _ = self.admit({}, [run(id=9)])
        self.assertEqual(verdict, "unattributed")
        read.assert_not_called()
        ab.time.sleep.assert_not_called()
        self.assertEqual(calls, [])
        self.assertEqual(self.state.load()["mode"], "paused")

    def test_admit_stopping_returns_stopped_without_pausing(self):
        self.state.update(lambda d: d.update(mode="stopping"))
        with patch.object(ab.time, "monotonic", return_value=0), \
                patch.object(ab.Controller, "find_runner_job") as find, \
                patch.object(ab.Controller, "pause") as pause:
            verdict, calls, _ = self.admit({}, [run(id=9)])
        self.assertEqual(verdict, "stopped")
        find.assert_not_called()
        pause.assert_not_called()
        ab.time.sleep.assert_not_called()
        self.assertEqual(calls, [])
        self.assertEqual(self.state.load()["mode"], "stopping")

    def test_admit_observes_stopping_during_a_transient_read_without_sleeping(self):
        def stop(*_):
            self.state.update(lambda d: d.update(mode="stopping"))
            raise ab.TransientGitHubError("GET /x: disconnected")

        with patch.object(ab.time, "monotonic", return_value=0), \
                patch.object(ab.Controller, "find_runner_job", side_effect=stop) as find, \
                patch.object(ab.Controller, "pause") as pause:
            verdict, calls, _ = self.admit({}, [run(id=9)])
        self.assertEqual(verdict, "stopped")
        find.assert_called_once()
        pause.assert_not_called()
        ab.time.sleep.assert_not_called()
        self.assertEqual(calls, [])

    def test_admit_recovers_from_one_transient_run_metadata_error(self):
        found = {"id": 90, "run_id": 9, "runner_name": "mbp2606-s0-90-abc"}
        error = ab.TransientGitHubError("GET /x: disconnected")
        with patch.object(ab.time, "monotonic", return_value=0), \
                patch.object(ab.Controller, "find_runner_job", return_value=found) as find, \
                patch.object(FakeGitHub, "run", side_effect=[error, run(id=9)]) as read, \
                patch.object(ab, "log") as log:
            verdict, calls, _ = self.admit({}, [run(id=9)])
        self.assertEqual(verdict, "ok")
        find.assert_called_once()
        self.assertEqual(read.call_count, 2)
        ab.time.sleep.assert_called_once_with(2)
        self.assertEqual(len(calls), 1)
        self.assertIn("unlock", calls[0][0])
        self.assertEqual(self.state.load()["mode"], "on")
        transient_logs = [call for call in log.call_args_list if "transient GitHub error" in call.args[0]]
        self.assertEqual(len(transient_logs), 1)

    def test_admit_run_metadata_deadline_exhaustion_pauses_without_unlocking(self):
        clock = Mock(return_value=0)
        found = {"id": 90, "run_id": 9, "runner_name": "mbp2606-s0-90-abc"}

        def unavailable(*_):
            clock.return_value += ab.ADMISSION_WAIT_SECONDS / 3 + 1
            raise ab.TransientGitHubError("GET /x: timeout")

        with patch.object(ab.time, "monotonic", clock), \
                patch.object(ab.Controller, "find_runner_job", return_value=found) as find, \
                patch.object(FakeGitHub, "run", side_effect=unavailable) as read:
            verdict, calls, _ = self.admit({}, [run(id=9)])
        self.assertEqual(verdict, "unattributed")
        find.assert_called_once()
        self.assertEqual(read.call_count, 3)
        self.assertEqual(ab.time.sleep.call_args_list, [unittest.mock.call(2)] * 2)
        self.assertEqual(calls, [], "no unlock without the run's event")
        self.assertEqual(self.state.load()["mode"], "paused")

    def test_admit_run_metadata_arriving_after_deadline_never_unlocks(self):
        clock = Mock(return_value=0)
        found = {"id": 90, "run_id": 9, "runner_name": "mbp2606-s0-90-abc"}

        def late_metadata(*_):
            clock.return_value = ab.ADMISSION_WAIT_SECONDS
            return run(id=9)

        with patch.object(ab.time, "monotonic", clock), \
                patch.object(ab.Controller, "find_runner_job", return_value=found), \
                patch.object(FakeGitHub, "run", side_effect=late_metadata):
            verdict, calls, _ = self.admit({}, [run(id=9)])
        self.assertEqual(verdict, "unattributed")
        self.assertEqual(calls, [])
        self.assertEqual(self.state.load()["mode"], "paused")

    def test_admit_stopping_during_run_metadata_read_never_unlocks(self):
        found = {"id": 90, "run_id": 9, "runner_name": "mbp2606-s0-90-abc"}

        def stop(*_):
            self.state.update(lambda d: d.update(mode="stopping"))
            return run(id=9)

        with patch.object(ab.time, "monotonic", return_value=0), \
                patch.object(ab.Controller, "find_runner_job", return_value=found), \
                patch.object(FakeGitHub, "run", side_effect=stop), \
                patch.object(ab.Controller, "pause") as pause:
            verdict, calls, _ = self.admit({}, [run(id=9)])
        self.assertEqual(verdict, "stopped")
        pause.assert_not_called()
        self.assertEqual(calls, [])
        self.assertEqual(self.state.load()["mode"], "stopping")

    def test_wait_for_runner_retries_a_transient_idle_poll_on_the_next_tick(self):
        gh = FakeGitHub([], {})
        gh.job = Mock(side_effect=[ab.TransientGitHubError("GET /x: disconnected"), {"status": "queued"}])
        ctl = self.controller(gh)
        ctl.cfg = {**self.cfg, "maxJobMinutes": 1}
        ctl.vm_running = Mock(return_value=True)
        ctl.lima = Mock()
        ctl.lima.shell.side_effect = [
            subprocess.CompletedProcess([], 1, "", ""),  # no hook denial
            subprocess.CompletedProcess([], 0, "active\n", ""),
            subprocess.CompletedProcess([], 1, "", ""),  # not admitted
        ] * 2 + [
            subprocess.CompletedProcess([], 1, "", ""),
            subprocess.CompletedProcess([], 0, "inactive\n", ""),
            subprocess.CompletedProcess([], 1, "", ""),
        ]
        with patch.object(ab.time, "sleep") as sleep, patch.object(ab, "log") as log:
            self.assertEqual(ctl.wait_for_runner(0, "aeon-job-0", "runner", {"id": 90}), "idle")
        self.assertEqual(gh.job.call_args_list, [unittest.mock.call(90)] * 2)
        self.assertEqual(sleep.call_args_list, [unittest.mock.call(3)] * 2)
        self.assertEqual(self.state.load()["mode"], "on")
        log.assert_called_once()
        self.assertIn("transient GitHub error polling job 90", log.call_args.args[0])

    def test_wait_for_runner_propagates_stopped_admission_without_pausing(self):
        ctl = self.controller(FakeGitHub([], {}))
        ctl.cfg = {**self.cfg, "maxJobMinutes": 1}
        ctl.vm_running = Mock(return_value=True)
        ctl.lima = Mock()
        ctl.lima.shell.side_effect = [
            subprocess.CompletedProcess([], 1, "", ""),
            subprocess.CompletedProcess([], 0, "active\n", ""),
            subprocess.CompletedProcess([], 0, "", ""),  # admitted
        ]
        ctl.admit = Mock(return_value="stopped")
        ctl.pause = Mock()
        with patch.object(ab.time, "sleep") as sleep:
            self.assertEqual(ctl.wait_for_runner(0, "aeon-job-0", "runner", {"id": 90}), "stopped")
        ctl.admit.assert_called_once()
        ctl.pause.assert_not_called()
        sleep.assert_not_called()

    def test_serve_cleans_up_stopped_admission_without_tainting_the_slot(self):
        r = run(id=9)
        job = {"id": 90, "status": "queued", "labels": ab.mint_labels(CFG, r)}
        gh = FakeGitHub([r], {9: [job]})
        gh.jit = Mock(return_value={"runner": {"id": 123}, "encoded_jit_config": "test-jit"})
        gh.delete_runner = Mock()
        ctl = self.controller(gh)
        ctl.lima = Mock()
        ctl.prepare_disk = Mock(return_value=("aeon-cache-0", False))
        ctl.retire_slot = Mock()
        ctl.wait_for_runner = Mock(return_value="stopped")
        ctl.post_job_check = Mock()
        slot = ctl.claim_slot(job, r)
        ab.Controller.serve(ctl, slot, r, job)
        ctl.post_job_check.assert_not_called()
        self.assertNotIn(slot, ctl.tainted)
        ctl.retire_slot.assert_called_once_with(slot, "aeon-job-0", "aeon-cache-0")
        gh.delete_runner.assert_called_once_with(123)

    def test_admit_non_transient_error_still_propagates_without_unlocking(self):
        jobs = {9: [{"id": 90, "run_id": 9, "runner_name": "", "labels": ["mbp2606"]}]}
        error = ab.BuilderError("GET /x: HTTP 403")
        with patch.object(ab.Controller, "find_runner_job", side_effect=error) as find, \
                patch.object(ab.Controller, "set_slot") as set_slot:
            with self.assertRaisesRegex(ab.BuilderError, "HTTP 403"):
                self.admit(jobs, [run(id=9)])
        find.assert_called_once()
        set_slot.assert_not_called()
        ab.time.sleep.assert_not_called()
        self.assertEqual(self.state.load()["mode"], "on")

    def test_trusted_disk_is_never_unlocked_for_non_push_jobs(self):
        jobs = {9: [{"id": 90, "run_id": 9, "run_attempt": 1, "runner_name": "mbp2606-s0-90-abc", "labels": ["mbp2606"]}]}
        for event in ("workflow_dispatch", "pull_request", "merge_group"):
            with self.subTest(event=event):
                verdict, calls, _ = self.admit(jobs, [run(id=9, event=event)])
                self.assertEqual(verdict, "class-mismatch")
                self.assertEqual(calls, [], "no unlock")
                self.assertEqual(self.state.load()["mode"], "on", "a verified swap is no attack: no pause")

    def test_non_push_jobs_on_scratch_disk_unlock(self):
        self.disk = "aeon-scratch-0"
        jobs = {9: [{"id": 90, "run_id": 9, "run_attempt": 1, "runner_name": "mbp2606-s0-90-abc", "labels": ["mbp2606"]}]}
        for event in ("workflow_dispatch", "pull_request", "merge_group"):
            with self.subTest(event=event):
                verdict, calls, _ = self.admit(jobs, [run(id=9, event=event)])
                self.assertEqual(verdict, "ok")
                self.assertIn("unlock", calls[0][0])

    def test_racing_unverified_job_never_gets_the_key(self):
        jobs = {9: [{"id": 90, "run_id": 9, "runner_name": "", "labels": ["mbp2606"], "status": "queued"}],
                66: [{"id": 660, "run_id": 66, "runner_name": "mbp2606-s0-90-abc", "labels": ["mbp2606"], "status": "in_progress"}]}
        verdict, calls, gh = self.admit(jobs, [run(id=9), run(id=66, event="push", head_branch="work/x")])
        self.assertEqual(verdict, "unverified")
        self.assertEqual(calls, [], "no unlock")
        self.assertEqual(self.state.load()["mode"], "paused")

    def test_rescan_before_mint_cancels_any_unverified_label_job(self):
        jobs = {9: [{"id": 90, "status": "queued", "labels": ["mbp2606", "mbp2606-push"]}],
                5: [{"id": 50, "status": "queued", "labels": ["mbp2606", "mbp2606-push"]}]}
        gh = FakeGitHub([run(id=9), run(id=5, event="push", head_branch="work/x")], jobs)
        ctl = self.controller(gh)
        self.assertEqual(ctl.unverified_label_runs(ab.mint_labels(CFG, run())), [5])
        self.assertEqual(gh.cancelled, [5])
        self.assertIn(9, self.state.load()["verifiedRuns"])

    def test_sweep_catches_jobs_whose_labels_are_a_subset(self):
        labels = CFG["runnerLabels"]
        for runs_on in (["self-hosted"], ["Self-Hosted", "linux"], ["ARM64"], ["self-hosted", "Linux", "ARM64", "mbp2606"]):
            self.assertTrue(ab.could_take({"labels": runs_on}, labels), runs_on)
        for runs_on in (["ubuntu-latest"], ["self-hosted", "macos"]):
            self.assertFalse(ab.could_take({"labels": runs_on}, labels), runs_on)
        for runs_on in ([], None):
            self.assertTrue(ab.could_take({"labels": runs_on}, labels), "missing labels fail closed")
        jobs = {9: [{"id": 90, "status": "queued", "labels": ["mbp2606", "mbp2606-push"]}],
                4: [{"id": 40, "status": "queued", "labels": ["self-hosted"]}],
                3: [{"id": 30, "status": "queued", "labels": ["ubuntu-latest"]}]}
        gh = FakeGitHub([run(id=9), run(id=4, event="pull_request"), run(id=3, event="pull_request")], jobs)
        ctl = self.controller(gh)
        self.assertEqual(ctl.unverified_label_runs(ab.mint_labels(CFG, run())), [4])
        self.assertEqual(gh.cancelled, [4], "hosted PR jobs are left alone")

    def test_mint_labels_carry_exactly_one_class(self):
        for event, label in CFG["classLabels"].items():
            self.assertEqual(ab.mint_labels(CFG, run(event=event)), ["self-hosted", "Linux", "ARM64", "mbp2606", label])

    def test_class_rules(self):
        base = ["self-hosted", "Linux", "ARM64", "mbp2606"]
        for event, label in CFG["classLabels"].items():
            r = run(event=event)
            runner = ab.mint_labels(CFG, r)
            self.assertTrue(ab.class_ok({"labels": base + [label.upper()]}, r, CFG))
            self.assertTrue(ab.could_take({"labels": base + [label.upper()]}, runner))
            self.assertFalse(ab.class_ok({"labels": base}, r, CFG))
            self.assertTrue(ab.could_take({"labels": base}, runner), "base-only jobs still fit, so they are swept")
            for other in set(CFG["classLabels"].values()) - {label}:
                self.assertFalse(ab.class_ok({"labels": base + [other]}, r, CFG))
                self.assertFalse(ab.class_ok({"labels": base + [label, other]}, r, CFG))
                self.assertFalse(ab.could_take({"labels": base + [other]}, runner))

    def test_verified_job_without_its_class_is_cancelled_not_minted(self):
        gh = FakeGitHub([run(id=9)], {9: [{"id": 90, "status": "queued", "labels": ["self-hosted", "Linux", "ARM64", "mbp2606"]}]})
        ctl = self.controller(gh)
        ctl.tick()
        self.assertEqual(self.served, [])
        self.assertEqual(gh.cancelled, [9])

    def test_sweep_cancels_base_only_jobs_of_verified_runs_but_keeps_other_classes(self):
        base = ["self-hosted", "Linux", "ARM64", "mbp2606"]
        jobs = {9: [{"id": 90, "status": "queued", "labels": base + ["mbp2606-push"]}],
                8: [{"id": 80, "status": "queued", "labels": base}],
                7: [{"id": 70, "status": "queued", "labels": base + ["mbp2606-dispatch"]}]}
        gh = FakeGitHub([run(id=9), run(id=8), run(id=7, event="workflow_dispatch")], jobs)
        ctl = self.controller(gh)
        self.assertEqual(ctl.unverified_label_runs(ab.mint_labels(CFG, run())), [8])
        self.assertEqual(gh.cancelled, [8], "the dispatch job cannot take a push runner, so it stays")

    def test_pause_sweeps_every_pool_label(self):
        for label in CFG["classLabels"].values():
            self.assertIn(label, ab.pool_labels(CFG))

    def test_clone_keeps_filesystem_of_copied_disks(self):
        self.assertIn('"format": false', ab.clone_expression(CFG, 1, "aeon-scratch-1", fresh=False))
        self.assertIn('"format": true', ab.clone_expression(CFG, 1, "aeon-cache-1", fresh=True))

if __name__ == "__main__":
    unittest.main()
