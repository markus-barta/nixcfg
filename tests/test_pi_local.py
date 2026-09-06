"""Launcher behavior without loading a GPU model or needing macOS."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "hosts/mbp2607/files/pi-local.py"
SPEC = importlib.util.spec_from_file_location("pi_local", SOURCE)
launcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(launcher)


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = {
            "pi": "/installed/pi", "extension": "/config/context.js",
            "providerExtension": "/config/provider.js", "agentDir": "/config/agent",
        }
        self.healthy = {
            "ok": True, "model": "app-model", "context_window": 262144,
            "startup": {"launch_id": "app-launch", "app_parent_pid": 10},
            "fan_mode": "default",
        }

    def test_reuses_app_server_without_spawning_or_changing_settings(self):
        with patch.object(launcher, "app_endpoint", return_value="http://127.0.0.1:8001"), patch.object(launcher, "health", return_value=self.healthy), patch.object(launcher.subprocess, "run") as spawn:
            result = launcher.ensure_server(self.root)
        spawn.assert_not_called()
        self.assertEqual(result, {"baseUrl": "http://127.0.0.1:8001/v1", "model": "app-model", "contextWindow": 262144})
        self.assertEqual(self.healthy["fan_mode"], "default")

    def test_external_engine_is_rejected_without_loading_second_model(self):
        info = {**self.healthy, "startup": {"launch_id": None, "pid": 12}}
        with patch.object(launcher, "app_endpoint", return_value="http://127.0.0.1:8000"), patch.object(launcher, "health", return_value=info), patch.object(launcher.subprocess, "run") as spawn:
            with self.assertRaisesRegex(RuntimeError, "outside the app"):
                launcher.ensure_server(self.root)
        spawn.assert_not_called()

    def test_cold_start_opens_app_and_follows_port_change(self):
        with patch.object(launcher, "app_endpoint", side_effect=["http://127.0.0.1:8000", "http://127.0.0.1:8001"]), patch.object(launcher, "health", side_effect=[None, self.healthy]), patch.object(launcher.subprocess, "run") as spawn:
            result = launcher.ensure_server(self.root)
        spawn.assert_called_once_with(["/usr/bin/open", "-g", "-a", "/Applications/MTPLX.app"], check=True)
        self.assertEqual(result["baseUrl"], "http://127.0.0.1:8001/v1")

    def test_timeout_never_starts_cli_or_kills_an_engine(self):
        with patch.object(launcher, "app_endpoint", return_value="http://127.0.0.1:8000"), patch.object(launcher, "health", return_value=None), patch.object(launcher.subprocess, "run") as spawn:
            with self.assertRaisesRegex(RuntimeError, "Start button"):
                launcher.ensure_server(self.root, timeout=0)
        self.assertEqual(spawn.call_count, 1)
        self.assertEqual(spawn.call_args.args[0][0], "/usr/bin/open")

    def test_metadata_tracks_app_model_and_context(self):
        result = launcher.connection({**self.healthy, "model": "changed-model", "context_window": 32768}, "http://127.0.0.1:8123")
        self.assertEqual(result["model"], "changed-model")
        self.assertEqual(result["contextWindow"], 32768)
        with self.assertRaisesRegex(RuntimeError, "authentication"):
            launcher.connection({**self.healthy, "api_key_required": True}, "http://127.0.0.1:8000")

    def test_app_endpoint_validates_port_and_never_uses_remote_host(self):
        settings = self.root / "Library/Application Support/MTPLX/settings.json"
        settings.parent.mkdir(parents=True)
        with patch.object(launcher.Path, "home", return_value=self.root):
            settings.write_text(json.dumps({"host": "0.0.0.0", "port": 8123}))
            self.assertEqual(launcher.app_endpoint(), "http://127.0.0.1:8123")
            for value in ["8000; command", True, 0, 65536]:
                settings.write_text(json.dumps({"port": value}))
                with self.assertRaises(RuntimeError):
                    launcher.app_endpoint()
            settings.write_text(json.dumps({"host": "remote.example", "port": 8000}))
            with self.assertRaises(RuntimeError):
                launcher.app_endpoint()

    def test_real_exec_preserves_cwd_argument_boundaries_and_exit_status(self):
        # --help skips server startup but still exercises the real foreground exec.
        caller = self.root / "repo with spaces ä"
        caller.mkdir()
        fake_pi = self.root / "pi"
        fake_pi.write_text(f"#!{sys.executable}\nimport os,sys,json\nprint(json.dumps([os.getcwd(), sys.argv[1:], os.environ['PI_CODING_AGENT_DIR']]))\nsys.exit(7)\n")
        fake_pi.chmod(0o755)
        self.config["pi"] = str(fake_pi)
        configured_source = self.root / "launcher.py"
        configured_source.write_text(SOURCE.read_text().replace('"@PI_LOCAL_CONFIG@"', json.dumps(json.dumps(self.config))))
        result = subprocess.run([sys.executable, str(configured_source), "--help", "literal $HOME; `pwd`"], cwd=caller, capture_output=True, text=True)
        self.assertEqual(result.returncode, 7, result.stderr)
        cwd, argv, agent_dir = json.loads(result.stdout)
        self.assertEqual(Path(cwd).resolve(), caller.resolve())
        self.assertEqual(argv[-1], "literal $HOME; `pwd`")
        self.assertEqual(agent_dir, self.config["agentDir"])
        self.assertEqual(argv[argv.index("--provider") + 1], "mtplx")


if __name__ == "__main__":
    unittest.main()
