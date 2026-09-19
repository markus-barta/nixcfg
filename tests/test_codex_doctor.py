#!/usr/bin/env python3
"""Exercise the doctor and just recipe without touching real Codex sessions."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
DOCTOR = REPO / "scripts/codex-doctor.sh"
CURSOR_SOURCES = REPO / "pkgs/cursor-agent/sources.json"
ALLOW_SCRIPTS = REPO / "modules/uzumaki/ai-clis-npm-allow-scripts.json"
AI_CLIS_MODULE = REPO / "modules/uzumaki/ai-clis-npm.nix"
JUSTFILE = REPO / "justfile"


def allow_scripts():
    return json.loads(ALLOW_SCRIPTS.read_text())["allowScripts"]


class CodexDoctorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="test-codex-doctor-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.home = self.root / "codex-home"
        self.home.mkdir()
        self.log = self.root / "calls"
        self.env = dict(os.environ, CODEX_HOME=str(self.home),
                        PATH=f"{self.bin}:{os.environ['PATH']}",
                        TEST_CALLS=str(self.log), TEST_DAEMON_VERSION="0.153.4",
                        TEST_LIVE="1", TMPDIR=str(self.root))
        self.cache = self.home / "models_cache.json"
        self.cache.write_text(json.dumps({"client_version": "0.153.4",
                                          "models": [{"slug": "test-model"}]}))
        (self.home / "config.toml").write_text('model = "test-model"\n')
        self.stub("codex", '''
printf 'codex %s\\n' "$*" >> "$TEST_CALLS"
case "$*" in
  --version) echo 'codex-cli 0.154.0' ;;
  'app-server daemon version')
    printf '{"status":"running","appServerVersion":"%s"}\\n' "$TEST_DAEMON_VERSION" ;;
  'app-server daemon start') exit 1 ;;
  *) echo 'unexpected mutation' >&2; exit 90 ;;
esac
''')
        self.stub("ps", '''
if [ "${TEST_PS_FAIL:-0}" = 1 ]; then exit 1; fi
if [ "$TEST_LIVE" = 1 ]; then
  echo '42 node /npm/bin/codex --dangerously-bypass-approvals-and-sandbox'
elif [ "$TEST_LIVE" = exec ]; then
  echo '42 /npm/bin/codex exec repair app-server and codex-doctor'
elif [ "$TEST_LIVE" = late ]; then
  if [ -f "$TMPDIR/ps-seen" ]; then
    echo '42 /npm/bin/codex exec work'
  else
    touch "$TMPDIR/ps-seen"
  fi
else
  echo '43 /standalone/codex app-server daemon run'
fi
''')
        self.stub("which", 'printf "%s\\n" "$TEST_BIN/codex"')
        self.env["TEST_BIN"] = str(self.bin)
        self.stub("trash", 'exit "${TEST_TRASH_EXIT:-0}"')
        self.stub("pgrep", "exit 1")
        self.stub("npm", '''
printf 'npm %s\\n' "$*" >> "$TEST_CALLS"
exit "${TEST_NPM_EXIT:-0}"
''')
        for name in ("claude", "grok", "pi", "cursor-agent"):
            self.stub(name, "echo test-version")
        # NIX-514: the recipe's Cursor pin step reads the vendor installer. The
        # stub names the release already pinned, so the step is a no-op and never
        # reaches the network or `nix build`.
        pinned = json.loads(CURSOR_SOURCES.read_text())["version"]
        self.stub("curl", f'''
printf 'curl %s\\n' "$*" >> "$TEST_CALLS"
case "$*" in
  *https://cursor.com/install) ;;
  *) echo "unexpected curl in test: $*" >&2; exit 97 ;;
esac
if [ "${{TEST_CURL_EXIT:-0}}" != 0 ]; then exit "$TEST_CURL_EXIT"; fi
echo 'DOWNLOAD_URL="https://downloads.cursor.com/lab/{pinned}/${{OS}}/${{ARCH}}/agent-cli-package.tar.gz"'
''')
        self.stub("nix", '''
printf 'nix %s\\n' "$*" >> "$TEST_CALLS"
exit 99
''')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\nset -eu\n" + body)
        path.chmod(0o755)

    def run_command(self, *args):
        return subprocess.run(args, cwd=REPO, env=self.env,
                              stdin=subprocess.DEVNULL, capture_output=True,
                              text=True, timeout=30)

    def assert_read_only(self, before):
        self.assertEqual(before, self.cache.read_bytes())
        calls = self.log.read_text()
        self.assertNotIn("debug models", calls)
        self.assertNotIn("daemon stop", calls)
        self.assertNotIn("daemon start", calls)
        self.assertFalse(list(self.root.glob("codex-doctor.*/processes")))

    def test_live_update_defers_successfully_without_mutation(self):
        before = self.cache.read_bytes()
        result = self.run_command("bash", str(DOCTOR), "--after-update")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("repair deferred", result.stdout)
        self.assertIn("just codex-doctor --fix", result.stdout)
        self.assert_read_only(before)

    def test_check_and_fix_stay_strict_with_live_sessions(self):
        for mode in ("--check", "--fix"):
            with self.subTest(mode=mode):
                before = self.cache.read_bytes()
                result = self.run_command("bash", str(DOCTOR), mode)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assert_read_only(before)

    def test_exec_prompt_cannot_hide_a_live_session(self):
        self.env["TEST_LIVE"] = "exec"
        result = self.run_command("bash", str(DOCTOR), "--fix")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Refusing the cleanup", result.stdout)
        self.assertNotIn("daemon stop", self.log.read_text())

    def test_noninteractive_update_defers_but_default_stays_strict(self):
        self.env["TEST_LIVE"] = "0"
        before = self.cache.read_bytes()
        result = self.run_command("bash", str(DOCTOR), "--after-update")
        self.assertEqual(result.returncode, 0)
        self.assertIn("stdin is not a terminal", result.stdout)
        result = self.run_command("bash", str(DOCTOR))
        self.assertEqual(result.returncode, 1)
        self.assert_read_only(before)

    def test_no_drift_is_success(self):
        self.env["TEST_DAEMON_VERSION"] = "0.154.0"
        self.cache.write_text(self.cache.read_text().replace("0.153.4", "0.154.0"))
        before = self.cache.read_bytes()
        result = self.run_command("bash", str(DOCTOR), "--check")
        self.assertEqual(result.returncode, 0)
        self.assertIn("No drift.", result.stdout)
        self.assert_read_only(before)

    def test_missing_model_in_current_cache_does_not_trigger_repair(self):
        self.env["TEST_DAEMON_VERSION"] = "0.154.0"
        self.cache.write_text(json.dumps({"client_version": "0.154.0", "models": []}))
        before = self.cache.read_bytes()
        for mode in ("--check", "--fix", "--after-update"):
            with self.subTest(mode=mode):
                result = self.run_command("bash", str(DOCTOR), mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("no cleanup for this alone", result.stdout)
                self.assert_read_only(before)

    def test_process_inspection_failure_is_not_a_deferral(self):
        self.env["TEST_PS_FAIL"] = "1"
        result = self.run_command("bash", str(DOCTOR), "--after-update")
        self.assertEqual(result.returncode, 2)
        self.assertIn("cannot inspect live sessions", result.stderr)

    def test_repair_failure_stays_nonzero(self):
        self.env["TEST_LIVE"] = "0"
        result = self.run_command("bash", str(DOCTOR), "--fix")
        self.assertEqual(result.returncode, 1)
        self.assertIn("daemon start failed", result.stdout)
        self.assertIn("Cleanup failed", result.stdout)

    def test_cache_removal_failure_stops_repair(self):
        self.env["TEST_LIVE"] = "0"
        self.env["TEST_TRASH_EXIT"] = "1"
        result = self.run_command("bash", str(DOCTOR), "--fix")
        self.assertEqual(result.returncode, 1)
        self.assertIn("could not trash models cache", result.stdout)
        self.assertNotIn("daemon start", self.log.read_text())

    def test_refusal_does_not_print_session_prompt(self):
        self.env["TEST_LIVE"] = "exec"
        result = self.run_command("bash", str(DOCTOR), "--fix")
        self.assertEqual(result.returncode, 1)
        self.assertIn("42 codex session", result.stdout)
        self.assertNotIn("repair app-server and codex-doctor", result.stdout)

    def test_session_started_before_cleanup_blocks_repair(self):
        self.env["TEST_LIVE"] = "late"
        before = self.cache.read_bytes()
        result = self.run_command("bash", str(DOCTOR), "--fix")
        self.assertEqual(result.returncode, 1)
        self.assertIn("a Codex session started before cleanup", result.stderr)
        self.assert_read_only(before)

    def test_recipe_scopes_script_approvals_and_accepts_deferral(self):
        result = self.run_command("just", "update-ai-clis")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("repair deferred", result.stdout)
        calls = self.log.read_text()
        self.assertIn(f"--allow-scripts={','.join(allow_scripts())}", calls)
        self.assertNotIn("dangerously-allow-all-scripts", calls)
        self.assertIn("curl -fsSL --max-time 30 https://cursor.com/install", calls)
        self.assertRegex(result.stdout, r"cursor-agent: pin \S+ is current")
        self.assertNotIn("nix ", calls)

    def test_activation_and_recipe_share_one_allow_list(self):
        # NIX-517: a switch installs the same CLIs as `just update-ai-clis`;
        # both must take the allow-list from the one file, never inline.
        names = allow_scripts()
        self.assertEqual(len(names), len(set(names)))
        for needed in ("@anthropic-ai/claude-code", "@xai-official/grok"):
            self.assertIn(needed, names)
        module = AI_CLIS_MODULE.read_text()
        self.assertIn("lib.importJSON ./ai-clis-npm-allow-scripts.json", module)
        self.assertIn('lib.escapeShellArg "--allow-scripts=${npmAllowScripts}"', module)
        recipe = JUSTFILE.read_text().split("\nupdate-ai-clis:\n", 1)[1].split("\n\n", 1)[0]
        self.assertIn("require('./modules/uzumaki/ai-clis-npm-allow-scripts.json').allowScripts", recipe)
        for text in (module, recipe):
            self.assertNotRegex(text, r"--allow-scripts=@")
            self.assertNotIn("dangerously-allow-all-scripts", text)

    def test_claude_auto_updater_is_disabled_in_home_environment(self):
        module = AI_CLIS_MODULE.read_text()
        self.assertRegex(module, r'home\.sessionVariables\.DISABLE_AUTOUPDATER\s*=\s*"1";')
        self.assertRegex(module, r"set -gx DISABLE_AUTOUPDATER 1")

    def test_recipe_cursor_failure_does_not_skip_doctor(self):
        before = CURSOR_SOURCES.read_bytes()
        self.env["TEST_CURL_EXIT"] = "7"
        result = self.run_command("just", "update-ai-clis")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("cursor-agent: cannot fetch the installer", result.stderr)
        self.assertIn("repair deferred", result.stdout)
        self.assertEqual(before, CURSOR_SOURCES.read_bytes())
        self.assertNotIn("nix ", self.log.read_text())

    def test_recipe_preserves_install_failure(self):
        self.env["TEST_NPM_EXIT"] = "42"
        result = self.run_command("just", "update-ai-clis")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Codex doctor", result.stdout)
        self.assertNotIn("codex ", self.log.read_text())
        self.assertNotIn("curl ", self.log.read_text())

    def test_recipe_preserves_doctor_environment_failure(self):
        self.env["TEST_PS_FAIL"] = "1"
        result = self.run_command("just", "update-ai-clis")
        self.assertNotEqual(result.returncode, 0)

    def test_extra_arguments_are_rejected(self):
        result = self.run_command("bash", str(DOCTOR), "--after-update", "--fix")
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
