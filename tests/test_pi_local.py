"""Launcher behavior without loading a GPU model or needing macOS."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch
import urllib.error
import errno

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
            "modelId": "local-model", "contextWindow": 262144,
            "modelPath": str(self.root), "mtplx": "/installed/mtplx",
            "pi": "/installed/pi", "extension": "/config/context.js", "agentDir": "/config/agent",
        }
        self.healthy = {
            "ok": True, "model": "local-model", "context_window": 262144,
            "generation_mode": "mtp", "mtp_enabled": True, "depth": 2,
        }

    def test_reuses_ready_server_without_spawning(self):
        with patch.object(launcher, "health", return_value=self.healthy), patch.object(launcher.subprocess, "Popen") as spawn:
            launcher.ensure_server(self.config, self.root)
        spawn.assert_not_called()

    def test_wrong_model_context_or_mode_never_spawns(self):
        for key, value in [("model", "other"), ("context_window", 32768), ("mtp_enabled", False), ("depth", 3), ("api_key_required", True)]:
            with self.subTest(key=key), patch.object(launcher, "health", return_value={**self.healthy, key: value}), patch.object(launcher.subprocess, "Popen") as spawn:
                with self.assertRaisesRegex(RuntimeError, "left alone"):
                    launcher.ensure_server(self.config, self.root)
                spawn.assert_not_called()

    def test_cold_start_waits_and_detaches_only_server(self):
        child = MagicMock()
        child.poll.return_value = None
        with patch.object(launcher, "health", side_effect=[None, None, self.healthy]), patch.object(launcher.socket, "socket"), patch.object(launcher.time, "sleep"), patch.object(launcher.subprocess, "Popen", return_value=child) as spawn:
            launcher.ensure_server(self.config, self.root)
        args, kwargs = spawn.call_args
        self.assertIn("262144", args[0])
        self.assertIn("--mtp", args[0])
        self.assertTrue(kwargs["start_new_session"])
        self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
        child.terminate.assert_not_called()

    def test_startup_timeout_cleans_up_only_own_child(self):
        child = MagicMock()
        with patch.object(launcher, "health", return_value=None), patch.object(launcher.socket, "socket"), patch.object(launcher.subprocess, "Popen", return_value=child):
            with self.assertRaisesRegex(RuntimeError, "did not become ready"):
                launcher.ensure_server(self.config, self.root, timeout=0)
        child.terminate.assert_called_once()
        child.wait.assert_called_once_with(timeout=10)

    def test_only_connection_refused_means_startable(self):
        for reason in [ConnectionRefusedError(errno.ECONNREFUSED, "refused"), TimeoutError("timeout")]:
            with self.subTest(reason=reason), patch.object(launcher.urllib.request, "build_opener") as opener:
                opener.return_value.open.side_effect = urllib.error.URLError(reason)
                if isinstance(reason, ConnectionRefusedError):
                    self.assertIsNone(launcher.health())
                else:
                    with self.assertRaises(RuntimeError):
                        launcher.health()

    def test_real_exec_preserves_cwd_argument_boundaries_and_exit_status(self):
        # --help skips server startup but still exercises the real foreground exec.
        caller = self.root / "repo with spaces ä"
        caller.mkdir()
        fake_pi = self.root / "pi"
        fake_pi.write_text(f"#!{sys.executable}\nimport os,sys,json\nprint(json.dumps([os.getcwd(), sys.argv[1:], os.environ['PI_CODING_AGENT_DIR']]))\nsys.exit(7)\n")
        fake_pi.chmod(0o755)
        self.config["pi"] = str(fake_pi)
        config_file = self.root / "config.json"
        config_file.write_text(json.dumps(self.config))
        result = subprocess.run([sys.executable, str(SOURCE), str(config_file), "--help", "literal $HOME; `pwd`"], cwd=caller, capture_output=True, text=True)
        self.assertEqual(result.returncode, 7, result.stderr)
        cwd, argv, agent_dir = json.loads(result.stdout)
        self.assertEqual(Path(cwd).resolve(), caller.resolve())
        self.assertEqual(argv[-1], "literal $HOME; `pwd`")
        self.assertEqual(agent_dir, self.config["agentDir"])
        self.assertEqual(argv[argv.index("--provider") + 1], "mtplx")


if __name__ == "__main__":
    unittest.main()
