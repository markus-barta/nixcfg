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
  # policy engine can express the same deny.
  #
  # SCOPE, STATED EXACTLY (no overclaim):
  #   `extends = ":workspace"` inherits Codex's BUILT-IN workspace baseline. It
  #   does not read, merge or preserve an account's own config. On this machine
  #   the two named accounts already run `sandbox_mode = "workspace-write"` with
  #   `approval_policy = "on-request"`, so a managed workspace-scoped profile
  #   matches what they do today and does not broaden them. The `agent.one`
  #   account home sets none of these keys and currently resolves to Codex's own
  #   default; a managed default_permissions TIGHTENS such a caller to workspace
  #   scope rather than leaving it wherever the default lands. That tightening is
  #   the point, and it is stated here so it is reviewed, not discovered.
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
      # `extends` inherits Codex's BUILT-IN baseline named here (":workspace"),
      # NOT whatever a given account's config happens to set. Read that as: this
      # profile is workspace-scoped plus a browser deny. It does not replicate
      # per-account settings, and it must never be used to broaden one.
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
      #
      # SCOPE: workspace baseline plus the browser deny, for every Codex caller
      # on this machine. Accounts already configured workspace-write are
      # unchanged; a caller that today resolves to a broader default is TIGHTENED
      # to workspace scope. Nothing here loosens any account.
      default_permissions = "${profileName}"

      # Vendor managed-configuration docs require a BOOLEAN here, not a table:
      # `<name> = true`. An invalid managed config can stop Codex starting at
      # all, so the installer parses and proves this file before keeping it.
      [allowed_permission_profiles]
      ${profileName} = true

      ${mkCodexPermissionsToml { inherit profileName extends denyPaths; }}
    '';

  # Self-test anchor. Included in every rendered Codex deny list so the managed
  # installer can prove enforcement by exec'ing a FAKE executable at this path,
  # instead of touching a real browser. Nothing legitimate ever lives here.
  codexProbePath = "/private/var/tmp/inspr-browser-guard-probe";

  # One reviewable operator command. Renders as a root-run script that
  # preflights, backs up, installs, PROVES enforcement with a fake executable,
  # and rolls back its own file on any failure. It never touches a browser, an
  # account credential, a model or the network, and it refuses to clobber an
  # unrelated managed config.
  mkManagedInstallerText =
    {
      requirementsPath,
      profileName,
      codexBinary,
      probePath ? codexProbePath,
      target ? "/etc/codex/requirements.toml",
    }:
    let
      src = checkPath "rendered requirements path" requirementsPath;
      tgt = checkPath "managed requirements target" target;
      probe = checkPath "probe path" probePath;
      codex = checkPath "Codex binary" codexBinary;
    in
    ''
      set -eu
      umask 022

      SOURCE=${lib.escapeShellArg src}
      TARGET=${lib.escapeShellArg tgt}
      STAMP=${lib.escapeShellArg tgt}.inspr-nix445.sha256
      PROBE=${lib.escapeShellArg probe}
      PROFILE=${lib.escapeShellArg profileName}
      CODEX=${lib.escapeShellArg codex}
      SHASUM=/usr/bin/shasum

      usage() {
        printf '%s\n' \
          'usage: sudo inspr-codex-managed-install [--replace-existing]' \
          '       sudo inspr-codex-managed-install --rollback' \
          "" \
          "Installs the NIX-445 managed Codex requirements at $TARGET, then proves" \
          'enforcement with a fake executable. Rolls its own file back on any' \
          'failure. Never launches a browser and never uses an account or model.' >&2
      }

      mode=install
      replace=0
      case "''${1-}" in
        --rollback) mode=rollback ;;
        --replace-existing) replace=1 ;;
        "") ;;
        *) usage; exit 64 ;;
      esac

      if [ "$(id -u)" != 0 ]; then
        printf '%s\n' 'inspr-codex-managed-install: must run as root (sudo); it writes /etc/codex' >&2
        exit 77
      fi

      OPERATOR="''${SUDO_USER-}"
      if [ -z "$OPERATOR" ] || [ "$OPERATOR" = root ]; then
        printf '%s\n' 'inspr-codex-managed-install: SUDO_USER must be the operator — validation never runs as root' >&2
        exit 77
      fi

      fail() {
        printf 'inspr-codex-managed-install: %s\n' "$1" >&2
        exit "''${2:-1}"
      }

      # Restore strictly what THIS installer put in place: the file is only
      # removed when its checksum still matches the recorded stamp.
      restore() {
        if [ ! -e "$TARGET" ]; then
          printf '%s\n' 'nothing installed at the target' >&2
          return 0
        fi
        if [ ! -f "$STAMP" ]; then
          fail "refusing to touch $TARGET: no NIX-445 stamp — it is not ours" 3
        fi
        recorded=$(cat "$STAMP")
        current=$($SHASUM -a 256 "$TARGET" | cut -d' ' -f1)
        if [ "$recorded" != "$current" ]; then
          fail "refusing to touch $TARGET: it changed since we installed it" 3
        fi
        backup=$(ls -1t "$TARGET".pre-inspr-nix445.* 2>/dev/null | head -n 1 || true)
        if [ -n "$backup" ]; then
          /usr/bin/install -m 0644 -o root -g wheel "$backup" "$TARGET"
          printf 'restored previous managed config from %s\n' "$backup" >&2
        else
          rm -f "$TARGET"
          printf 'removed %s\n' "$TARGET" >&2
        fi
        rm -f "$STAMP"
      }

      if [ "$mode" = rollback ]; then
        restore
        printf '%s\n' 'codex_managed_guard=rolled-back' >&2
        exit 0
      fi

      [ -r "$SOURCE" ] || fail "rendered requirements missing: $SOURCE"
      [ -x "$CODEX" ] || fail "Codex CLI not found at $CODEX"
      [ -x "$SHASUM" ] || fail "shasum not found at $SHASUM"

      /usr/bin/install -d -m 0755 -o root -g wheel "$(dirname "$TARGET")"

      if [ -e "$TARGET" ]; then
        if cmp -s "$TARGET" "$SOURCE"; then
          printf '%s\n' 'target already byte-identical; re-validating only' >&2
        elif [ -f "$STAMP" ] \
          && [ "$(cat "$STAMP")" = "$($SHASUM -a 256 "$TARGET" | cut -d' ' -f1)" ]; then
          printf '%s\n' 'replacing an older NIX-445 managed config' >&2
        elif [ "$replace" = 1 ]; then
          stampdir=$TARGET.pre-inspr-nix445.$(date -u +%Y%m%dT%H%M%SZ)
          /usr/bin/install -m 0600 -o root -g wheel "$TARGET" "$stampdir"
          printf 'backed up existing managed config to %s\n' "$stampdir" >&2
        else
          fail "$TARGET exists and is not ours — re-run with --replace-existing to back it up first" 3
        fi
      fi

      tmp=$(mktemp "$(dirname "$TARGET")/.requirements.XXXXXX")
      trap 'rm -f "$tmp"' EXIT
      cat "$SOURCE" >"$tmp"
      chown root:wheel "$tmp"
      chmod 0644 "$tmp"
      mv -f "$tmp" "$TARGET"
      trap - EXIT
      $SHASUM -a 256 "$TARGET" | cut -d' ' -f1 >"$STAMP"
      chmod 0644 "$STAMP"
      chown root:wheel "$STAMP"

      # ── Proof, as the operator, in an isolated CODEX_HOME, fake binary only ──
      workdir=$(mktemp -d /private/tmp/inspr-nix445-verify.XXXXXX)
      chown "$OPERATOR" "$workdir"
      printf '#!/bin/sh\necho INSPR_PROBE_RAN\n' >"$PROBE"
      chmod 0755 "$PROBE"

      cleanup_proof() {
        rm -rf "$workdir"
        rm -f "$PROBE"
      }

      abort() {
        cleanup_proof
        printf 'inspr-codex-managed-install: verification failed (%s) — rolling back\n' "$1" >&2
        restore
        exit 4
      }

      run_as_operator() {
        /usr/bin/sudo -u "$OPERATOR" /usr/bin/env CODEX_HOME="$workdir/home" "$CODEX" "$@" 2>&1 || true
      }
      /usr/bin/sudo -u "$OPERATOR" /bin/mkdir -p "$workdir/home" "$workdir/ws"

      out=$(run_as_operator sandbox --include-managed-config -P "$PROFILE" -C "$workdir/ws" -- /bin/echo PARSE_OK)
      case "$out" in
        *PARSE_OK*) ;;
        *) abort "managed config did not parse or profile did not resolve: $out" ;;
      esac

      out=$(run_as_operator sandbox --include-managed-config -P "$PROFILE" -C "$workdir/ws" -- \
        /bin/sh -c 'touch ./inspr-write-probe && echo WRITE_OK')
      case "$out" in
        *WRITE_OK*) ;;
        *) abort "guarded profile lost the ordinary workspace write: $out" ;;
      esac

      # Explicit selection, default selection, and a legacy override attempt must
      # all refuse to execute the fake probe binary.
      for attempt in explicit default legacy; do
        case "$attempt" in
          explicit) out=$(run_as_operator sandbox --include-managed-config -P "$PROFILE" -C "$workdir/ws" -- /bin/sh -c "$PROBE") ;;
          default) out=$(run_as_operator sandbox --include-managed-config -C "$workdir/ws" -- /bin/sh -c "$PROBE") ;;
          legacy) out=$(run_as_operator sandbox --include-managed-config -c sandbox_mode=danger-full-access -C "$workdir/ws" -- /bin/sh -c "$PROBE") ;;
        esac
        case "$out" in
          *INSPR_PROBE_RAN*) abort "$attempt selection still executed the probe binary" ;;
          *"not permitted"*) ;;
          *) abort "$attempt selection produced no recognisable denial: $out" ;;
        esac
      done

      # A built-in profile must not be selectable once managed config allow-lists
      # only the guarded one.
      out=$(run_as_operator sandbox --include-managed-config -P :workspace -C "$workdir/ws" -- /bin/echo BUILTIN_OK)
      case "$out" in
        *BUILTIN_OK*) abort "managed allow-list did not reject the built-in :workspace profile" ;;
      esac

      cleanup_proof
      printf '%s\n' \
        'codex_managed_guard=installed target='"$TARGET" \
        'proof=fake-probe-denied explicit+default+legacy, workspace-write kept, builtin rejected' \
        'restart the Codex app-server so it reloads policy' >&2
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
