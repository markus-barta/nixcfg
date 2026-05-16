{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.uzumaki.codex.exitAlias;
  hookScript = ".codex/hooks/codex-exit-alias.py";
  hookCommand = "${pkgs.python3}/bin/python3 ${config.home.homeDirectory}/${hookScript}";
in
{
  config = lib.mkIf (config.uzumaki.enable && cfg.enable) {
    assertions = [
      {
        assertion = pkgs.stdenv.isDarwin;
        message = "uzumaki.codex.exitAlias currently requires macOS AppleScript support.";
      }
    ];

    home.file.${hookScript} = {
      executable = true;
      text = ''
        #!${pkgs.python3}/bin/python3
        import json
        import os
        import subprocess
        import sys
        import time


        TRIGGER = ${builtins.toJSON cfg.trigger}
        DELAY_SECONDS = ${toString cfg.delaySeconds}
        ALLOWED_BUNDLE_IDS = ${builtins.toJSON cfg.allowedBundleIds}
        LOG_PATH = os.path.expanduser("~/.codex/exit-alias.log")


        def log(message):
            try:
                os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
                timestamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
                with open(LOG_PATH, "a", encoding="utf-8") as handle:
                    handle.write(timestamp + " " + message + "\n")
            except Exception:
                pass


        def run_osascript(lines, args=None, timeout=3):
            command = ["/usr/bin/osascript"]
            for line in lines:
                command.extend(["-e", line])
            command.extend(args or [])
            return subprocess.run(
                command,
                text=True,
                capture_output=True,
                timeout=timeout,
                check=False,
            )


        def current_focus():
            result = run_osascript(
                [
                    'tell application "System Events"',
                    "set frontApp to first application process whose frontmost is true",
                    "set appBundle to bundle identifier of frontApp",
                    "set appName to name of frontApp",
                    "set appPid to unix id of frontApp as string",
                    'set winTitle to ""',
                    'set winId to ""',
                    "try",
                    "set winTitle to name of front window of frontApp",
                    "set winId to id of front window of frontApp as string",
                    "end try",
                    "return appBundle & linefeed & appName & linefeed & appPid & linefeed & winId & linefeed & winTitle",
                    "end tell",
                ]
            )
            if result.returncode != 0:
                log("focus-read-failed: " + result.stderr.strip())
                return None

            lines = result.stdout.rstrip("\n").split("\n", 4)
            while len(lines) < 5:
                lines.append("")
            return {
                "bundle_id": lines[0],
                "app_name": lines[1],
                "pid": lines[2],
                "window_id": lines[3],
                "window_title": lines[4],
            }


        def emit_block(reason):
            print(json.dumps({"decision": "block", "reason": reason}))


        def send_exit_after_delay(expected_bundle, expected_pid, expected_window_id, expected_window_title):
            time.sleep(DELAY_SECONDS)
            result = run_osascript(
                [
                    "on run argv",
                    "set expectedBundle to item 1 of argv",
                    "set expectedPid to item 2 of argv",
                    "set expectedWindowId to item 3 of argv",
                    "set expectedWindowTitle to item 4 of argv",
                    'tell application "System Events"',
                    "set frontApp to first application process whose frontmost is true",
                    "set currentBundle to bundle identifier of frontApp",
                    "set currentPid to unix id of frontApp as string",
                    "if currentBundle is not expectedBundle then return \"focus-changed\"",
                    "if expectedPid is not \"\" and currentPid is not expectedPid then return \"process-changed\"",
                    'set currentWindowId to ""',
                    'set currentWindowTitle to ""',
                    "try",
                    "set currentWindowTitle to name of front window of frontApp",
                    "set currentWindowId to id of front window of frontApp as string",
                    "end try",
                    "if expectedWindowId is not \"\" and currentWindowId is not expectedWindowId then return \"window-changed\"",
                    "if expectedWindowId is \"\" and expectedWindowTitle is not \"\" and currentWindowTitle is not expectedWindowTitle then return \"window-title-changed\"",
                    'keystroke "/exit"',
                    "key code 36",
                    'return "sent"',
                    "end tell",
                    "end run",
                ],
                [expected_bundle, expected_pid, expected_window_id, expected_window_title],
                timeout=5,
            )
            status = result.stdout.strip() if result.stdout.strip() else result.stderr.strip()
            log("send-result: " + status)
            return 0 if result.returncode == 0 else result.returncode


        def hook_main():
            try:
                payload = json.load(sys.stdin)
            except Exception as exc:
                log("invalid-hook-input: " + str(exc))
                return 0

            prompt = payload.get("prompt", "")
            if prompt.strip() != TRIGGER:
                return 0

            focus = current_focus()
            if focus is None:
                emit_block("Codex exit alias could not inspect macOS focus; use /exit.")
                return 0

            bundle_id = focus["bundle_id"]
            if ALLOWED_BUNDLE_IDS and bundle_id not in ALLOWED_BUNDLE_IDS:
                log("blocked-non-terminal-focus: " + bundle_id)
                emit_block("Codex exit alias saw non-terminal focus; use /exit.")
                return 0

            if os.environ.get("CODEX_EXIT_ALIAS_DRY_RUN") == "1":
                log("dry-run: would send /exit for " + bundle_id)
                emit_block("Codex exit alias dry run blocked exact exit.")
                return 0

            try:
                subprocess.Popen(
                    [
                        sys.executable,
                        os.path.realpath(__file__),
                        "--send-after-delay",
                        focus["bundle_id"],
                        focus["pid"],
                        focus["window_id"],
                        focus["window_title"],
                    ],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
                log("scheduled: " + bundle_id)
                emit_block("Translating exit to /exit.")
            except Exception as exc:
                log("schedule-failed: " + str(exc))
                emit_block("Codex exit alias could not schedule /exit; use /exit.")
            return 0


        def main():
            if len(sys.argv) >= 2 and sys.argv[1] == "--send-after-delay":
                args = sys.argv[2:]
                while len(args) < 4:
                    args.append("")
                return send_exit_after_delay(args[0], args[1], args[2], args[3])
            return hook_main()


        if __name__ == "__main__":
            raise SystemExit(main())
      '';
    };

    home.file.".codex/hooks.json".text =
      builtins.toJSON {
        hooks = {
          UserPromptSubmit = [
            {
              hooks = [
                {
                  type = "command";
                  command = hookCommand;
                  timeout = 5;
                  statusMessage = "checking Codex exit alias";
                }
              ];
            }
          ];
        };
      }
      + "\n";

    home.activation.codexExitAliasHint = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      echo "Codex exit alias hook installed. If Codex marks it as new, open /hooks and trust it once."
      echo "macOS may also ask for Accessibility permission before AppleScript keystrokes can be sent."
    '';
  };
}
