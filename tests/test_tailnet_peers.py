"""OPS-384 offline fixtures exercise the real sync transaction and alert retry."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("peer_sync", ROOT / "modules/tailnet-peers/sync.py")
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class Admission(unittest.TestCase):
    def setUp(self):
        (ROOT / "tests/.tmp").mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=ROOT / "tests/.tmp")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.status = (ROOT / "tests/fixtures/tailnet-peers/joined.json").read_text()
        self.calls, self.alerts = [], []
        self.reject_restore = self.reject_probe = self.relay_down = False
        self.count = 0
        self.installed = ""
        self.cfg = dict(tailscale="tailscale", restore="restore", iptables="iptables", save="save",
                        docker="docker", rules=[dict(tag="tag:paper-desk", host="grok-amy-box", identity="amy")],
                        reserved=["100.64.0.14"], staleSeconds=300, address="100.64.0.6")

    def fixture(self, name):
        self.status = (ROOT / f"tests/fixtures/tailnet-peers/{name}.json").read_text()

    def step(self, now=1000):
        def command(args, data=None):
            self.calls.append((args, data))
            if args[0] == "tailscale":
                if isinstance(self.status, Exception):
                    raise self.status
                return self.status
            if args[0] == "restore" and self.reject_restore:
                raise subprocess.CalledProcessError(1, args)
            if args[0] == "restore" and "--test" not in args:
                self.installed = data
            if args[0] == "save":
                rules = self.installed
                for prefix, port in sync.CHAINS:
                    rules += f"\n-A {prefix}-peers -j {prefix}-dyn"
                    rules += f"\n-A PREROUTING -d 100.64.0.6/32 -i tailscale0 -p tcp -m tcp --dport {port} -j {prefix}-peers"
                    rules += f"\n-A nixos-fw -j {prefix}-dyn-fw"
                if self.reject_probe:
                    rules = rules.replace("-j ACCEPT", "-j DROP")
                return rules + "\n" + "\n".join(f'[{self.count}:64] -A {prefix}-peers -s 100.64.0.0/10 -m comment --comment "tailnet-refused-{port}" -j DROP'
                                 for prefix, port in sync.CHAINS)
            return ""
        def deliver(message, identifier):
            self.alerts.append(message)
            return not self.relay_down
        with patch.object(sync, "run", command), contextlib.redirect_stdout(io.StringIO()):
            sync.synchronize(self.cfg, self.root, self.root / "lock", now, deliver)

    def peers(self):
        return json.loads((self.root / "peers.json").read_text())["peers"]

    def test_rejoin_replaces_address_and_scopes_atomic_restore(self):
        self.step()
        self.assertEqual(self.peers(), {"100.64.0.15": "amy"})
        self.fixture("rejoined")
        self.step(1030)
        self.assertEqual(self.peers(), {"100.64.0.23": "amy"})
        restore = [data for args, data in self.calls if args[0] == "restore"][-1]
        self.assertIn("-A paper-desk-dyn -s 100.64.0.23 -j ACCEPT", restore)
        self.assertIn("-A agent-mailbox-dyn -s 100.64.0.23 -j ACCEPT", restore)
        self.assertNotIn("100.64.0.15", restore)
        self.assertNotIn("-F PREROUTING", restore)
        self.assertNotIn("-F nixos-fw\n", restore)
        for args, _ in self.calls:
            if args[0] == "restore":
                self.assertIn("--noflush", args)
        self.assertEqual((self.root / "peers.json").stat().st_mode & 0o777, 0o644)
        self.assertEqual((self.root / "state.json").stat().st_mode & 0o777, 0o600)

    def test_tag_removed_is_dropped_immediately(self):
        self.step()
        self.fixture("untagged")
        self.step(1030)
        self.assertEqual(self.peers(), {})

    def test_null_tags_revoke_like_an_empty_tag_list(self):
        self.step()
        value = json.loads(self.status)
        value["Peer"]["node-a"]["Tags"] = None
        self.status = json.dumps(value)
        self.step(1030)
        self.assertEqual(self.peers(), {})

    def test_two_tagged_nodes_and_optional_hostname(self):
        self.cfg["rules"][0]["host"] = None
        self.fixture("two")
        self.step()
        self.assertEqual(self.peers(), {"100.64.0.23": "amy", "100.64.0.25": "amy"})
        self.cfg["rules"][0]["host"] = "grok-amy-box"
        self.step(1030)
        self.assertEqual(self.peers(), {"100.64.0.23": "amy"})

    def test_errors_keep_last_good_and_alert_after_two_minutes(self):
        for index, bad in enumerate([subprocess.CalledProcessError(1, "tailscale"), "{broken", '{"BackendState":"Stopped","Peer":{}}',
                    '{"BackendState":"Running","Peer":[]}']):
            with self.subTest(bad=type(bad).__name__):
                base = 1000 + index * 2000
                self.status = (ROOT / "tests/fixtures/tailnet-peers/joined.json").read_text()
                self.step(base)
                self.alerts.clear()
                self.status = bad
                self.step(base + 30)
                self.step(base + 151)
                self.assertEqual(self.peers(), {"100.64.0.15": "amy"})
                self.assertTrue(any("two minutes" in m for m in self.alerts))
                self.step(base + 1000)
                self.assertEqual(self.peers(), {"100.64.0.15": "amy"})

    def test_empty_view_kept_and_alerted_then_absent_node_expires(self):
        self.step()
        self.fixture("empty")
        self.step(1030)
        self.assertEqual(self.peers(), {"100.64.0.15": "amy"})
        self.assertTrue(any("retaining" in m for m in self.alerts))
        self.step(1301)
        self.assertEqual(self.peers(), {})

    def test_missing_node_expires_while_other_tagged_node_remains(self):
        self.cfg["rules"][0]["host"] = None
        self.fixture("two")
        self.step()
        value = json.loads(self.status)
        del value["Peer"]["node-c"]
        self.status = json.dumps(value)
        self.step(1030)
        self.assertEqual(len(self.peers()), 2)
        self.step(1301)
        self.assertEqual(self.peers(), {"100.64.0.23": "amy"})

    def test_reserved_address_and_malformed_peer_never_admitted(self):
        for address in ["100.64.0.14", "192.0.2.1", "broken"]:
            value = json.loads(self.status)
            value["Peer"]["node-a"]["TailscaleIPs"] = [address]
            self.status = json.dumps(value)
            self.step(1030)
            self.assertEqual(self.peers(), {})
            self.assertTrue(any("skipped" in m for m in self.alerts))
            self.fixture("joined")

    def test_bad_peer_does_not_freeze_other_peer_admission_or_revocation(self):
        for bad in [None, {"Tags": "tag:paper-desk"},
                    {"HostName": "unsafe\nvalue", "TailscaleIPs": ["100.64.0.25"]},
                    {"HostName": "grok-amy-box", "TailscaleIPs": None},
                    {"HostName": "grok-amy-box", "TailscaleIPs": ["fd7a:115c:a1e0::1"]},
                    {"HostName": "grok-amy-box", "TailscaleIPs": ["broken"]},
                    {"HostName": "grok-amy-box", "TailscaleIPs": ["100.64.0.14"]}]:
            with self.subTest(bad=bad):
                self.fixture("joined")
                value = json.loads(self.status)
                value["Peer"]["node-b"] = None if bad is None else dict(bad)
                if isinstance(value["Peer"]["node-b"], dict):
                    value["Peer"]["node-b"].setdefault("Tags", ["tag:paper-desk"])
                self.status = json.dumps(value)
                self.step()
                self.assertEqual(self.peers(), {"100.64.0.15": "amy"})
                value["Peer"]["node-a"]["Tags"] = []
                self.status = json.dumps(value)
                self.step(1030)
                self.assertEqual(self.peers(), {})
                self.assertTrue(any("skipped" in m for m in self.alerts))

    def test_node_set_changes_notify_without_addresses_and_deduplicate(self):
        self.step()
        self.assertTrue(any("node set changed" in m for m in self.alerts))
        self.alerts.clear()
        self.step(1030)
        self.assertEqual(self.alerts, [])
        self.fixture("rejoined")
        self.step(1060)
        self.assertTrue(any("node set changed" in m for m in self.alerts))
        self.assertFalse(any("100.64." in m or "node-a" in m for m in self.alerts))
        self.cfg["rules"][0]["host"] = None
        self.fixture("two")
        self.alerts.clear()
        self.step(1090)
        self.assertTrue(any("2 admitted nodes match one" in m for m in self.alerts))

    def test_corrupt_or_unreadable_state_alerts_without_touching_admission(self):
        self.step()
        good = self.peers()
        for invalid in ["{broken", "[]", '{"rows":{"100.64.0.15":{}}}']:
            (self.root / "state.json").write_text(invalid)
            self.alerts.clear()
            self.step(1030)
            self.assertEqual(self.peers(), good)
            self.assertTrue(any("crashed" in m for m in self.alerts))
        with patch.object(Path, "read_text", side_effect=PermissionError):
            self.step(1060)
        self.assertTrue(any("crashed" in m for m in self.alerts))

    def test_state_write_failure_and_snapshot_keyerror_alert(self):
        self.step()
        original = sync.atomic_json
        def fail_state(path, value, mode):
            if path.name == "state.json":
                raise OSError("private test detail must not reach alerts")
            original(path, value, mode)
        with patch.object(sync, "atomic_json", fail_state):
            self.step(1030)
        self.assertTrue(any("crashed" in m for m in self.alerts))
        self.alerts.clear()
        with patch.object(sync, "snapshot", side_effect=KeyError("private detail")):
            self.step(1060)
        self.assertTrue(any("sync failed" in m for m in self.alerts))
        self.assertFalse(any("private" in m for m in self.alerts))

    def test_rejoin_with_absent_old_node_revokes_old_address(self):
        self.step()
        self.fixture("rejoined")
        value = json.loads(self.status)
        del value["Peer"]["node-a"]
        self.status = json.dumps(value)
        self.step(1030)
        self.assertEqual(self.peers(), {"100.64.0.23": "amy"})

    def test_old_address_reused_by_untagged_node_is_not_retained(self):
        self.step()
        value = json.loads(self.status)
        value["Peer"]["node-new"] = value["Peer"].pop("node-a")
        value["Peer"]["node-new"]["Tags"] = []
        self.status = json.dumps(value)
        self.step(1030)
        self.assertEqual(self.peers(), {})

    def test_online_tagged_node_with_unmapped_hostname_is_refused_and_alerted(self):
        self.fixture("two")
        self.step()
        self.assertEqual(self.peers(), {"100.64.0.23": "amy"})
        self.assertTrue(any("desk-two:8470/8471 online" in m for m in self.alerts))

    def test_restore_failure_does_not_publish_and_online_not_admitted_alerts(self):
        self.step()
        self.fixture("rejoined")
        self.reject_restore = True
        self.step(1030)
        self.assertEqual(self.peers(), {"100.64.0.15": "amy"})
        self.assertTrue(any("grok-amy-box:8470/8471 online" in m for m in self.alerts))

    def test_installed_admission_probe_failure_alerts(self):
        self.reject_probe = True
        self.step()
        self.assertTrue(any("not admitted" in m for m in self.alerts))
        self.step(1121)
        self.assertTrue(any("two minutes" in m for m in self.alerts))

    def test_refusal_counter_alert_persists_and_retries_failed_relay(self):
        self.step()
        self.count = 5
        self.relay_down = True
        self.step(1030)
        self.assertTrue(any("hsb0:8470 refused" in m for m in self.alerts))
        state = json.loads((self.root / "state.json").read_text())
        self.assertTrue(state["pending"])
        self.relay_down = False
        self.alerts.clear()
        self.step(1060)
        self.assertTrue(any("hsb0:8471 refused" in m for m in self.alerts))
        self.assertEqual(json.loads((self.root / "state.json").read_text())["pending"], {})
        self.alerts.clear()
        self.step(1090)
        self.assertEqual(self.alerts, [])


if __name__ == "__main__":
    unittest.main()
