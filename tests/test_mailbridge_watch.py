"""Mail integrity and secret-safe failure tests; no live accounts or network."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import types
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("engine", ROOT / "modules/shared/fleet-alerts/engine.py")
engine = importlib.util.module_from_spec(SPEC)
sys.modules["engine"] = engine
SPEC.loader.exec_module(engine)


def load(relative, replacements):
    source = (ROOT / relative).read_text()
    for key, value in replacements.items():
        source = source.replace(f"@{key}@", value)
    module = types.ModuleType("checks")
    exec(compile(source, str(ROOT / relative), "exec"), module.__dict__)
    return module


checks = load("hosts/hsb1/mailbridge-watch.py", {
    "CONFIG": "/not-a-real-config", "NOTIFICATION_ENV": "/not-a-real-notification",
    "DOCKER": "/not-a-real-docker", "CA_BUNDLE": "", "GRANT_ISSUED_AT": "",
})
witness = load("modules/shared/fleet-alerts/tailnet-watch-checks.py", {
    "MONITOR_STATUS": "/not-a-real-status", "HOSTNAME": "hsb1",
    "NOTIFICATION_ENV": "", "TAILSCALE_BIN": "",
})
CFG = {"client": {"client_id": "fixture-client", "client_secret": "fixture-secret"},
       "tokens": {"refresh_token": "fixture-refresh"}, "accounts": []}
STAMP = 1800000000


class OAuthTest(unittest.TestCase):
    def probe(self, result=None, error=None):
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=None)
        response.read.return_value = json.dumps(result).encode()
        opener = Mock()
        opener.open.side_effect = error
        opener.open.return_value = response
        with patch.object(checks.ssl, "create_default_context"), patch.object(checks.urllib.request, "build_opener", return_value=opener):
            return checks.oauth_probe(CFG), opener

    def test_valid_refresh_uses_fixed_endpoint_and_does_not_write(self):
        status, opener = self.probe({"access_token": "fixture-access", "token_type": "Bearer", "expires_in": 3600})
        self.assertEqual(status, "ok")
        self.assertEqual(opener.open.call_args.args[0].full_url, "https://oauth2.googleapis.com/token")
        self.assertEqual(CFG["tokens"], {"refresh_token": "fixture-refresh"})

    def test_invalid_grant_does_not_include_provider_description(self):
        err = urllib.error.HTTPError("https://example.invalid/fixture-secret", 400, "fixture-secret", {}, io.BytesIO(b'{"error":"invalid_grant","error_description":"fixture-secret"}'))
        status, _ = self.probe(error=err)
        self.assertEqual(status, "invalid_grant")

    def test_rate_limit_and_server_errors_are_transient(self):
        for code in (429, 500, 503):
            with self.subTest(code=code):
                err = urllib.error.HTTPError("https://example.invalid", code, "fixture-secret", {}, io.BytesIO())
                self.assertEqual(self.probe(error=err)[0], "transient_http")

    def test_transport_exception_is_never_printed(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            status, _ = self.probe(error=RuntimeError("fixture-secret"))
        self.assertEqual(status, "transport_or_response_error")
        self.assertEqual(out.getvalue(), "")

    def test_incomplete_success_or_rotated_refresh_cannot_be_green(self):
        self.assertEqual(self.probe({"access_token": "fixture-access"})[0], "invalid_response")
        self.assertEqual(self.probe({"access_token": "fixture-access", "expires_in": 3600, "token_type": "Bearer", "refresh_token": "new-fixture"})[0], "credential_rotation_required")

    def test_redirect_does_not_forward_credentials(self):
        self.assertIsNone(checks.NoRedirect().redirect_request(None, None, 307, "", {}, "https://example.invalid"))


class QueueTest(unittest.TestCase):
    def test_defaults_match_pinned_upstream(self):
        self.assertEqual(checks.mapped_folders({}), {"INBOX": False, "Junk": False})

    def test_unreadable_folder_never_looks_empty(self):
        client = Mock()
        client.status.return_value = ("NO", [b"fixture-provider-error"])
        account = {"Username": "fixture-user", "Password": "fixture-password", "Folders": {"INBOX": []}}
        with patch.object(checks.ssl, "create_default_context"), patch.object(checks.imaplib, "IMAP4_SSL", return_value=client):
            _, counts = checks.mailbox_counts({"accounts": [account]})
            self.assertIsNone(counts["a0f0"]["count"])
        client.logout.assert_called_once()

    def test_all_mapped_source_and_failed_folders_are_observed(self):
        account = {"Username": "fixture-user", "Password": "fixture-password", "Folders": {"INBOX": [], "ArchiveSource": []}, "FailedFolders": {"*": "Failed"}}
        client = Mock()
        client.status.return_value = ("OK", [b'"box" (MESSAGES 3)'])
        with patch.object(checks.ssl, "create_default_context"), patch.object(checks.imaplib, "IMAP4_SSL", return_value=client):
            _, counts = checks.mailbox_counts({"accounts": [account]})
        self.assertEqual(len(counts), 3)
        self.assertEqual(sum(v["failed_folder"] for v in counts.values()), 1)
        self.assertEqual([c.args[0] for c in client.status.call_args_list], ['"ArchiveSource"', '"Failed"', '"INBOX"'])
        self.assertEqual({c[0] for c in client.method_calls}, {"login", "status", "logout"})

    def test_one_failed_folder_does_not_blind_source_queue(self):
        account = {"Username": "fixture-user", "Password": "fixture-password", "Folders": {"INBOX": []}, "FailedFolders": {"*": "Failed"}}
        client = Mock()
        client.status.side_effect = [("NO", [b"unknown"]), ("OK", [b'"INBOX" (MESSAGES 20)'])]
        with patch.object(checks.ssl, "create_default_context"), patch.object(checks.imaplib, "IMAP4_SSL", return_value=client):
            _, counts = checks.mailbox_counts({"accounts": [account]})
        self.assertIsNone(counts["a0f0"]["count"])
        self.assertEqual(counts["a0f1"]["count"], 20)
        saved, problems = checks.queue_problems(counts, {}, 1000)
        self.assertEqual([p.key for p in problems], ["mailbridge:imap:a0f0"])
        _, problems = checks.queue_problems(counts, saved, 9000)
        self.assertIn("mailbridge:queue:a0f1", [p.key for p in problems])

    def test_batch_queue_is_not_stalled_for_first_two_hours(self):
        current = {"a0f0": {"count": 1000, "failed_folder": False}}
        prior, problems = checks.queue_problems(current, {}, 1000)
        self.assertFalse(problems)
        _, problems = checks.queue_problems(current, prior, 1000 + 7199)
        self.assertFalse(problems)
        _, problems = checks.queue_problems(current, prior, 1000 + 7200)
        self.assertEqual(problems[0].key, "mailbridge:queue:a0f0")

    def test_growing_queue_alerts_but_decrease_restarts_window(self):
        old = {"a0f0": {"count": 10, "since": 1000}}
        current = {"a0f0": {"count": 20, "failed_folder": False}}
        _, problems = checks.queue_problems(current, old, 9000)
        self.assertTrue(problems)
        current["a0f0"]["count"] = 5
        state, problems = checks.queue_problems(current, old, 9000)
        self.assertFalse(problems)
        self.assertEqual(state["a0f0"]["since"], 9000)

    def test_failed_folder_is_actionable_without_stall_delay(self):
        _, problems = checks.queue_problems({"f": {"count": 1, "failed_folder": True}}, {}, 1000)
        self.assertEqual(problems[0].key, "mailbridge:failed:f")


class ObserveTest(unittest.TestCase):
    def observe(self, **kwargs):
        defaults = {"auth": "ok", "bridge": {"state": "running", "import_errors": 0}, "imap": ("mapping", {})}
        defaults.update(kwargs)
        with patch.object(checks, "load_config", return_value=CFG), patch.object(checks, "oauth_probe", return_value=defaults["auth"]), patch.object(checks, "bridge_probe", return_value=defaults["bridge"]), patch.object(checks, "mailbox_counts", return_value=defaults["imap"]):
            return checks.observe(STAMP, {})

    def test_running_container_and_auth_do_not_hide_import_failures(self):
        _, problems = self.observe(bridge={"state": "running", "import_errors": 2})
        self.assertIn("mailbridge:imports", [p.key for p in problems])

    def test_unknown_production_grant_does_not_pass_day8(self):
        snapshot, problems = self.observe()
        self.assertIsNone(snapshot["day8_verified_at"])
        self.assertIn("mailbridge:publication", [p.key for p in problems])

    def test_day8_uses_recorded_issuance_and_requires_current_health(self):
        issued = checks.dt.datetime.fromtimestamp(STAMP - 8 * 86400, checks.dt.timezone.utc).isoformat()
        with patch.object(checks, "GRANT_ISSUED_AT", issued):
            snapshot, problems = self.observe()
            self.assertFalse(problems)
            self.assertEqual(snapshot["day8_verified_at"], STAMP)
            snapshot, _ = self.observe(auth="invalid_grant")
            self.assertIsNone(snapshot["day8_verified_at"])

    def test_imap_outage_preserves_stall_clock_and_known_failure(self):
        prior = {"mapping": "mapping", "queue": {"f": {"count": 2, "since": STAMP - 8000, "failed_folder": True}}}
        with patch.object(checks, "load_config", return_value=CFG), patch.object(checks, "oauth_probe", return_value="ok"), patch.object(checks, "bridge_probe", return_value={"state": "running", "import_errors": 0}), patch.object(checks, "mailbox_counts", side_effect=RuntimeError("fixture-secret")):
            snapshot, problems = checks.observe(STAMP, prior)
        self.assertFalse(snapshot["complete"])
        self.assertEqual(snapshot["queue"]["f"]["count"], prior["queue"]["f"]["count"])
        self.assertEqual(snapshot["queue"]["f"]["since"], prior["queue"]["f"]["since"])
        self.assertIn("mailbridge:failed:f", [p.key for p in problems])
        self.assertIn("mailbridge:imap", [p.key for p in problems])
        self.assertNotIn("fixture-secret", repr(snapshot) + repr(problems))

    def test_day8_evidence_survives_later_failure_for_same_grant(self):
        issued = checks.dt.datetime.fromtimestamp(STAMP - 9 * 86400, checks.dt.timezone.utc).isoformat()
        prior = {"grant_issued_at": STAMP - 9 * 86400, "day8_verified_at": STAMP - 500}
        with patch.object(checks, "GRANT_ISSUED_AT", issued), patch.object(checks, "load_config", return_value=CFG), patch.object(checks, "oauth_probe", return_value="invalid_grant"), patch.object(checks, "bridge_probe", return_value={"state": "running", "import_errors": 0}), patch.object(checks, "mailbox_counts", return_value=("mapping", {})):
            snapshot, problems = checks.observe(STAMP, prior)
        self.assertEqual(snapshot["day8_verified_at"], STAMP - 500)
        self.assertFalse(snapshot["day8_check_ok"])
        self.assertIn("mailbridge:oauth:invalid_grant", [p.key for p in problems])

    def test_day8_waits_for_empty_queues(self):
        issued = checks.dt.datetime.fromtimestamp(STAMP - 8 * 86400, checks.dt.timezone.utc).isoformat()
        with patch.object(checks, "GRANT_ISSUED_AT", issued):
            snapshot, _ = self.observe(imap=("mapping", {"f": {"count": 1, "failed_folder": False}}))
        self.assertIsNone(snapshot["day8_verified_at"])

    def test_bad_config_does_not_leak_and_is_not_complete(self):
        with patch.object(checks, "load_config", side_effect=ValueError("fixture-secret")):
            snapshot, problems = checks.observe(STAMP, {})
        self.assertFalse(snapshot["complete"])
        self.assertNotIn("fixture-secret", repr(snapshot) + repr(problems))


class DeliveryTest(unittest.TestCase):
    def test_real_engine_retries_failed_delivery_then_clears(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = str(Path(tmp) / "alerts.json")
            problem = [engine.Problem("mailbridge:oauth", "auth failed")]
            sent = []
            sender = lambda text, _: sent.append(text) or False
            engine.run_cycle(state, 100, lambda: problem, checks.render, sender)
            self.assertEqual(sent, [])
            self.assertEqual(engine.run_cycle(state, 400, lambda: problem, checks.render, sender), 2)
            self.assertIsNotNone(engine.load_state(state)["pending"])
            delivered = []
            sender = lambda text, _: delivered.append(text) or True
            self.assertEqual(engine.run_cycle(state, 700, lambda: [], checks.render, sender), 0)
            self.assertEqual(len(delivered), 2)
            self.assertIn("Cleared:", delivered[1])
            self.assertIsNone(engine.load_state(state)["pending"])

    def test_stale_monitor_pages_even_when_incomplete_is_already_announced(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(witness, "MONITOR_STATUS", str(Path(tmp) / "status.json")), patch.object(witness.time, "time", return_value=10000):
            path = Path(tmp) / "status.json"
            path.write_text(json.dumps({"checked_at": 10000, "delivery": "ok", "complete": False}))
            state_path = str(Path(tmp) / "alerts.json")
            sent = []
            sender = lambda text, _: sent.append(text) or True
            engine.run_cycle(state_path, 10000, witness.check_monitor, checks.render, sender)
            engine.run_cycle(state_path, 10001, witness.check_monitor, checks.render, sender)
            self.assertEqual(len(sent), 1)
            path.write_text(json.dumps({"checked_at": 1, "delivery": "ok", "complete": False}))
            engine.run_cycle(state_path, 10002, witness.check_monitor, checks.render, sender)
            engine.run_cycle(state_path, 10003, witness.check_monitor, checks.render, sender)
            self.assertEqual(len(sent), 2)
            self.assertIn("stale", sent[-1])

    def test_independent_witness_rejects_missing_stale_or_undelivered_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(witness, "MONITOR_STATUS", str(Path(tmp) / "status.json")), patch.object(witness.time, "time", return_value=10000):
            path = Path(tmp) / "status.json"
            self.assertTrue(witness.check_monitor())
            for status in ({"checked_at": 10001, "delivery": "ok", "complete": True}, {"checked_at": 1, "delivery": "ok", "complete": True}, {"checked_at": 10000, "delivery": "failed", "complete": True}, {"checked_at": 10000, "delivery": "ok", "complete": False}):
                path.write_text(json.dumps(status))
                self.assertTrue(witness.check_monitor())
            path.write_text(json.dumps({"checked_at": 10000, "delivery": "ok", "complete": True}))
            self.assertFalse(witness.check_monitor())


if __name__ == "__main__":
    unittest.main()
