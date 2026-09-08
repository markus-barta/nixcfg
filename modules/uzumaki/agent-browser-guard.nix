# NIX-445 — declarative macOS agent browser-launch guard (Home Manager)
#
# Prevents agent worker sessions from executing a native browser, before the
# browser process starts, without modifying any browser app bundle, any vendor
# CLI, or macOS security settings. Rationale, the measured Seatbelt behaviour
# and the proven nesting limit live in lib/agent-browser-guard.nix.
#
# FOUR LAYERS, DELIBERATELY DIFFERENT IN STRENGTH
#   1. Seatbelt boundary — `inspr-agent-guard <program>` runs the program under a
#      profile that denies `process-exec*` on every browser bundle. Inherited by
#      all descendants, including Node/Playwright grandchildren. Usable only for
#      CLIs that do NOT apply their own Seatbelt profile.
#   2. Codex native policy — Codex applies its own Seatbelt profile per command,
#      and macOS refuses nested profiles, so Codex is covered by an equivalent
#      deny inside ITS OWN permission profile (`extends = ":workspace"` plus a
#      filesystem deny). Measured working with fake executables on Codex 0.153.4;
#      see lib/agent-browser-guard.nix. Rendering is declarative here; SELECTING
#      the profile machine-wide is a privileged operator step (below).
#   3. Harness hints — guarded launchers point PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH,
#      PUPPETEER_EXECUTABLE_PATH and CHROME_PATH at a refusal shim instead of the
#      NIX-288 native Chrome path. These are HINTS, not a boundary: a harness that
#      hardcodes a path never reads them. Their value is turning an opaque EPERM
#      into a stable, explained refusal.
#   4. Guidance — AGENTS-NIXCFG.md tells agents what the refusal means, that a
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
#   b. Operator-owned imperative shims that call an absolute vendor path — the
#      named Codex launchers in ~/.local/share/inspr/codex/bin, the agent.one
#      docs path, ~/.local/bin/agent. Those bypass the PATH-shadowing launchers
#      by construction; they are migration items, not covered ground.
#   c. Codex app-server picks up policy at start: restart it after (a).
#
# WHAT THIS MODULE DOES NOT DO
#   - It does not touch `home.sessionVariables`. Ordinary human shells keep the
#     NIX-288 export (modules/uzumaki/macos-common.nix → playwrightSessionVars)
#     and normal browser use from Finder/Dock/Spotlight is unaffected.
#   - It never shadows `codex`: wrapping it would break its own sandbox. Other
#     CLIs ARE shadowed under their real names (`shadowedPrograms`) in a
#     dedicated directory that fish puts ahead of ~/.npm-global/bin and
#     /opt/homebrew/bin, so today's callers and aliases become guarded without
#     being renamed. Callers that hardcode an absolute vendor path still bypass
#     it — see the migration items above.
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

  guard = pkgs.writeShellScriptBin "inspr-agent-guard" (
    guardLib.mkGuardText {
      profilePath = "${profile}";
      inherit refusalPath;
    }
  );
  guardPath = "${guard}/bin/inspr-agent-guard";

  # Codex cannot be wrapped (macOS refuses nested Seatbelt profiles); it carries
  # the same deny in its OWN permission policy instead. Rendered here, installed
  # by the operator — see the activation checklist in the option descriptions.
  codexDenyPaths = cfg.browserBundles ++ cfg.extraDenyPaths;
  codexProfile = pkgs.writeText "codex-permissions.toml" (
    guardLib.mkCodexPermissionsToml {
      inherit (cfg.codexPermissions) profileName extends;
      denyPaths = codexDenyPaths;
    }
  );
  codexRequirements = pkgs.writeText "codex-requirements.toml" (
    guardLib.mkCodexRequirementsToml {
      inherit (cfg.codexPermissions) profileName extends;
      denyPaths = codexDenyPaths;
    }
  );

  # Named guarded launcher: `exec` keeps argv, signals and the caller's
  # environment intact, so a self-updating npm CLI behind an absolute path
  # stays exactly the CLI the operator authenticated.
  mkWrapper =
    name: target:
    pkgs.writeShellScriptBin name ''
      exec ${lib.escapeShellArg guardPath} ${lib.escapeShellArg target} "$@"
    '';
  wrappers = lib.mapAttrsToList mkWrapper cfg.guardedPrograms;

  # PATH-shadowing launchers: same command NAME as the vendor CLI, in a directory
  # of their own that fish puts ahead of ~/.npm-global/bin and /opt/homebrew/bin.
  # This is what makes existing callers — `claude`, the `cla`/`clar` aliases,
  # `grok` from either resolution — go through the guard without renaming
  # anything. Absolute-path callers still bypass it by construction; those are
  # listed in the migration checklist rather than claimed as covered.
  shadowBin = pkgs.symlinkJoin {
    name = "inspr-agent-guard-shadow-bin";
    paths = lib.mapAttrsToList mkWrapper cfg.shadowedPrograms;
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
        assertion = !(cfg.shadowedPrograms ? codex);
        message = "uzumaki.agentBrowserGuard: Codex must not be sandbox-wrapped — macOS refuses nested Seatbelt profiles; use codexPermissions instead";
      }
      {
        assertion = cfg.browserBundles != [ ];
        message = "uzumaki.agentBrowserGuard.browserBundles must not be empty — an empty guard denies nothing";
      }
    ];

    home.packages = [
      guard
      refusal
    ]
    ++ wrappers;

    # fish is the interactive shell here, and ai-clis-npm.nix prepends
    # ~/.npm-global/bin in its own shellInit; `mkAfter` puts the guard directory
    # in front of it. `--move` keeps a single entry if it is already present.
    programs.fish.shellInit = lib.mkIf (cfg.shadowedPrograms != { }) (
      lib.mkAfter "fish_add_path --prepend --move ${shadowBin}/bin"
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
      codexProfilePath = "${codexProfile}";
      codexRequirementsPath = "${codexRequirements}";
      envOnlyExports = guardLib.mkEnvOnlyExports refusalPath;
      launchdEnvironment = guardLib.mkHarnessEnv {
        inherit refusalPath;
        mode = "env-only";
      };
    };
  };
}
