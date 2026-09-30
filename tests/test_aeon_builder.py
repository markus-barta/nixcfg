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
    "sshPortBase": 60020,
    "blockedNetworks": ["10.0.0.0/8", "192.168.0.0/16", "100.64.0.0/10", "127.0.0.0/8"],
    "ruleset": {
        "id": 24240960,
        "include": ["~DEFAULT_BRANCH", "refs/heads/main"],
        "ruleTypes": ["deletion", "non_fast_forward", "pull_request", "required_status_checks"],
        "requiredChecks": ["go", "web", "release-check", "e2e"],
        "bypass": [["RepositoryRole", "pull_request"]],
    },
}

LIVE_RULESET = {
    "enforcement": "active",
    "target": "branch",
    "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
    "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request"}],
    "rules": [
        {"type": "deletion"},
        {"type": "non_fast_forward"},
        {"type": "pull_request", "parameters": {"required_approving_review_count": 0}},
        {"type": "required_status_checks", "parameters": {"required_status_checks": [
            {"context": c, "integration_id": 15368} for c in ("go", "web", "release-check", "e2e")]}},
    ],
}


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
    def test_live_ruleset_passes(self):
        self.assertEqual(ab.ruleset_problems(LIVE_RULESET, CFG["ruleset"]), [])

    def test_drift_is_reported(self):
        disabled = dict(LIVE_RULESET, enforcement="disabled")
        self.assertTrue(ab.ruleset_problems(disabled, CFG["ruleset"]))
        fewer = dict(LIVE_RULESET, rules=LIVE_RULESET["rules"][:2])
        self.assertTrue(any("pull_request" in p for p in ab.ruleset_problems(fewer, CFG["ruleset"])))
        bypass = dict(LIVE_RULESET, bypass_actors=[{"actor_type": "Integration", "bypass_mode": "always"}])
        self.assertIn("unexpected bypass actors", ab.ruleset_problems(bypass, CFG["ruleset"]))
        self.assertEqual(ab.ruleset_problems(None, CFG["ruleset"]), ["ruleset missing"])


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
        self.assertIn(".ssh.localPort = 60019", expr)

    def test_clone_uses_slot_port_and_disk(self):
        expr = ab.clone_expression(CFG, 2, "aeon-cache-2")
        self.assertIn(".ssh.localPort = 60022", expr)
        self.assertIn('"name": "aeon-cache-2"', expr)
        self.assertIn(".additionalDisks = []", ab.clone_expression(CFG, 0, None))

    def test_pf_rules_block_private_ranges_for_ci_only(self):
        rules = ab.pf_rules(CFG, "ci")
        self.assertIn("block return out quick from any to <aeon_private> user ci", rules)
        self.assertIn("port 60019:60023 user ci", rules)
        self.assertIn("100.64.0.0/10", rules)
        self.assertLess(rules.index("pass out quick on lo0"), rules.index("block return"))

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

    def hook(self, payload=None, **env):
        event = self.tmp / "event.json"
        event.write_text(json.dumps(payload if payload is not None else {"repository": {"full_name": REPO}}))
        base = {
            "PATH": os.environ["PATH"],
            "AEON_ALLOWLIST": str(self.tmp / "allow.json"),
            "AEON_HOOK_LOG": str(self.log),
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

    def test_allowed_job_passes_and_is_logged(self):
        proc = self.hook()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("aeon-hook allow run=42", self.log.read_text())

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
                self.assertNotEqual(self.hook(**env).returncode, 0)
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

    def test_post_job_check_pauses_on_foreign_run(self):
        ctl = self.controller(FakeGitHub([], {}))
        self.state.update(lambda d: d["verifiedRuns"].append(9))

        class Lima:
            def shell(self, vm, cmd, check=True):
                return subprocess.CompletedProcess([], 0, "aeon-hook allow run=666 attempt=1 job=go event=push sha=x\n", "")
        ctl.lima = Lima()
        ctl.post_job_check(0, "aeon-job-0")
        self.assertEqual(self.state.load()["mode"], "paused")


if __name__ == "__main__":
    unittest.main()
