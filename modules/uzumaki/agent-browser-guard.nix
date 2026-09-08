# NIX-445 — declarative macOS agent browser-launch guard (Home Manager)
#
# Prevents agent worker sessions from executing a native browser, before the
# browser process starts, without modifying any browser app bundle, any vendor
# CLI, or macOS security settings. Rationale, the measured Seatbelt behaviour
# and the proven nesting limit live in lib/agent-browser-guard.nix.
#
# FIVE LAYERS, DELIBERATELY DIFFERENT IN STRENGTH
#   1. Seatbelt boundary — `inspr-agent-guard <program>` runs the program under a
#      profile that denies `process-exec*` on every browser bundle. Inherited by
#      all descendants, including Node/Playwright grandchildren.
#
#      THE INHERITANCE CUTS BOTH WAYS, and this is the D1 decision made here:
#      a guarded session's descendants cannot apply their own Seatbelt profile
#      either, so Codex and Cursor started BENEATH a guarded Claude die with
#      `sandbox_apply: Operation not permitted`. The live topology on this Mac is
#      a Claude controller dispatching Codex and Cursor workers. Therefore the
#      default route for every dispatch-capable entry point — the same-name shell
#      launchers and the agentd-owned CLIs — is env+preload, NOT this profile.
#      The strict route stays available and opt-in for leaf workers that never
#      dispatch another agent: the `*-guarded` launchers and
#      `paimosAgentd.browserGuard.sandboxedClis` (empty by default). Strict
#      wrappers are re-entrant: inside an existing guard they exec directly
#      rather than failing on a second `sandbox_apply`.
#      Consequence, stated plainly: after activation the only OS-level boundary
#      in the default path is Codex's own permission profile, and only once the
#      managed config is installed. Everything else is layer 3 and 4.
#   2. Codex native policy — Codex applies its own Seatbelt profile per command,
#      and macOS refuses nested profiles, so Codex is covered by an equivalent
#      deny inside ITS OWN permission profile (`extends = ":workspace"` plus a
#      filesystem deny). Measured working with fake executables on Codex 0.153.4;
#      see lib/agent-browser-guard.nix. Rendering is declarative here; SELECTING
#      the profile machine-wide is a privileged operator step (below).
#   3. Node preload — a CommonJS module added to NODE_OPTIONS that refuses
#      spawn/spawnSync/execFile/execFileSync (and the promisified execFile)
#      before a denied executable starts. This is the Cursor answer and a
#      defence-in-depth layer elsewhere. Cooperative and process-local: a direct
#      shell/Python/Go/XPC launch or a scrubbed NODE_OPTIONS escapes it, so it is
#      accidental-launch prevention, NOT a boundary.
#   4. Harness hints — guarded launchers point PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH,
#      PUPPETEER_EXECUTABLE_PATH and CHROME_PATH at a refusal shim instead of the
#      NIX-288 native Chrome path. These are HINTS, not a boundary: a harness that
#      hardcodes a path never reads them. Their value is turning an opaque EPERM
#      into a stable, explained refusal.
#   5. Guidance — AGENTS-NIXCFG.md tells agents what the refusal means, that a
#      blocked launch is not a passed test, and that browser QA belongs to a
#      verified controller-owned or remote runner.
#
# OPERATOR ACTIVATION STEPS THIS MODULE CANNOT PERFORM (by design)
#   a. Machine-wide Codex enforcement. An ordinary per-account
#      `default_permissions` is overridden by an explicit `-s/--sandbox` on the
#      command line, and the recurring HAUSV dispatch passes `-s workspace-write`.
#      Only managed `/etc/codex/requirements.toml` forces the profile. Install:
#        sudo install -d -m 0755 /etc/codex
#        sudo install -m 0644 \
#          ~/.config/inspr/agent-browser-guard/codex-requirements.toml \
#          /etc/codex/requirements.toml
#      Then VERIFY with a fake binary (never a browser) before trusting it, and
#      `sudo rm /etc/codex/requirements.toml` to roll back. The rendered schema
#      follows vendor documentation but has not been exercised on this machine.
#      One command does all of it, including rollback on failure:
#        sudo inspr-codex-managed-install            # refuses to clobber a
#        sudo inspr-codex-managed-install --replace-existing   # foreign config
#        sudo inspr-codex-managed-install --rollback  # checksum-guarded restore
#      The installer proves enforcement through `codex sandbox`, including a
#      flagless invocation; `codex exec` and the app-server are covered by the
#      same managed default but are NOT exercised by that proof, so treat plain
#      absolute callers as covered only after a fresh-session check.
#
#      Two profiles are rendered, because this machine has two legitimate modes:
#      a workspace-scoped default, and a guarded FULL-access profile (no
#      `extends`, `":root" = "write"`, network enabled, same browser denies) for
#      the launches that today pass `--dangerously-bypass-approvals-and-sandbox`.
#      `inspr-codex-full` maps that flag onto the guarded-full profile and keeps
#      approvals non-interactive, so authorized full-access work keeps working
#      without ever running the built-in unguarded bypass. Ordinary defaults stay
#      workspace-scoped; no account is broadened.
#   b. Cursor has NO sandbox-grade coverage, and this is settled, not pending:
#        - wrapped in the Seatbelt guard, a real `cursor-agent --sandbox enabled
#          --auto-review` tool call died with `sandbox_apply` EPERM, exit 71
#          (`--help` passes and proves nothing — it starts no tool sandbox);
#        - its sandbox.json schema has no arbitrary filesystem deny;
#        - a `permissions.deny = [Read(<abs fake>)]` rule does not reach the
#          native shell sandbox: the fake executed and wrote its marker.
#      So Cursor gets the env-only launcher: harness hints plus the Node preload.
#      Composer and Grok run through the same harness and inherit it. Do not
#      propose a Read-deny or a `--help` proof again.
#   c. KNOWN ABSOLUTE CALLERS TO MIGRATE (named, not hand-waved):
#        ~/.local/share/inspr/codex/bin/codex-admin
#        ~/.local/share/inspr/codex/bin/codex-markus
#      are operator-owned Python shims that `execve` the absolute
#      ~/.npm-global/bin/codex, and the agent.one guide uses that absolute path
#      directly. Managed Codex policy (a) reaches them without any change,
#      because it is machine-wide — but their full-access launches keep using the
#      built-in bypass until they are pointed at `inspr-codex-full`, which is the
#      exported guarded launcher for exactly that. Nothing here edits those shims
#      or any credential: they are declaratively unowned, so migration is an
#      operator step after the reviewed install.
#   d. RAW ABSOLUTE CALLERS REQUIRE FRESH GUARDED ENTRY POINTS. Anything that
#      invokes a vendor binary by absolute path — the operator-owned imperative
#      Codex shims, a script holding ~/.npm-global/bin/claude, a dispatcher
#      holding the pinned cursor-agent path — bypasses every PATH-based launcher
#      here by construction. Managed Codex (a) closes that for Codex only. The
#      rest must be migrated to the guarded entry points; until each one is,
#      it is uncovered, and saying otherwise would be false.
#   e. Codex app-server picks up policy at start: restart it after (a).
#
# WHAT THIS MODULE DOES NOT DO
#   - It does not touch `home.sessionVariables`. Ordinary human shells keep the
#     NIX-288 export (modules/uzumaki/macos-common.nix → playwrightSessionVars)
#     and normal browser use from Finder/Dock/Spotlight is unaffected.
#   - It never shadows `codex`: wrapping it would break its own sandbox. Other
#     CLIs get same-name launchers in a dedicated directory placed ahead of
#     ~/.npm-global/bin and /opt/homebrew/bin — by fish `shellInit` and by zsh
#     `envExtra` (.zshenv, which non-interactive `zsh -c` also reads). bash, sh
#     scripts and launchd jobs are NOT covered by PATH, and callers that hardcode
#     an absolute vendor path bypass it by construction — see the migration items.
#   - It writes nothing into a CODEX_HOME, /etc, a vendor npm package or a
#     browser app bundle.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.uzumaki.agentBrowserGuard;
  guardLib = import ../../lib/agent-browser-guard.nix { inherit lib; };

  profile = pkgs.writeText "inspr-agent-browser-guard.sb" (
    guardLib.mkProfileText {
      inherit (cfg) browserBundles extraDenyPaths denyLaunchServices;
    }
  );

  refusal = pkgs.writeShellScriptBin "inspr-browser-guard-refuse" (guardLib.mkRefusalText { });
  refusalPath = "${refusal}/bin/inspr-browser-guard-refuse";

  # Node preload: the only lever left for CLIs that sandbox themselves and have
  # no native filesystem deny (Cursor). Cooperative, process-local, NOT a
  # boundary — see the header of modules/uzumaki/agent-browser-guard.cjs.
  preload = pkgs.writeText "inspr-browser-guard-preload.cjs" (
    guardLib.mkPreloadText { denyPaths = codexDenyPaths; }
  );
  preloadPath = "${preload}";
  # Harness hints + preload, no Seatbelt profile. Used where a profile cannot be
  # applied without breaking the CLI's own sandbox.
  envOnlyPrefix =
    guardLib.mkEnvOnlyExports refusalPath + "\n" + guardLib.mkPreloadEnvExports preloadPath;

  guard = pkgs.writeShellScriptBin "inspr-agent-guard" (
    guardLib.mkGuardText {
      profilePath = "${profile}";
      inherit refusalPath preloadPath;
    }
  );
  guardPath = "${guard}/bin/inspr-agent-guard";

  # Codex cannot be wrapped (macOS refuses nested Seatbelt profiles); it carries
  # the same deny in its OWN permission policy instead. Rendered here, installed
  # by the operator — see the activation checklist in the option descriptions.
  # Self-test anchors, not browsers. The root one lives inside the root-owned
  # managed directory (a fixed name in world-writable /private/var/tmp would be a
  # symlink trap for the one sudo command). The unprivileged one is what the
  # Node preload proof and the tests use; nothing privileged ever writes there.
  codexDenyPaths =
    cfg.browserBundles
    ++ cfg.extraDenyPaths
    ++ [
      guardLib.codexProbePath
      cfg.preloadProbePath
    ];
  codexProfile = pkgs.writeText "codex-permissions.toml" (
    guardLib.mkCodexPermissionsToml {
      inherit (cfg.codexPermissions)
        profileName
        fullProfileName
        readOnlyProfileName
        extends
        ;
      denyPaths = codexDenyPaths;
    }
  );
  codexRequirements = pkgs.writeText "codex-requirements.toml" (
    guardLib.mkCodexRequirementsToml {
      inherit (cfg.codexPermissions)
        profileName
        fullProfileName
        readOnlyProfileName
        extends
        ;
      denyPaths = codexDenyPaths;
    }
  );

  # ONE reviewable operator command: preflight, owner-only backup, root-owned
  # install, enforcement proof with a fake executable, automatic rollback on any
  # failure. Rendered here; running it needs a password and stays the operator's.
  managedInstaller = pkgs.writeShellScriptBin "inspr-codex-managed-install" (
    guardLib.mkManagedInstallerText {
      requirementsPath = "${codexRequirements}";
      inherit (cfg.codexPermissions)
        profileName
        fullProfileName
        readOnlyProfileName
        codexBinary
        ;
    }
  );

  # Stable, non-Seatbelt route for an explicit full-access Codex launch. The
  # coordinator and the operator's own native sessions run with
  # `--dangerously-bypass-approvals-and-sandbox`; forcing them to workspace scope
  # would break authorized work, and leaving them on the built-in bypass would
  # leave the browser reachable. This maps that flag onto the guarded-full
  # profile, keeps approvals non-interactive as the flag implied, and passes
  # everything else — including CODEX_HOME and auth — through untouched.
  codexFullLauncher = pkgs.writeShellScriptBin "inspr-codex-full" ''
    set -eu
    args=()
    saw_bypass=0
    saw_approval=0
    for arg in "$@"; do
      case "$arg" in
        --dangerously-bypass-approvals-and-sandbox) saw_bypass=1 ;;
        --ask-for-approval | -a | --ask-for-approval=*) saw_approval=1; args+=("$arg") ;;
        *) args+=("$arg") ;;
      esac
    done
    if [ "$saw_bypass" = 0 ]; then
      printf '%s\n' 'inspr-codex-full: expects --dangerously-bypass-approvals-and-sandbox; use codex directly otherwise' >&2
      exit 64
    fi
    set -- -c ${lib.escapeShellArg "default_permissions=\"${cfg.codexPermissions.fullProfileName}\""}
    if [ "$saw_approval" = 0 ]; then
      set -- "$@" --ask-for-approval never
    fi
    exec ${lib.escapeShellArg cfg.codexPermissions.codexBinary} "$@" "''${args[@]}"
  '';

  # Named guarded launcher: `exec` keeps argv, signals and the caller's
  # environment intact, so a self-updating npm CLI behind an absolute path
  # stays exactly the CLI the operator authenticated.
  mkWrapper =
    name: target:
    pkgs.writeShellScriptBin name ''
      # Re-entrancy: the profile is inherited by every descendant, and macOS
      # refuses to apply a second one. If we are already inside our own guard,
      # exec the vendor path directly — the outer profile still covers this
      # process — instead of dying on `sandbox_apply`.
      if [ "''${INSPR_AGENT_BROWSER_GUARD-}" = sandbox ]; then
        exec ${lib.escapeShellArg target} "$@"
      fi
      exec ${lib.escapeShellArg guardPath} ${lib.escapeShellArg target} "$@"
    '';
  # Env-only launcher: same vendor path, same argv, no Seatbelt profile. For
  # Cursor, whose own seatbelt helper cannot live inside another profile.
  mkEnvOnlyWrapper =
    name: target:
    pkgs.writeShellScriptBin name ''
      ${envOnlyPrefix}
      exec ${lib.escapeShellArg target} "$@"
    '';
  wrappers = lib.mapAttrsToList mkWrapper cfg.guardedPrograms;
  hasLaunchers = cfg.shadowedPrograms != { } || cfg.envOnlyPrograms != { };

  # PATH-shadowing launchers: same command NAME as the vendor CLI, in a directory
  # of their own that fish puts ahead of ~/.npm-global/bin and /opt/homebrew/bin.
  # This is what makes existing callers — `claude`, the `cla`/`clar` aliases,
  # `grok` from either resolution — go through the guard without renaming
  # anything. Absolute-path callers still bypass it by construction; those are
  # listed in the migration checklist rather than claimed as covered.
  shadowBin = pkgs.symlinkJoin {
    name = "inspr-agent-guard-shadow-bin";
    paths =
      lib.mapAttrsToList mkWrapper cfg.shadowedPrograms
      ++ lib.mapAttrsToList mkEnvOnlyWrapper cfg.envOnlyPrograms;
  };
in
{
  options.uzumaki.agentBrowserGuard = {
    enable = lib.mkEnableOption "the shared macOS agent browser-launch guard (NIX-445)";

    browserBundles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = guardLib.defaultBrowserBundles;
      description = ''
        Absolute REALPATHs of native browser app bundles denied inside guarded
        sessions. Seatbelt matches resolved paths, so a symlinked bundle path
        (for example /Applications/Safari.app) silently never matches — list the
        target instead. Entries that are not installed are harmless.
      '';
    };

    extraDenyPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Additional absolute realpath subtrees whose executables are denied in
        guarded sessions (for example Chromium PWA shim directories).
      '';
    };

    denyLaunchServices = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Also deny `lsopen` in guarded sessions. LaunchServices (`open -a …`)
        spawns the target from launchd, outside the guarded process tree, where
        a `process-exec` deny cannot see it. Cost: an OAuth login flow started
        inside a guarded session can no longer open a browser window — run that
        login outside the guard.
      '';
    };

    guardedPrograms = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        claude-guarded = "/Users/markus/.npm-global/bin/claude";
      };
      description = ''
        Named guarded launchers installed into the user profile: attribute name
        becomes the command, the value is the absolute program it wraps under
        the Seatbelt guard. Do NOT list a CLI that applies its own Seatbelt
        profile per command (Codex) — macOS refuses nested profile application
        and the CLI would break; those get the environment layer only.
      '';
    };

    codexPermissions = {
      profileName = lib.mkOption {
        type = lib.types.str;
        default = "inspr-browser-guard";
        description = "Name of the Codex native permission profile this guard renders.";
      };

      fullProfileName = lib.mkOption {
        type = lib.types.str;
        default = "${cfg.codexPermissions.profileName}-full";
        description = ''
          Name of the guarded FULL-ACCESS Codex profile: no `extends`,
          `":root" = "write"`, network enabled, same browser denies. Explicit
          `--dangerously-bypass-approvals-and-sandbox` launches are routed here
          by `inspr-codex-full` instead of running the built-in unguarded bypass.
          Ordinary defaults stay workspace-scoped.
        '';
      };

      readOnlyProfileName = lib.mkOption {
        type = lib.types.str;
        default = "${cfg.codexPermissions.profileName}-readonly";
        description = ''
          Name of the guarded READ-ONLY Codex profile. Without it, a managed
          allow-list naming only the workspace profile would silently broaden an
          explicit read-only caller to workspace-write. This keeps read-only
          read-only, minus the browsers.
        '';
      };

      codexBinary = lib.mkOption {
        type = lib.types.str;
        default = "${config.home.homeDirectory}/.npm-global/bin/codex";
        description = ''
          Absolute operator-authenticated Codex CLI used by the managed
          installer's verification step. The installer runs it as the invoking
          operator (never as root) with an isolated temporary CODEX_HOME, so no
          account credential is involved.
        '';
      };

      extends = lib.mkOption {
        type = lib.types.str;
        default = ":workspace";
        description = ''
          Base Codex policy the guarded profile extends. Keeps the account's
          effective workspace and network policy; the profile only removes
          native browser execution on top of it. Never weaken this.
        '';
      };
    };

    shadowedPrograms = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        claude = "/Users/markus/.npm-global/bin/claude";
      };
      description = ''
        Guarded launchers installed under the vendor CLI's OWN name, in a
        dedicated directory placed ahead of ~/.npm-global/bin and
        /opt/homebrew/bin in fish. Existing callers and aliases keep working and
        become guarded; each wrapper execs the absolute vendor path, so CLI
        self-updates still apply.

        `codex` must not be listed: it applies its own Seatbelt profile per
        command and macOS refuses nested profiles. Codex is covered by its
        native permission profile instead (see codexPermissions).
      '';
    };

    envOnlyPrograms = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        cursor-agent = "/Users/markus/.local/share/cursor-agent/versions/<v>/cursor-agent";
      };
      description = ''
        Launchers installed under the vendor CLI's own name in the same
        PATH-ahead directory as `shadowedPrograms`, but WITHOUT a Seatbelt
        profile: they only add the harness hints and the Node preload.

        This is the Cursor case. `cursor-agent` (and its `agent` symlink) runs
        its own seatbelt helper, so an outer profile breaks it — measured: a real
        `--sandbox enabled` tool call under the guard died with `sandbox_apply`
        EPERM, exit 71. Its sandbox.json has no arbitrary filesystem deny and a
        `Read(<path>)` permission deny does not reach the native shell sandbox,
        so the Node preload is the honest remaining lever. It prevents accidental
        Playwright-shaped launches; it is not a boundary.
      '';
    };

    preloadProbePath = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/${guardLib.defaultPreloadProbeRelative}";
      description = ''
        Unprivileged self-test anchor carried in the deny lists so the Node
        preload and the Cursor proof can be exercised with a fake executable.
        Never written by anything privileged, and deliberately not the root
        installer's anchor.
      '';
    };

    guardCommand = lib.mkOption {
      type = lib.types.str;
      default = "";
      internal = true; # set by this module; consumers read, never define
      description = "Absolute path of the `inspr-agent-guard` launcher (consumers only).";
    };

    refusalCommand = lib.mkOption {
      type = lib.types.str;
      default = "";
      internal = true; # set by this module; consumers read, never define
      description = "Absolute path of the stable browser-refusal shim (consumers only).";
    };

    profilePath = lib.mkOption {
      type = lib.types.str;
      default = "";
      internal = true; # set by this module; consumers read, never define
      description = "Absolute path of the rendered Seatbelt profile (consumers and tests only).";
    };

    codexProfilePath = lib.mkOption {
      type = lib.types.str;
      default = "";
      internal = true;
      description = "Rendered Codex permission-profile snippet for the operator's CODEX_HOME configs.";
    };

    preloadPath = lib.mkOption {
      type = lib.types.str;
      default = "";
      internal = true;
      description = "Absolute path of the Node child-process preload (consumers and tests only).";
    };

    codexRequirementsPath = lib.mkOption {
      type = lib.types.str;
      default = "";
      internal = true;
      description = "Rendered managed /etc/codex/requirements.toml content (never installed from Nix).";
    };

    envOnlyExports = lib.mkOption {
      type = lib.types.lines;
      default = "";
      internal = true; # set by this module; consumers read, never define
      description = ''
        Shell `export` lines pointing the browser-harness variables at the
        refusal shim, without applying a Seatbelt profile. For entry points that
        apply their own sandbox and therefore cannot be wrapped.
      '';
    };

    launchdEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      internal = true; # set by this module; consumers read, never define
      description = "Same harness variables as an attrset, for launchd `EnvironmentVariables`.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "uzumaki.agentBrowserGuard is a macOS Seatbelt guard and requires Darwin";
      }
      {
        assertion = lib.all (target: lib.hasPrefix "/" target) (lib.attrValues cfg.guardedPrograms);
        message = "uzumaki.agentBrowserGuard.guardedPrograms targets must be absolute paths";
      }
      {
        assertion = lib.all (target: lib.hasPrefix "/" target) (lib.attrValues cfg.shadowedPrograms);
        message = "uzumaki.agentBrowserGuard.shadowedPrograms targets must be absolute paths";
      }
      {
        assertion = lib.all (target: lib.hasPrefix "/" target) (lib.attrValues cfg.envOnlyPrograms);
        message = "uzumaki.agentBrowserGuard.envOnlyPrograms targets must be absolute paths";
      }
      {
        assertion =
          lib.intersectLists (lib.attrNames cfg.shadowedPrograms) (lib.attrNames cfg.envOnlyPrograms) == [ ];
        message = "uzumaki.agentBrowserGuard: a command must be either sandbox-shadowed or env-only, not both";
      }
      {
        # Codex and Cursor both apply their own Seatbelt profile per command, and
        # macOS refuses nested profile application, so wrapping either would
        # break its existing inner sandbox. Cursor evidence: its `cursorsandbox`
        # helper carries sandbox-exec/seatbelt/process-exec strings (inspected
        # read-only, 2026-09-08). `agent` is the same Cursor binary by symlink.
        assertion =
          !(lib.any (name: cfg.shadowedPrograms ? ${name}) [
            "codex"
            "cursor-agent"
            "agent"
          ]);
        message = "uzumaki.agentBrowserGuard: codex, cursor-agent and agent apply their own Seatbelt profile and must not be wrapped — macOS refuses nested profiles";
      }
      {
        assertion = cfg.browserBundles != [ ];
        message = "uzumaki.agentBrowserGuard.browserBundles must not be empty — an empty guard denies nothing";
      }
    ];

    home.packages = [
      guard
      refusal
      managedInstaller
      codexFullLauncher
    ]
    ++ wrappers;

    # fish is the interactive shell here, and ai-clis-npm.nix prepends
    # ~/.npm-global/bin in its own shellInit; `mkAfter` puts the guard directory
    # in front of it. `--move` keeps a single entry if it is already present.
    programs.fish.shellInit = lib.mkIf (hasLaunchers) (
      lib.mkAfter "fish_add_path --prepend --move ${shadowBin}/bin"
    );

    # zsh: `envExtra` lands in .zshenv, which every zsh reads — including the
    # non-interactive `zsh -c` an agent Bash tool uses. `initExtra` would only
    # cover interactive shells. Other shells (bash, sh scripts, launchd jobs)
    # are NOT covered by PATH at all; they reach the guard only through an
    # absolute guarded path or an agentd-owned launch.
    programs.zsh.envExtra = lib.mkIf (hasLaunchers) (
      lib.mkAfter ''export PATH="${shadowBin}/bin:$PATH"''
    );

    # Operator-reviewable copies of the Codex policy. Home Manager owns these two
    # files; nothing here writes to a CODEX_HOME, to /etc, or to any vendor
    # package. The privileged install step is deliberately left to the operator.
    home.file.".config/inspr/agent-browser-guard/codex-permissions.toml".source = codexProfile;
    home.file.".config/inspr/agent-browser-guard/codex-requirements.toml".source = codexRequirements;

    uzumaki.agentBrowserGuard = {
      guardCommand = guardPath;
      refusalCommand = refusalPath;
      profilePath = "${profile}";
      preloadPath = preloadPath;
      codexProfilePath = "${codexProfile}";
      codexRequirementsPath = "${codexRequirements}";
      envOnlyExports = envOnlyPrefix;
      launchdEnvironment = guardLib.mkHarnessEnv {
        inherit refusalPath;
        mode = "env-only";
      };
    };
  };
}
