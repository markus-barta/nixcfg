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
  # Two profiles, because this machine has two legitimate Codex modes.
  #   guarded-workspace  — extends the built-in ":workspace" baseline. The
  #     ordinary default; the two named accounts already run workspace-write.
  #   guarded-full       — NO extends, `":root" = "write"`, network enabled.
  #     The guarded stand-in for `--dangerously-bypass-approvals-and-sandbox`,
  #     which the root coordinator and the operator's own native sessions use
  #     today. Without it, a single workspace-only managed policy would silently
  #     break those authorized full-access workflows. Verified read-only on Codex
  #     0.153.4 with a fake executable: an outside-workspace write succeeded and
  #     the fake exec was denied, no marker written.
  # Both deny the same paths. Ordinary defaults stay workspace; full mode is
  # opt-in per invocation and is never the built-in unguarded bypass.
  mkCodexProfileBlock =
    {
      name,
      denyPaths,
      extends ? null,
      rootWrite ? false,
      rootRead ? false,
      networkEnabled ? false,
    }:
    let
      profile =
        if builtins.match "[a-z0-9][a-z0-9-]*" name != null then
          name
        else
          throw "agent-browser-guard: Codex profile name must be lowercase kebab-case (got: ${toString name})";
      denyLines = map (path: ''"${checkPath "Codex deny path" path}" = "deny"'') denyPaths;
      rootLine =
        lib.optional rootWrite ''":root" = "write"'' ++ lib.optional rootRead ''":root" = "read"'';
    in
    ''
      [permissions.${profile}]
      ${lib.optionalString (extends != null) ''extends = "${extends}"''}

      [permissions.${profile}.filesystem]
      ${lib.concatStringsSep "\n" (rootLine ++ denyLines)}
    ''
    + lib.optionalString networkEnabled ''

      [permissions.${profile}.network]
      enabled = true
    '';

  mkCodexPermissionsToml =
    {
      profileName,
      fullProfileName ? "${profileName}-full",
      readOnlyProfileName ? "${profileName}-readonly",
      extends ? ":workspace",
      denyPaths,
    }:
    ''
      # INSPR agent browser guard (NIX-445) — generated, do not hand-edit.
      # `extends` inherits Codex's BUILT-IN baseline named here (":workspace"),
      # NOT whatever a given account's config happens to set. Read that as: this
      # profile is workspace-scoped plus a browser deny. It does not replicate
      # per-account settings, and it must never be used to broaden one.
      ${mkCodexProfileBlock {
        name = profileName;
        inherit extends denyPaths;
      }}
      # Guarded stand-in for an explicit full-access launch: everything writable
      # and network enabled — approvals unchanged — minus the browser bundles.
      ${mkCodexProfileBlock {
        name = fullProfileName;
        inherit denyPaths;
        rootWrite = true;
        networkEnabled = true;
      }}
      # Guarded stand-in for an explicit READ-ONLY launch. Without it, a managed
      # allow-list that names only the workspace profile would silently BROADEN
      # an explicit read-only caller to workspace-write. Verified read-only on
      # Codex 0.153.4: a workspace write is refused, an ordinary read succeeds,
      # and the fake probe is denied.
      ${mkCodexProfileBlock {
        name = readOnlyProfileName;
        inherit denyPaths;
        rootRead = true;
      }}
    '';

  # Machine-wide managed requirements. Content only — installation is one
  # reviewed operator command that verifies and rolls itself back. The key layout
  # follows the vendor managed-configuration documentation; the allow-list value
  # is the documented BOOLEAN form.
  mkCodexRequirementsToml =
    {
      profileName,
      fullProfileName ? "${profileName}-full",
      readOnlyProfileName ? "${profileName}-readonly",
      extends ? ":workspace",
      denyPaths,
    }:
    ''
      # INSPR agent browser guard (NIX-445) — managed Codex requirements.
      # Generated by nixcfg lib/agent-browser-guard.nix. Install path:
      #   /etc/codex/requirements.toml   (root-owned, 0644)
      # Forces a guarded permission profile even when a caller passes an explicit
      # `-s/--sandbox`, which ordinary `default_permissions` does not.
      #
      # SCOPE: the default stays workspace-scoped, so accounts already configured
      # workspace-write are unchanged and a caller resolving to a broader default
      # is TIGHTENED. Explicit full-access launches are not banned — they are
      # routed to `${fullProfileName}`, which keeps root write and network and
      # only removes the browsers. An explicit read-only launch keeps read-only
      # scope through `${readOnlyProfileName}`; the workspace default must never
      # silently broaden it. Nothing here loosens any account, and the built-in
      # unguarded `danger-full-access` is never allow-listed.
      default_permissions = "${profileName}"

      [allowed_permission_profiles]
      ${profileName} = true
      ${fullProfileName} = true
      ${readOnlyProfileName} = true

      ${mkCodexPermissionsToml {
        inherit
          profileName
          fullProfileName
          readOnlyProfileName
          extends
          denyPaths
          ;
      }}
    '';

  # ── Node preload: accidental-launch prevention where no sandbox can apply ──
  # Cursor ships its own seatbelt helper, so it can be neither wrapped (macOS
  # refuses nested profiles — a real `cursor-agent --sandbox enabled` tool call
  # under the guard failed with `sandbox_apply` EPERM, exit 71) nor expressed
  # natively: its sandbox.json schema has no arbitrary filesystem deny, and a
  # `permissions.deny = [Read(<path>)]` rule does not reach the native shell
  # sandbox — both were measured with fake executables, and both let the fake
  # run. What is left is the actual launch chain: Node.
  #
  # This preload wraps spawn/spawnSync/execFile/execFileSync (including the
  # promisified execFile custom) and refuses before a denied executable starts.
  # It is cooperative and process-local: a direct shell/Python/Go/XPC launch or a
  # scrubbed NODE_OPTIONS escapes it. Never call it a boundary.
  defaultBrowserBasenames = [
    "Google Chrome"
    "Google Chrome Canary"
    "Google Chrome Beta"
    "Google Chrome Dev"
    "Chromium"
    "chromium"
    "chrome"
    "google-chrome"
    "google-chrome-stable"
    "Brave Browser"
    "Microsoft Edge"
    "msedge"
    "firefox"
    "Firefox"
    "Safari"
    "Zen"
    "Helium"
    "Arc"
  ];

  mkPreloadText =
    {
      denyPaths,
      denyBasenames ? defaultBrowserBasenames,
    }:
    let
      checked = map (checkPath "preload deny path") denyPaths;
      source = builtins.readFile ../modules/uzumaki/agent-browser-guard.cjs;
    in
    builtins.replaceStrings
      [ "@INSPR_DENY_PATHS@" "@INSPR_DENY_BASENAMES@" ]
      [ (builtins.toJSON checked) (builtins.toJSON denyBasenames) ]
      source;

  # Shell snippet that adds the preload to NODE_OPTIONS without discarding an
  # existing value and without adding it twice.
  mkPreloadEnvExports =
    preloadPath:
    let
      preload = checkPath "preload path" preloadPath;
    in
    ''
      case " ''${NODE_OPTIONS-} " in
        *" --require ${preload} "*) ;;
        *) NODE_OPTIONS="''${NODE_OPTIONS-} --require ${preload}"; export NODE_OPTIONS ;;
      esac
    '';

  # Self-test anchors.
  #
  # `codexProbePath` lives INSIDE the root-owned managed directory. It used to
  # sit in /private/var/tmp, which is mode 1777: a fixed, published name there
  # let any local user pre-create a symlink and turn the one command the operator
  # runs under sudo into an arbitrary root-owned truncate + chmod. The installer
  # additionally refuses to run if that directory is a symlink, is not owned by
  # root, or is group/world-writable.
  codexProbePath = "/etc/codex/inspr-nix445-probe";

  # Unprivileged anchor for the Node preload, used by the Cursor proof and by
  # tests. Deliberately separate from the root one: no privileged component ever
  # writes here, and no unprivileged component ever writes into /etc.
  defaultPreloadProbeRelative = "Library/Caches/inspr/agent-browser-guard/probe";

  # One reviewable operator command. Renders as a root-run script that validates
  # the managed directory BEFORE touching it, installs transactionally, PROVES
  # enforcement with a fake executable, and rolls back on any failure or signal
  # between mutation and verification. It never touches a browser, an account
  # credential, a model or the network.
  #
  # Proof scope, stated exactly: every check runs `codex sandbox
  # --include-managed-config`, which is the documented way to resolve managed
  # policy. A plain `codex exec` or app-server caller is covered by the same
  # managed default but is NOT exercised here — that is a separate post-install
  # check with the actual caller, and the banner says so.
  mkManagedInstallerText =
    {
      requirementsPath,
      profileName,
      fullProfileName,
      readOnlyProfileName,
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
      TARGET_DIR=$(dirname ${lib.escapeShellArg tgt})
      STAMP=${lib.escapeShellArg tgt}.inspr-nix445.sha256
      PROBE=${lib.escapeShellArg probe}
      PROFILE=${lib.escapeShellArg profileName}
      FULL_PROFILE=${lib.escapeShellArg fullProfileName}
      READONLY_PROFILE=${lib.escapeShellArg readOnlyProfileName}
      CODEX=${lib.escapeShellArg codex}
      SHASUM=/usr/bin/shasum

      mutation_intent=0
      verified=0
      adopted_foreign_identical=0
      new_sha=""
      pre_target_sha=""
      pre_stamp=""
      workdir=""

      usage() {
        printf '%s\n' \
          'usage: sudo inspr-codex-managed-install [--replace-existing]' \
          '       sudo inspr-codex-managed-install --rollback' \
          "" \
          "Installs the NIX-445 managed Codex requirements at $TARGET, proves" \
          'enforcement with a fake executable, and rolls back on any failure or' \
          'interrupt. Never launches a browser, never uses an account or model.' >&2
      }

      mode=install
      replace=0
      case "''${1-}" in
        --rollback) mode=rollback ;;
        --replace-existing) replace=1 ;;
        "") ;;
        *) usage; exit 64 ;;
      esac

      fail() {
        printf 'inspr-codex-managed-install: %s\n' "$1" >&2
        exit "''${2:-1}"
      }

      if [ "$(id -u)" != 0 ]; then
        fail 'must run as root (sudo); it writes /etc/codex' 77
      fi

      OPERATOR="''${SUDO_USER-}"
      if [ -z "$OPERATOR" ] || [ "$OPERATOR" = root ]; then
        fail 'SUDO_USER must be the operator — verification never runs as root' 77
      fi

      sha_of() {
        $SHASUM -a 256 "$1" | cut -d' ' -f1
      }

      # Restore strictly what THIS run put in place. A file that was never ours
      # is left alone, a file that changed under us is left alone, and a
      # pre-existing stamp is put back exactly as it was.
      restore() {
        if [ "$adopted_foreign_identical" = 1 ]; then
          printf '%s\n' 'left the pre-existing identical managed config untouched' >&2
          return 0
        fi
        if [ ! -e "$TARGET" ]; then
          [ -n "$pre_stamp" ] || rm -f "$STAMP"
          return 0
        fi
        if [ -n "$new_sha" ] && [ "$(sha_of "$TARGET")" != "$new_sha" ]; then
          printf '%s\n' "leaving $TARGET alone: it is not the file this run installed" >&2
          return 0
        fi
        if [ -z "$new_sha" ] && [ ! -f "$STAMP" ]; then
          printf '%s\n' "refusing to touch $TARGET: no NIX-445 stamp — it is not ours" >&2
          return 0
        fi
        if [ -z "$new_sha" ] && [ "$(cat "$STAMP")" != "$(sha_of "$TARGET")" ]; then
          printf '%s\n' "refusing to touch $TARGET: it changed since we installed it" >&2
          return 0
        fi
        backup=$(ls -1t "$TARGET".pre-inspr-nix445.* 2>/dev/null | head -n 1 || true)
        if [ -n "$backup" ] && [ ! -L "$backup" ]; then
          cat "$backup" >"$TARGET"
          chmod 0644 "$TARGET"
          [ "$(id -u)" = 0 ] && chown root:wheel "$TARGET"
          printf 'restored previous managed config from %s\n' "$backup" >&2
        else
          rm -f "$TARGET"
          printf 'removed %s\n' "$TARGET" >&2
        fi
        if [ -n "$pre_stamp" ]; then
          printf '%s\n' "$pre_stamp" >"$STAMP"
        else
          rm -f "$STAMP"
        fi
      }

      cleanup_probe() {
        [ -n "$workdir" ] && rm -rf "$workdir"
        if [ -e "$PROBE" ] && [ ! -L "$PROBE" ]; then
          rm -f "$PROBE"
        fi
        return 0
      }

      if [ "$mode" = rollback ]; then
        restore
        printf '%s\n' 'codex_managed_guard=rolled-back' >&2
        exit 0
      fi

      [ -r "$SOURCE" ] || fail "rendered requirements missing: $SOURCE"
      [ -x "$CODEX" ] || fail "Codex CLI not found at $CODEX"
      [ -x "$SHASUM" ] || fail "shasum not found at $SHASUM"

      # Validate an EXISTING managed directory before touching it: `install -d`
      # would silently normalise unsafe ownership or mode instead of refusing.
      if [ -L "$TARGET_DIR" ]; then
        fail "$TARGET_DIR is a symlink — refusing to write through it" 3
      fi
      if [ -e "$TARGET_DIR" ]; then
        [ -d "$TARGET_DIR" ] || fail "$TARGET_DIR exists and is not a directory" 3
        dir_owner=$(/usr/bin/stat -f '%u' "$TARGET_DIR")
        dir_mode=$(/usr/bin/stat -f '%OLp' "$TARGET_DIR")
        [ "$dir_owner" = 0 ] || fail "$TARGET_DIR is not owned by root — refusing" 3
        case "$dir_mode" in
          *[2367]) fail "$TARGET_DIR is group- or world-writable — refusing" 3 ;;
        esac
      else
        /usr/bin/install -d -m 0755 -o root -g wheel "$TARGET_DIR"
      fi

      # Every predictable path this script writes must be a real file, never a
      # pre-planted symlink.
      for guarded_path in "$TARGET" "$STAMP" "$PROBE"; do
        if [ -L "$guarded_path" ]; then
          fail "$guarded_path is a symlink — refusing to write through it" 3
        fi
      done

      [ -f "$STAMP" ] && pre_stamp=$(cat "$STAMP")

      if [ -e "$TARGET" ]; then
        [ -f "$TARGET" ] || fail "$TARGET exists and is not a regular file" 3
        pre_target_sha=$(sha_of "$TARGET")
        if cmp -s "$TARGET" "$SOURCE"; then
          if [ -n "$pre_stamp" ] && [ "$pre_stamp" = "$pre_target_sha" ]; then
            printf '%s\n' 'target already byte-identical and ours; re-validating only' >&2
          else
            adopted_foreign_identical=1
            printf '%s\n' 'target already byte-identical but not ours; validating without claiming it' >&2
          fi
        elif [ -n "$pre_stamp" ] && [ "$pre_stamp" = "$pre_target_sha" ]; then
          printf '%s\n' 'replacing an older NIX-445 managed config' >&2
        elif [ "$replace" = 1 ]; then
          backup_path=$TARGET.pre-inspr-nix445.$(date -u +%Y%m%dT%H%M%SZ)
          [ -L "$backup_path" ] && fail "$backup_path is a symlink — refusing" 3
          /usr/bin/install -m 0600 -o root -g wheel "$TARGET" "$backup_path"
          printf 'backed up existing managed config to %s\n' "$backup_path" >&2
        else
          fail "$TARGET exists and is not ours — re-run with --replace-existing to back it up first" 3
        fi
      fi

      on_exit() {
        status=$?
        cleanup_probe
        rm -f "''${tmp-}" 2>/dev/null || true
        if [ "$mutation_intent" = 1 ] && [ "$verified" != 1 ]; then
          printf '%s\n' 'inspr-codex-managed-install: unverified install — rolling back' >&2
          restore
        fi
        exit "$status"
      }
      trap on_exit EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM

      if [ "$adopted_foreign_identical" = 0 ]; then
        tmp=$(mktemp "$TARGET_DIR/.requirements.XXXXXX")
        cat "$SOURCE" >"$tmp"
        chown root:wheel "$tmp"
        chmod 0644 "$tmp"
        new_sha=$(sha_of "$tmp")

        # Intent is recorded BEFORE the mutation, so a signal landing between the
        # rename and any later statement still rolls back. Provenance, not a
        # flag set after the fact, decides what actually happened: the trap only
        # touches a target whose checksum is the one this run wrote.
        mutation_intent=1
        printf '%s\n' "$new_sha" >"$STAMP"
        chmod 0644 "$STAMP"
        chown root:wheel "$STAMP"
        mv -f "$tmp" "$TARGET"
      else
        mutation_intent=1
      fi

      # ── Proof, as the operator, in an isolated CODEX_HOME, fake binary only ──
      printf '#!/bin/sh\necho INSPR_PROBE_RAN\n' >"$PROBE"
      chmod 0755 "$PROBE"
      chown root:wheel "$PROBE"

      workdir=$(mktemp -d "$TARGET_DIR/.verify.XXXXXX")
      chown "$OPERATOR" "$workdir"
      /usr/bin/sudo -u "$OPERATOR" /bin/mkdir -p "$workdir/home" "$workdir/ws"

      abort() {
        printf 'inspr-codex-managed-install: verification failed (%s)\n' "$1" >&2
        exit 4
      }

      run_as_operator() {
        /usr/bin/sudo -u "$OPERATOR" /usr/bin/env CODEX_HOME="$workdir/home" "$CODEX" \
          sandbox --include-managed-config "$@" 2>&1 || true
      }

      expect_denied() {
        case "$2" in
          *INSPR_PROBE_RAN*) abort "$1 executed the probe binary" ;;
          *"not permitted"*) ;;
          *) abort "$1 produced no recognisable denial: $2" ;;
        esac
      }

      out=$(run_as_operator -P "$PROFILE" -C "$workdir/ws" -- /bin/echo PARSE_OK)
      case "$out" in
        *PARSE_OK*) ;;
        *) abort "managed config did not parse or profile did not resolve: $out" ;;
      esac

      out=$(run_as_operator -P "$PROFILE" -C "$workdir/ws" -- \
        /bin/sh -c 'touch ./inspr-write-probe && echo WRITE_OK')
      case "$out" in
        *WRITE_OK*) ;;
        *) abort "guarded workspace profile lost the ordinary workspace write: $out" ;;
      esac

      expect_denied "explicit selection" \
        "$(run_as_operator -P "$PROFILE" -C "$workdir/ws" -- /bin/sh -c "$PROBE")"
      expect_denied "default selection" \
        "$(run_as_operator -C "$workdir/ws" -- /bin/sh -c "$PROBE")"
      expect_denied "legacy sandbox override" \
        "$(run_as_operator -c sandbox_mode=danger-full-access -C "$workdir/ws" -- /bin/sh -c "$PROBE")"

      # Guarded full access must keep full access — otherwise a single managed
      # workspace policy would silently break the authorized full-access
      # workflows this machine actually runs — while still refusing the probe,
      # and it must be selectable through the config key `inspr-codex-full` uses.
      out=$(run_as_operator -P "$FULL_PROFILE" -C "$workdir/ws" -- \
        /bin/sh -c "touch $workdir/outside-probe && echo FULL_WRITE_OK")
      case "$out" in
        *FULL_WRITE_OK*) ;;
        *) abort "guarded full profile lost outside-workspace write: $out" ;;
      esac
      expect_denied "guarded full profile" \
        "$(run_as_operator -P "$FULL_PROFILE" -C "$workdir/ws" -- /bin/sh -c "$PROBE")"
      expect_denied "full profile via config key" \
        "$(run_as_operator -c default_permissions="$FULL_PROFILE" -C "$workdir/ws" -- /bin/sh -c "$PROBE")"

      # An explicit read-only selection must STAY read-only. If the workspace
      # default silently broadened it to workspace-write, that would be a
      # regression introduced by this guard, so it fails the install.
      out=$(run_as_operator -P "$READONLY_PROFILE" -C "$workdir/ws" -- \
        /bin/sh -c 'touch ./inspr-readonly-probe && echo READONLY_WROTE')
      case "$out" in
        *READONLY_WROTE*) abort "guarded read-only profile was broadened to write" ;;
      esac
      expect_denied "guarded read-only profile" \
        "$(run_as_operator -P "$READONLY_PROFILE" -C "$workdir/ws" -- /bin/sh -c "$PROBE")"

      # A built-in profile must not be selectable once the managed allow-list
      # names only the guarded ones.
      out=$(run_as_operator -P :workspace -C "$workdir/ws" -- /bin/echo BUILTIN_OK)
      case "$out" in
        *BUILTIN_OK*) abort "managed allow-list did not reject the built-in :workspace profile" ;;
      esac

      verified=1
      printf '%s\n' \
        "codex_managed_guard=installed target=$TARGET" \
        'proof=fake probe denied under explicit, default and legacy-override selection;' \
        'guarded-full keeps root write, guarded-read-only stays read-only, builtin rejected' \
        'scope=proved through `codex sandbox --include-managed-config` only.' \
        'A plain `codex exec` / app-server caller is covered by the same managed' \
        'default but is NOT proved here — check one real caller after restarting' \
        'the Codex app-server, and treat plain callers as unproven until then.' >&2
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
      preloadPath ? null,
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
      ${lib.optionalString (preloadPath != null) (mkPreloadEnvExports preloadPath)}

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
