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
    "events": ["push", "workflow_dispatch"],
    "workflows": [".github/workflows/ci.yml", ".github/workflows/test-runner-smoke.yml"],
    "branch": "main",
    "cacheWriteEvents": ["push"],
    "slots": 4,
    "slotCpus": 4,
    "slotMemoryGiB": 7,
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

    def test_same_repo_pull_request_is_rejected(self):
        self.assertFalse(self.verify(run(event="pull_request"))[0])
        self.assertFalse(self.verify(run(event="pull_request_target"))[0])

    def test_merge_group_schedule_and_other_workflows_are_rejected(self):
        self.assertFalse(self.verify(run(event="merge_group"))[0])
        self.assertFalse(self.verify(run(event="schedule"))[0])
        self.assertFalse(self.verify(run(path=".github/workflows/release.yml"))[0])

    def test_branch_and_reachability(self):
        self.assertFalse(self.verify(run(head_branch="work/x"))[0])
        self.assertFalse(self.verify(run(), on_branch=False)[0])

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
        self.assertFalse(ab.uses_cache_disk(run(event="workflow_dispatch"), CFG))


class RulesetTests(unittest.TestCase):
    def expected(self):
        return CFG["ruleset"]["expected"]

    def test_pinned_ruleset_covers_the_contract(self):
        pinned = self.expected()
        self.assertEqual(pinned["enforcement"], "active")
        types = {r["type"] for r in pinned["rules"]}
        self.assertLessEqual({"deletion", "non_fast_forward", "pull_request", "required_status_checks"}, types)
        checks = next(r for r in pinned["rules"] if r["type"] == "required_status_checks")["parameters"]
        self.assertLessEqual({"go", "web", "release-check", "e2e"}, {c["context"] for c in checks["required_status_checks"]})

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
    def test_availability_record_matches_schema_1(self):
        import datetime as dt
        now = dt.datetime(2026, 9, 30, 10, 0, tzinfo=dt.timezone.utc)
        rec = ab.availability_record(CFG, 3, now)
        self.assertEqual(rec, {"schema": 1, "repository": REPO, "os": "linux", "arch": "arm64", "online": True,
                               "busy": False, "observed_at": "2026-09-30T10:00:00Z", "idle_runners": 3})
        self.assertTrue(ab.availability_record(CFG, 0, now)["busy"])
        self.assertEqual(ab.availability_record(CFG, -1, now)["idle_runners"], 0)

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

    def test_admitted_job_without_controller_confirmation_is_killed(self):
        proc = self.hook()
        self.assertEqual(proc.returncode, 97, "deny path (kill + poweroff in the VM)")
        self.assertIn("did not confirm admission", self.log.read_text())

    def test_deny_path_kills_and_powers_off_before_returning(self):
        text = (ROOT / "modules/aeon-builder/job-started.sh").read_text()
        deny = text[text.index("deny() {"):text.index("\n}\n", text.index("deny() {"))]
        self.assertLess(deny.index("pkill -9"), deny.index("poweroff -ff"))
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
        gh = FakeGitHub([fork], {7: [{"id": 70, "status": "queued", "labels": ["self-hosted", "mbp2606"]}]})
        ctl = self.controller(gh)
        ctl.tick()
        self.assertEqual(gh.cancelled, [7])
        self.assertEqual(self.served, [])
        ctl.tick()
        self.assertEqual(gh.cancelled, [7], "cancel once")

    def test_verified_jobs_get_slots_and_availability_counts_down(self):
        jobs = [{"id": 900 + i, "status": "queued", "labels": ["self-hosted", "Linux", "ARM64", "mbp2606"]} for i in range(5)]
        gh = FakeGitHub([run(id=9)], {9: jobs})
        ctl = self.controller(gh)
        ctl.tick()
        self.assertEqual(sorted(s for s, _, _ in self.served), [0, 1, 2, 3])
        self.assertEqual(gh.published[-1]["idle_runners"], 0)
        self.assertTrue(gh.published[-1]["busy"])

    def test_hosted_jobs_are_ignored(self):
        gh = FakeGitHub([run(id=9)], {9: [{"id": 1, "status": "queued", "labels": ["ubuntu-latest"]}]})
        ctl = self.controller(gh)
        ctl.tick()
        self.assertEqual(self.served, [])
        self.assertEqual(gh.published[-1]["idle_runners"], 4)

    def test_off_publishes_nothing_and_drain_ends_off(self):
        gh = FakeGitHub([], {})
        ctl = self.controller(gh)
        self.state.update(lambda d: d.update(mode="draining"))
        self.assertEqual(ctl.tick(), "off")
        self.assertEqual(gh.published, [])
        self.assertEqual(ctl.tick(), "off")

    def test_ruleset_drift_pauses_and_clears(self):
        gh = FakeGitHub([run(id=9)], {9: [{"id": 1, "status": "queued", "labels": ["mbp2606"]}]})
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

    def admit(self, jobs, runs):
        gh = FakeGitHub(runs, jobs)
        ctl = self.controller(gh)
        self.state.update(lambda d: (d["verifiedRuns"].append(9), d["slots"].__setitem__("0", {"jobId": 90})))
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

    def test_racing_unverified_job_never_gets_the_key(self):
        jobs = {9: [{"id": 90, "run_id": 9, "runner_name": "", "labels": ["mbp2606"], "status": "queued"}],
                66: [{"id": 660, "run_id": 66, "runner_name": "mbp2606-s0-90-abc", "labels": ["mbp2606"], "status": "in_progress"}]}
        verdict, calls, gh = self.admit(jobs, [run(id=9), run(id=66, event="push", head_branch="work/x")])
        self.assertEqual(verdict, "unverified")
        self.assertEqual(calls, [], "no unlock")
        self.assertEqual(self.state.load()["mode"], "paused")

    def test_rescan_before_mint_cancels_any_unverified_label_job(self):
        jobs = {9: [{"id": 90, "status": "queued", "labels": ["mbp2606"]}],
                5: [{"id": 50, "status": "queued", "labels": ["mbp2606"]}]}
        gh = FakeGitHub([run(id=9), run(id=5, event="push", head_branch="work/x")], jobs)
        ctl = self.controller(gh)
        self.assertEqual(ctl.unverified_label_runs(), [5])
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
        jobs = {9: [{"id": 90, "status": "queued", "labels": ["mbp2606"]}],
                4: [{"id": 40, "status": "queued", "labels": ["self-hosted"]}],
                3: [{"id": 30, "status": "queued", "labels": ["ubuntu-latest"]}]}
        gh = FakeGitHub([run(id=9), run(id=4, event="pull_request"), run(id=3, event="pull_request")], jobs)
        ctl = self.controller(gh)
        self.assertEqual(ctl.unverified_label_runs(), [4])
        self.assertEqual(gh.cancelled, [4], "hosted PR jobs are left alone")

    def test_clone_keeps_filesystem_of_copied_disks(self):
        self.assertIn('"format": false', ab.clone_expression(CFG, 1, "aeon-scratch-1", fresh=False))
        self.assertIn('"format": true', ab.clone_expression(CFG, 1, "aeon-cache-1", fresh=True))

if __name__ == "__main__":
    unittest.main()
