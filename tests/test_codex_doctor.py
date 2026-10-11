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
        self.env = dict(os.environ, HOME=str(self.root / "user-home"), CODEX_HOME=str(self.home),
                        PATH=f"{self.bin}:{os.environ['PATH']}",
                        TEST_CALLS=str(self.log), TEST_DAEMON_VERSION="0.153.4",
                        TEST_LIVE="1", TMPDIR=str(self.root))
        # The daemon's control socket: a link to the real path lsof reports.
        control = self.home / "app-server-control"
        control.mkdir()
        target = self.root / "daemon.sock"
        target.write_text("")
        (control / "app-server-control.sock").symlink_to(target)
        self.env["TEST_SOCK_REAL"] = os.path.realpath(target)
        self.cache = self.home / "models_cache.json"
        self.cache.write_text(json.dumps({"client_version": "0.153.4",
                                          "models": [{"slug": "test-model"}]}))
        (self.home / "config.toml").write_text('model = "test-model"\n')
        # NIX-609: the stub daemon keeps its version and package layout in a
        # state file, so a repair (`daemon update`) changes what it reports next.
        self.stub("codex", '''
printf 'codex %s\\n' "$*" >> "$TEST_CALLS"
state="$CODEX_HOME/.stub-daemon"
[ -f "$state" ] || printf '%s %s\\n' "$TEST_DAEMON_VERSION" "${TEST_LAYOUT:-dedicated}" > "$state"
read -r ver layout < "$state"
if [ "$layout" = legacy ]; then
  pkg="$CODEX_HOME/packages/standalone/current/bin/codex"
else
  pkg="$CODEX_HOME/packages/app-server-daemon/current/bin/codex"
fi
cli="${TEST_CLI_VERSION:-0.154.0}"
sock="$CODEX_HOME/app-server-control/app-server-control.sock"
case "$*" in
  --version) echo "codex-cli $cli" ;;
  'app-server daemon version')
    case "${TEST_DAEMON_JSON:-ok}" in
      fail) exit 1 ;;
      malformed) echo 'not json'; exit 0 ;;
    esac
    if [ "${TEST_NO_MANAGED:-0}" = 1 ]; then
      printf '{"status":"%s","socketPath":"%s","appServerVersion":"%s"}\\n' \\
        "${TEST_DAEMON_STATUS:-running}" "$sock" "$ver"
    else
      printf '{"status":"%s","managedCodexPath":"%s","managedCodexVersion":"%s","socketPath":"%s","appServerVersion":"%s"}\\n' \\
        "${TEST_DAEMON_STATUS:-running}" "$pkg" "$ver" "$sock" "$ver"
    fi ;;
  'app-server daemon update --yes')
    if [ "${TEST_UPDATE_EXIT:-0}" != 0 ]; then echo 'update failed' >&2; exit "$TEST_UPDATE_EXIT"; fi
    printf '%s dedicated\\n' "${TEST_UPDATE_TO:-0.154.0}" > "$state" ;;
  'debug models')
    printf '{"client_version":"%s","models":[{"slug":"test-model"}]}\\n' "$cli" > "$CODEX_HOME/models_cache.json"
    echo '{}' ;;
  *) echo 'unexpected mutation' >&2; exit 90 ;;
esac
''')
        self.stub("ps", '''
if [ "${TEST_PS_FAIL:-0}" = 1 ]; then exit 1; fi
[ "${TEST_DAEMON_STATUS:-running}" = stopped ] || echo '43 /daemon/bin/codex app-server --listen unix://'
echo '44 /daemon/bin/codex app-server daemon pid-update-loop'
if [ "$TEST_LIVE" = 1 ]; then
  echo '42 node /npm/bin/codex --dangerously-bypass-approvals-and-sandbox'
elif [ "$TEST_LIVE" = exec ]; then
  echo '45 node /npm/bin/codex exec --ignore-user-config -m test-model work'
  echo '46 /vendor/bin/codex exec --ignore-user-config -m test-model work'
elif [ "$TEST_LIVE" = exec-options ]; then
  echo '45 node /npm/bin/codex -m test-model exec work'
  echo '46 /vendor/bin/codex -c sandbox_mode=read-only e work'
  echo '47 /npm/bin/codex --enable some_feature exec work'
elif [ "$TEST_LIVE" = tui-options ]; then
  echo '48 /npm/bin/codex -m test-model'
elif [ "$TEST_LIVE" = exec-remote ]; then
  echo '42 /npm/bin/codex exec --remote unix:///tmp/sock work'
elif [ "$TEST_LIVE" = exec-prompt-tui ]; then
  echo '42 /npm/bin/codex exec draw a diagram'
elif [ "$TEST_LIVE" = proxy ]; then
  echo '47 /npm/bin/codex app-server proxy'
elif [ "$TEST_LIVE" = prompt ]; then
  echo '42 /npm/bin/codex repair app-server and codex-doctor'
elif [ "$TEST_LIVE" = late ]; then
  if [ -f "$TMPDIR/ps-seen" ]; then
    echo '42 /npm/bin/codex resume --last'
  else
    touch "$TMPDIR/ps-seen"
  fi
fi
''')
        # lsof -F pdn: pid 43 is the daemon (listener + one accepted socket named
        # by the socket path); a client names the accepted socket as its peer.
        self.stub("lsof", '''
case "$*" in
  *-iTCP*) [ "${TEST_LSOF_TCP:-0}" = 1 ] && echo 43; exit 0 ;;
esac
mode="${TEST_LSOF:-ok}"
[ "$mode" = fail ] && exit 1
printf 'p44\\nf7\\nd0xpair1\\nn->0xpair2\\n'
[ "$mode" = nolistener ] && exit 0
printf 'p43\\nf31\\nd0xlisten\\nn%s\\nf48\\nd0xaccepted\\nn%s\\n' "$TEST_SOCK_REAL" "$TEST_SOCK_REAL"
case "$mode" in
  client42) printf 'p42\\nf38\\nd0xclient\\nn->0xaccepted\\n' ;;
  client47) printf 'p47\\nf5\\nd0xproxy\\nn->0xaccepted\\n' ;;
esac
''')
        self.stub("which", 'printf "%s\\n" "$TEST_BIN/codex"')
        self.env["TEST_BIN"] = str(self.bin)
        self.stub("trash", 'exit "${TEST_TRASH_EXIT:-0}"')
        self.stub("pgrep", "exit 1")
        npm = self.bin / "npm"
        npm.write_text("#!/usr/bin/env python3\n" + r'''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["TEST_CALLS"], "a") as log:
    log.write("npm " + " ".join(args) + "\n")
if os.environ.get("TEST_NPM_EXIT", "0") != "0":
    sys.exit(int(os.environ["TEST_NPM_EXIT"]))
if args[0] == "view":
    print(json.dumps("0.8.0" if args[1].endswith("@0.8.0") else "1.2.3"))
elif args[0] == "install":
    prefix = Path(args[args.index("--prefix") + 1])
    name, version = args[-1].rsplit("@", 1)
    command = {"@anthropic-ai/claude-code": "claude", "@openai/codex": "codex",
               "@xai-official/grok": "grok", "@earendil-works/pi-coding-agent": "pi",
               "@steipete/bird": "bird"}[name]
    package = prefix / "lib/node_modules" / name
    package.mkdir(parents=True)
    (package / "package.json").write_text(json.dumps({"name": name, "version": version}))
    target = package / command
    target.write_text("#!/bin/sh\necho " + version + "\n")
    target.chmod(0o755)
    (prefix / "bin").mkdir()
    (prefix / "bin" / command).symlink_to(target)
else:
    sys.exit(99)
''')
        npm.chmod(0o755)
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
        self.assertNotIn("daemon update", calls)
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

    def assert_repaired(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Fixed.", result.stdout)
        calls = self.log.read_text()
        self.assertIn("codex app-server daemon update --yes", calls)
        self.assertIn("codex debug models", calls)
        for forbidden in ("daemon stop", "daemon start", "curl "):
            self.assertNotIn(forbidden, calls)
        self.assertEqual(json.loads(self.cache.read_text())["client_version"], "0.154.0")

    def test_exec_workers_do_not_block_repair(self):
        # NIX-609: exec runs its own app-server; LEAD workers run it around the
        # clock, and counting them deferred every repair for twelve days.
        self.env["TEST_LIVE"] = "exec"
        for mode in ("--fix", "--after-update"):
            with self.subTest(mode=mode):
                (self.home / ".stub-daemon").unlink(missing_ok=True)
                self.log.unlink(missing_ok=True)
                self.assert_repaired(self.run_command("bash", str(DOCTOR), mode))

    def test_exec_with_remote_counts_as_attached(self):
        self.env["TEST_LIVE"] = "exec-remote"
        before = self.cache.read_bytes()
        result = self.run_command("bash", str(DOCTOR), "--fix")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Refusing the repair", result.stdout)
        self.assert_read_only(before)

    def test_noninteractive_update_repairs_but_default_stays_strict(self):
        self.env["TEST_LIVE"] = "0"
        before = self.cache.read_bytes()
        result = self.run_command("bash", str(DOCTOR))
        self.assertEqual(result.returncode, 1)
        self.assertIn("stdin is not a terminal", result.stdout)
        self.assert_read_only(before)
        self.assert_repaired(self.run_command("bash", str(DOCTOR), "--after-update"))

    def test_no_drift_is_success(self):
        self.env["TEST_DAEMON_VERSION"] = "0.154.0"
        self.cache.write_text(self.cache.read_text().replace("0.153.4", "0.154.0"))
        before = self.cache.read_bytes()
        result = self.run_command("bash", str(DOCTOR), "--check")
        self.assertEqual(result.returncode, 0)
        self.assertIn("No drift.", result.stdout)
        self.assert_read_only(before)

    def test_newer_daemon_and_cache_are_not_drift(self):
        # The dedicated package updates itself and may run ahead of the CLI.
        for newer in ("0.155.0", "0.154.1", "0.160.0-alpha.1"):
            with self.subTest(newer=newer):
                (self.home / ".stub-daemon").unlink(missing_ok=True)
                self.env["TEST_DAEMON_VERSION"] = newer
                self.cache.write_text(json.dumps({"client_version": newer,
                                                  "models": [{"slug": "test-model"}]}))
                result = self.run_command("bash", str(DOCTOR), "--check")
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn("newer than CLI", result.stdout)

    def test_older_or_unreadable_versions_are_drift(self):
        for older in ("0.153.4", "0.154.0-alpha.17.2", "0.99.9", "garbage", ""):
            with self.subTest(older=older):
                (self.home / ".stub-daemon").unlink(missing_ok=True)
                self.env["TEST_DAEMON_VERSION"] = "0.154.0"
                self.cache.write_text(json.dumps({"client_version": older, "models": []}))
                result = self.run_command("bash", str(DOCTOR), "--check")
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("older than CLI 0.154.0", result.stdout)

    def test_legacy_standalone_package_is_drift_and_repair_moves_it(self):
        self.env.update(TEST_LAYOUT="legacy", TEST_DAEMON_VERSION="0.154.0", TEST_LIVE="0")
        self.cache.write_text(self.cache.read_text().replace("0.153.4", "0.154.0"))
        before = self.cache.read_bytes()
        result = self.run_command("bash", str(DOCTOR), "--check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("legacy standalone package 0.154.0", result.stdout)
        self.assert_read_only(before)
        self.assert_repaired(self.run_command("bash", str(DOCTOR), "--fix"))

    def test_legacy_leftover_after_the_move_is_info_only(self):
        self.env["TEST_DAEMON_VERSION"] = "0.154.0"
        self.cache.write_text(self.cache.read_text().replace("0.153.4", "0.154.0"))
        legacy = self.home / "packages/standalone/current/bin"
        legacy.mkdir(parents=True)
        (legacy / "codex").write_text("#!/bin/sh\necho 'codex-cli 0.150.1'\n")
        (legacy / "codex").chmod(0o755)
        result = self.run_command("bash", str(DOCTOR), "--check")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("legacy standalone package 0.150.1 left behind by the move; unused",
                      result.stdout)
        self.assertIn("No drift.", result.stdout)

    def test_missing_model_in_current_cache_does_not_trigger_repair(self):
        self.env["TEST_DAEMON_VERSION"] = "0.154.0"
        self.cache.write_text(json.dumps({"client_version": "0.154.0", "models": []}))
        before = self.cache.read_bytes()
        for mode in ("--check", "--fix", "--after-update"):
            with self.subTest(mode=mode):
                result = self.run_command("bash", str(DOCTOR), mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("no repair for this alone", result.stdout)
                self.assert_read_only(before)

    def test_process_inspection_failure_is_not_a_deferral(self):
        self.env["TEST_PS_FAIL"] = "1"
        result = self.run_command("bash", str(DOCTOR), "--after-update")
        self.assertEqual(result.returncode, 2)
        self.assertIn("cannot inspect live sessions", result.stderr)

    def test_repair_failure_stays_nonzero(self):
        self.env.update(TEST_LIVE="0", TEST_UPDATE_EXIT="3")
        for mode in ("--fix", "--after-update"):
            with self.subTest(mode=mode):
                result = self.run_command("bash", str(DOCTOR), mode)
                self.assertEqual(result.returncode, 1)
                self.assertIn("daemon update failed", result.stdout)
                self.assertIn("Repair failed", result.stdout)
                self.assertNotIn("debug models", self.log.read_text())

    def test_refusal_does_not_print_session_prompt(self):
        self.env["TEST_LIVE"] = "prompt"
        result = self.run_command("bash", str(DOCTOR), "--fix")
        self.assertEqual(result.returncode, 1)
        self.assertIn("42 codex session", result.stdout)
        self.assertNotIn("repair app-server and codex-doctor", result.stdout)

    def test_session_attached_before_repair_blocks_it(self):
        self.env["TEST_LIVE"] = "late"
        before = self.cache.read_bytes()
        result = self.run_command("bash", str(DOCTOR), "--fix")
        self.assertEqual(result.returncode, 1)
        self.assertIn("a Codex session attached before the repair", result.stderr)
        self.assert_read_only(before)

    def test_tui_whose_prompt_starts_with_exec_is_caught_by_its_socket(self):
        # `codex "exec draw a diagram"` is a TUI; ps flattens it into `codex exec …`.
        self.env.update(TEST_LIVE="exec-prompt-tui", TEST_LSOF="client42")
        before = self.cache.read_bytes()
        result = self.run_command("bash", str(DOCTOR), "--fix")
        self.assertEqual(result.returncode, 1)
        self.assertIn("42 attached to the daemon", result.stdout)
        self.assertNotIn("draw a diagram", result.stdout)
        result = self.run_command("bash", str(DOCTOR), "--after-update")
        self.assertEqual(result.returncode, 0)
        self.assertIn("repair deferred", result.stdout)
        self.assert_read_only(before)

    def test_ssh_proxy_client_blocks_repair(self):
        self.env.update(TEST_LIVE="proxy", TEST_LSOF="client47")
        before = self.cache.read_bytes()
        result = self.run_command("bash", str(DOCTOR), "--fix")
        self.assertEqual(result.returncode, 1)
        self.assertIn("47 attached to the daemon", result.stdout)
        self.assert_read_only(before)

    def test_remote_clients_that_cannot_be_ruled_out_block_repair(self):
        settings = self.home / "app-server-daemon"
        settings.mkdir()
        for remote_control, tcp, expected in ((True, "0", "remote control enabled"),
                                              (False, "1", "43 daemon listens on TCP")):
            with self.subTest(expected=expected):
                (settings / "settings.json").write_text(
                    json.dumps({"remoteControlEnabled": remote_control}))
                self.env.update(TEST_LIVE="0", TEST_LSOF_TCP=tcp)
                before = self.cache.read_bytes()
                result = self.run_command("bash", str(DOCTOR), "--fix")
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(expected, result.stdout)
                result = self.run_command("bash", str(DOCTOR), "--after-update")
                self.assertEqual(result.returncode, 0)
                self.assertIn("repair deferred", result.stdout)
                self.assert_read_only(before)

    def test_socket_inspection_failure_is_not_a_deferral(self):
        self.env["TEST_LIVE"] = "0"
        for mode in ("fail", "nolistener"):
            with self.subTest(lsof=mode):
                self.env["TEST_LSOF"] = mode
                before = self.cache.read_bytes()
                result = self.run_command("bash", str(DOCTOR), "--after-update")
                self.assertEqual(result.returncode, 2)
                self.assertIn("cannot inspect daemon connections", result.stderr)
                self.assert_read_only(before)

    def test_stopped_daemon_needs_no_socket_check_and_uses_the_package_fallback(self):
        # Older CLIs and a stopped daemon report no managedCodexPath.
        self.env.update(TEST_DAEMON_STATUS="stopped", TEST_NO_MANAGED="1", TEST_LIVE="0",
                        TEST_LSOF="fail", TEST_DAEMON_VERSION="0.154.0")
        dedicated = self.home / "packages/app-server-daemon/current/bin"
        dedicated.mkdir(parents=True)
        (dedicated / "codex").write_text("#!/bin/sh\necho 'codex-cli 0.154.0'\n")
        (dedicated / "codex").chmod(0o755)
        result = self.run_command("bash", str(DOCTOR), "--check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("daemon package 0.154.0 matches CLI", result.stdout)
        self.assertIn("app-server daemon not running", result.stdout)
        self.assertIn("models cache written by client 0.153.4, older", result.stdout)
        self.assert_repaired(self.run_command("bash", str(DOCTOR), "--fix"))

    def test_prerelease_versions_follow_semver_order(self):
        self.env["TEST_CLI_VERSION"] = "0.163.0-alpha.2"
        for component, drift in (("0.163.0-alpha.1", True), ("0.163.0-alpha", True),
                                 ("0.163.0-alpha.10", False), ("0.163.0-beta", False),
                                 ("0.163.0", False)):
            with self.subTest(component=component):
                (self.home / ".stub-daemon").unlink(missing_ok=True)
                self.env["TEST_DAEMON_VERSION"] = component
                self.cache.write_text(json.dumps({"client_version": component,
                                                  "models": [{"slug": "test-model"}]}))
                result = self.run_command("bash", str(DOCTOR), "--check")
                self.assertEqual(result.returncode, 1 if drift else 0, result.stdout)
                if drift:
                    self.assertIn("older than CLI 0.163.0-alpha.2", result.stdout)

    def test_unparseable_cli_version_is_an_error(self):
        self.env["TEST_CLI_VERSION"] = "dev-build"
        result = self.run_command("bash", str(DOCTOR), "--check")
        self.assertEqual(result.returncode, 2)
        self.assertIn("cannot parse the CLI version", result.stderr)

    def test_exec_workers_with_global_options_do_not_block_repair(self):
        self.env["TEST_LIVE"] = "exec-options"
        self.assert_repaired(self.run_command("bash", str(DOCTOR), "--after-update"))

    def test_tui_with_global_options_still_blocks(self):
        self.env["TEST_LIVE"] = "tui-options"
        before = self.cache.read_bytes()
        result = self.run_command("bash", str(DOCTOR), "--fix")
        self.assertEqual(result.returncode, 1)
        self.assertIn("48 codex session", result.stdout)
        self.assert_read_only(before)

    def test_unknown_daemon_status_with_a_running_app_server_refuses(self):
        # A failed or malformed `daemon version` must not skip the socket check
        # while an SSH proxy client (invisible to the process check) is attached.
        self.env.update(TEST_LIVE="proxy", TEST_LSOF="client47")
        for answer in ("fail", "malformed"):
            with self.subTest(answer=answer):
                self.env["TEST_DAEMON_JSON"] = answer
                before = self.cache.read_bytes()
                result = self.run_command("bash", str(DOCTOR), "--after-update")
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertIn("while an app-server runs; refusing repair", result.stderr)
                self.assert_read_only(before)

    def test_build_metadata_is_ignored(self):
        self.env.update(TEST_CLI_VERSION="0.154.0+build.7", TEST_DAEMON_VERSION="0.154.0")
        self.cache.write_text(self.cache.read_text().replace("0.153.4", "0.154.0"))
        result = self.run_command("bash", str(DOCTOR), "--check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("No drift.", result.stdout)

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
        self.assertIn("--allow-scripts ${./ai-clis-npm-allow-scripts.json}", module)
        self.assertIn("${../../scripts/update-ai-clis.py}", module)
        recipe = JUSTFILE.read_text().split("\nupdate-ai-clis:\n", 1)[1].split("\n\n", 1)[0]
        self.assertIn("python3 ./scripts/update-ai-clis.py", recipe)
        updater = (REPO / "scripts/update-ai-clis.py").read_text()
        self.assertIn("modules/uzumaki/ai-clis-npm-allow-scripts.json", updater)
        for text in (module, recipe):
            self.assertNotRegex(text, r"--allow-scripts=@")
            self.assertNotIn("dangerously-allow-all-scripts", text)

    def test_claude_auto_updater_is_disabled_in_home_environment(self):
        module = AI_CLIS_MODULE.read_text()
        for var in ("DISABLE_AUTOUPDATER", "DISABLE_UPDATES", "FORCE_AUTOUPDATE_PLUGINS"):
            self.assertRegex(module, rf'home\.sessionVariables\.{var}\s*=\s*"1";')
            self.assertRegex(module, rf"set -gx {var} 1")

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
