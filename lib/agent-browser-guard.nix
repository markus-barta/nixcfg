# NIX-445 — shared macOS agent browser-launch guard (pure text builders)
#
# WHY THIS EXISTS
#   Agent worker sessions repeatedly launched the native Chrome binary that
#   NIX-288 deliberately exports as PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH. On a
#   sandboxed agent session Chrome aborts inside macOS `_RegisterApplication`,
#   which is disruptive on the operator's desktop (2026-09-08 21:35 CEST,
#   Chrome 74417 from node 74416). Prompt-level prohibitions did not hold, so
#   the boundary has to be mechanical.
#
# WHAT THIS FILE IS
#   Pure string builders only — no derivations, no `pkgs`. Consumed by
#   modules/uzumaki/agent-browser-guard.nix (Home Manager module) and by
#   modules/uzumaki/paimos-agentd.nix (owned-session launchers), and evaluated
#   directly by tests/T72-agent-browser-guard.sh.
#
# MECHANISM AND ITS PROVEN LIMIT (measured on Darwin 25.6, 2026-09-08)
#   `sandbox-exec -f <profile>` with `(allow default)` plus
#   `(deny process-exec* (subpath "<browser>.app"))` blocks the exec for the
#   wrapped process AND every descendant — direct exec, exec through a symlink,
#   and Node `child_process` grandchildren (Playwright) all fail with EPERM.
#   Ordinary commands are unaffected.
#
#   HARD LIMIT: a process already running under ANY profile that contains a
#   `deny` rule cannot apply a second profile — `sandbox_apply: Operation not
#   permitted`. Verified for unrelated denies too (sysctl-write, lsopen,
#   network-outbound), so it is not specific to process-exec. Consequence:
#   CLIs that apply their own Seatbelt profile per command (Codex) MUST NOT be
#   wrapped in this sandbox — doing so would break their existing inner
#   sandbox. Those entry points get the environment layer only, and that gap is
#   documented rather than papered over.
#
# PATH RESOLUTION TRAP
#   Seatbelt matches the RESOLVED path. `/tmp/...` rules never fire because
#   `/tmp` is a symlink to `/private/tmp`; likewise `/Applications/Safari.app`
#   resolves into the cryptex. Always list the realpath.
{ lib }:

let
  # Reject anything that could break out of the `"..."` literal in the profile
  # or the shell single-quoting in the generated launchers.
  pathIsSafe =
    path: lib.isString path && lib.hasPrefix "/" path && builtins.match ''[^"\\'$`]+'' path != null;

  checkPath =
    what: path:
    if pathIsSafe path then
      path
    else
      throw "agent-browser-guard: ${what} must be an absolute path without quote, backslash, dollar or backtick characters (got: ${toString path})";
in
rec {
  # Native browser app bundles denied inside guarded sessions. Realpaths only
  # (see PATH RESOLUTION TRAP above). Listing a bundle that is not installed is
  # harmless — the rule simply never matches.
  defaultBrowserBundles = [
    "/Applications/Google Chrome.app"
    "/Applications/Google Chrome Canary.app"
    "/Applications/Google Chrome Beta.app"
    "/Applications/Google Chrome Dev.app"
    "/Applications/Chromium.app"
    "/Applications/Helium.app" # Chromium-family, installed on mbp2607
    "/Applications/Brave Browser.app"
    "/Applications/Microsoft Edge.app"
    "/Applications/Firefox.app"
    "/Applications/Zen.app" # operator's daily driver — agents must not drive it
    "/Applications/Arc.app"
    # /Applications/Safari.app is a symlink into the cryptex; the realpath is
    # what Seatbelt sees.
    "/System/Cryptexes/App/System/Applications/Safari.app"
  ];

  # Environment hints SOME browser-driving harnesses read. They are hints, not a
  # boundary: a harness that hardcodes an executable path, or reads a different
  # variable, never sees them. Guarded sessions get
  # the refusal shim instead of the NIX-288 native Chrome path, so a blocked run
  # produces a readable refusal rather than a bare EPERM. Human shells keep the
  # NIX-288 value untouched (macos-common.nix → playwrightSessionVars).
  harnessBrowserVariables = [
    "PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH"
    "PUPPETEER_EXECUTABLE_PATH"
    "CHROME_PATH"
  ];

  # `NAME=value` pairs for the launchd plist / any env-taking consumer.
  mkHarnessEnv =
    { refusalPath, mode }:
    let
      safe = checkPath "refusal shim path" refusalPath;
    in
    lib.listToAttrs (map (name: lib.nameValuePair name safe) harnessBrowserVariables)
    // {
      INSPR_AGENT_BROWSER_GUARD = mode;
    };

  # Same, rendered as shell `export` lines. Only these variables are touched —
  # CODEX_HOME, PATH, and every other inherited CLI/home variable stay as-is.
  mkHarnessEnvExports =
    args:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") (mkHarnessEnv args)
    );

  # Seatbelt profile text. `(allow default)` keeps the session's existing
  # filesystem/network behaviour intact; only browser execution is removed.
  mkProfileText =
    {
      browserBundles ? defaultBrowserBundles,
      extraDenyPaths ? [ ],
      denyLaunchServices ? true,
    }:
    let
      bundleRules = map (
        b: ''(deny process-exec* (subpath "${checkPath "browser bundle" b}"))''
      ) browserBundles;
      extraRules = map (
        p: ''(deny process-exec* (subpath "${checkPath "extra deny path" p}"))''
      ) extraDenyPaths;
      lsopenRule = lib.optional denyLaunchServices ''
        ; LaunchServices would otherwise spawn the browser from launchd, outside
        ; this process tree, where process-exec cannot see it.
        (deny lsopen)'';
    in
    ''
      (version 1)
      ; INSPR agent browser-launch guard — NIX-445. Generated by
      ; lib/agent-browser-guard.nix; do not hand-edit the rendered file.
      ;
      ; Additional restriction only: everything the session could do before is
      ; still allowed, minus native browser execution.
      (allow default)

      ${lib.concatStringsSep "\n" (bundleRules ++ extraRules ++ lsopenRule)}
    '';

  # ── Codex native permission profiles (Codex >= 0.138; measured on 0.153.4) ──
  # Codex applies its own Seatbelt profile per command, and macOS refuses nested
  # profile application, so Codex cannot be wrapped in the guard sandbox. Its own
  # policy engine can express the same deny, and it composes with — rather than
  # replaces — the existing workspace policy via `extends`.
  #
  # Verified 2026-09-08 with fake executables in an isolated CODEX_HOME:
  # a directory-level deny on a fake `.app` bundle blocked `sh -c <fake>` with
  # "Operation not permitted" and Node `spawnSync` with status 126, no marker
  # file was written, while ordinary commands and workspace writes still ran.
  #
  # SELECTION IS THE HARD PART, and this file cannot solve it alone:
  #   - `codex sandbox -P <name>` selects a profile explicitly (proof path).
  #   - `default_permissions` in a CODEX_HOME config selects it by default, but
  #     an explicit `-s/--sandbox` on the command line overrides it — and the
  #     recurring HAUSV dispatch passes `-s workspace-write`.
  #   - Only managed `/etc/codex/requirements.toml` forces the profile against
  #     such callers. Writing that file is a privileged operator step; this repo
  #     renders the exact content and never installs it.
  mkCodexPermissionsToml =
    {
      profileName,
      extends ? ":workspace",
      denyPaths,
    }:
    let
      name =
        if builtins.match "[a-z0-9][a-z0-9-]*" profileName != null then
          profileName
        else
          throw "agent-browser-guard: Codex profile name must be lowercase kebab-case (got: ${toString profileName})";
      denyLines = map (path: ''"${checkPath "Codex deny path" path}" = "deny"'') denyPaths;
    in
    ''
      # INSPR agent browser guard (NIX-445) — generated, do not hand-edit.
      # `extends` keeps the account's existing workspace policy; this profile only
      # removes native browser execution on top of it.
      [permissions.${name}]
      extends = "${extends}"

      [permissions.${name}.filesystem]
      ${lib.concatStringsSep "\n" denyLines}
    '';

  # Machine-wide managed requirements. Content only — installation is a reviewed
  # operator step (`sudo install -m 0644 … /etc/codex/requirements.toml`) with a
  # fake-binary verification afterwards. UNVERIFIED SCHEMA: the key layout below
  # follows the vendor managed-configuration documentation but has not been
  # exercised on this machine, because no /etc/codex/requirements.toml exists and
  # writing one needs a password. Verify, then keep or roll back.
  mkCodexRequirementsToml =
    {
      profileName,
      extends ? ":workspace",
      denyPaths,
    }:
    ''
      # INSPR agent browser guard (NIX-445) — managed Codex requirements.
      # Generated by nixcfg lib/agent-browser-guard.nix. Install path:
      #   /etc/codex/requirements.toml   (root-owned, 0644)
      # Forces the guarded permission profile even when a caller passes an
      # explicit `-s/--sandbox`, which ordinary `default_permissions` does not.
      default_permissions = "${profileName}"

      [allowed_permission_profiles]
      ${profileName} = {}

      ${mkCodexPermissionsToml { inherit profileName extends denyPaths; }}
    '';

  # Stable agent-facing refusal. Printed by the shim that replaces the browser
  # path in guarded sessions, and quoted in agent guidance so the wording an
  # agent sees matches the wording it was told to expect.
  mkRefusalText =
    { }:
    ''
      set -eu
      printf '%s\n' \
        'INSPR agent browser guard (NIX-445): native browser launch refused.' \
        "" \
        '  Agent worker sessions must not start a native browser on this Mac.' \
        '  Chrome aborts in macOS _RegisterApplication from a sandboxed agent' \
        '  session and disrupts the operator desktop.' \
        "" \
        '  Browser QA belongs to a verified controller-owned or remote runner.' \
        '  Ask the controller for it; if none is available, report browser QA as' \
        '  unavailable. Do not retry, do not look for another browser binary,' \
        '  and do not disable the guard.' \
        "" \
        '  A blocked launch is NOT a passed browser test. Report the refusal.' >&2
      exit 78
    '';

  # The guard launcher: applies the Seatbelt profile, then execs the real CLI.
  # argv is passed through untouched so a self-updating npm CLI keeps its own
  # identity and invocation.
  mkGuardText =
    {
      profilePath,
      refusalPath,
      sandboxExec ? "/usr/bin/sandbox-exec",
    }:
    let
      profile = checkPath "profile path" profilePath;
      sandbox = checkPath "sandbox-exec path" sandboxExec;
      envExports = mkHarnessEnvExports {
        inherit refusalPath;
        mode = "sandbox";
      };
    in
    ''
      set -eu

      if [ "$#" -lt 1 ]; then
        printf '%s\n' 'usage: inspr-agent-guard <absolute-program> [args...]' >&2
        exit 64
      fi

      program=$1
      shift

      case "$program" in
        /*) ;;
        *)
          printf '%s\n' 'inspr-agent-guard: program must be an absolute path' >&2
          exit 64
          ;;
      esac

      if [ ! -x "$program" ]; then
        printf '%s\n' "inspr-agent-guard: not executable: $program" >&2
        exit 64
      fi

      if [ ! -x ${lib.escapeShellArg sandbox} ]; then
        printf '%s\n' 'inspr-agent-guard: sandbox-exec missing — refusing to run unguarded' >&2
        exit 69
      fi

      ${envExports}

      # Fail closed: if the profile cannot be applied (for example because this
      # process already runs under a restrictive Seatbelt profile — see the
      # nesting limit in lib/agent-browser-guard.nix) we refuse rather than
      # silently running the CLI without the guard.
      exec ${lib.escapeShellArg sandbox} -f ${lib.escapeShellArg profile} "$program" "$@"
    '';

  # Env-only variant for entry points that apply their own Seatbelt profile
  # (Codex). No sandbox is applied — nesting is impossible on macOS — so this is
  # a harness fix, not a boundary. Callers must document it as such.
  mkEnvOnlyExports =
    refusalPath:
    mkHarnessEnvExports {
      inherit refusalPath;
      mode = "env-only";
    };
}
