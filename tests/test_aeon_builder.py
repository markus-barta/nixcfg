"""NIX-600: mode-B admission, the job-started hook, pf rules and the controller loop."""

import importlib.util
import json
import os
import shutil
import subprocess
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
        }''' % json.dumps(str(ROOT))
        proc = subprocess.run(["nix-instantiate", "--eval", "--strict", "--json", "--expr", expr],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        cfg = json.loads(proc.stdout)
        self.assertTrue(cfg.pop("enable"))
        self.assertEqual(cfg, {key: CFG[key] for key in cfg})


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
        self._log = ab.log
        ab.log = lambda message: None
        self.addCleanup(setattr, ab, "log", self._log)

    def controller(self, gh):
        ctl = ab.Controller(CFG, gh=gh, lima=object(), state=self.state)
        self.served = []
        gate = threading.Event()

        def serve(slot, r, job):
            self.served.append((slot, r["id"], job["id"]))
            gate.wait(2)
        ctl.serve = serve
        self.addCleanup(gate.set)
        return ctl

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
        ctl.tick()
        self.assertEqual(sorted(self.served), [(i, i + 1, (i + 1) * 10) for i in range(4)])
        self.assertEqual(gh.cancelled, [])
        self.assertTrue(ctl.publish_once())
        self.assertEqual(gh.published[-1]["idle_runners"], 0)

    def test_jit_registration_uses_labels_matching_each_event_job(self):
        for event in CFG["events"]:
            with self.subTest(event=event):
                r = run(id=9, event=event, head_branch="work/x" if event in ("pull_request", "merge_group") else "main")
                labels = CFG["runnerLabels"] + [CFG["classLabels"][event]]
                job = {"id": 90, "status": "queued", "labels": labels}
                gh = FakeGitHub([r], {9: [job]})
                gh.jit = Mock(return_value={"runner": {"id": 123}, "encoded_jit_config": "test-jit"})
                gh.delete_runner = Mock()
                ctl = ab.Controller(CFG, gh=gh, lima=Mock(), state=self.state)
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
                ctl = ab.Controller(CFG, gh=FakeGitHub([], {}), lima=lima, state=self.state)
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
        ab.urllib.request.urlopen = lambda *a, **k: (_ for _ in ()).throw(urllib.error.URLError("dns"))
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
        real = ab.urllib.request.urlopen
        ab.urllib.request.urlopen = lambda *a, **k: (_ for _ in ()).throw(http.client.IncompleteRead(b"x"))
        self.addCleanup(setattr, ab.urllib.request, "urlopen", real)
        with self.assertRaises(ab.BuilderError):
            gh._raw("GET", "/x", bearer="t")

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
        ab.time.sleep = lambda s: None
        self.addCleanup(setattr, ab.time, "sleep", sleep)
        return ctl.admit(0, "aeon-job-0", "mbp2606-s0-90-abc", {"id": 90}), calls, gh

    def test_cache_unlocks_only_after_api_attribution_to_a_verified_run(self):
        jobs = {9: [{"id": 90, "run_id": 9, "run_attempt": 1, "runner_name": "mbp2606-s0-90-abc", "labels": ["mbp2606"]}]}
        verdict, calls, _ = self.admit(jobs, [run(id=9)])
        self.assertEqual(verdict, "ok")
        self.assertIn("unlock", calls[0][0])
        self.assertNotIn("--init", calls[0][0], "an existing disk is never re-initialised")
        self.assertEqual(calls[0][1], "k" * 128)

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
