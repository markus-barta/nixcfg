# NIX-445 — declarative macOS agent browser-launch guard (Home Manager)
#
# Prevents native browser launches in Codex and explicitly guarded sessions
# before the process starts, without modifying any browser app bundle, any vendor
# CLI, or macOS security settings. Rationale, the measured Seatbelt behaviour
# and the proven nesting limit live in lib/agent-browser-guard.nix.
#
# NIX-578: native HEADLESS Playwright/Puppeteer is supported outside Codex.
# Default non-Codex launchers preserve the NIX-288 browser environment and add
# no preload. Codex gets its own shell and agentd env+preload launchers:
# Chrome aborts in _RegisterApplication inside its Seatbelt sandbox (2026-09-08).
# Strict `*-guarded` launchers and the Seatbelt profile remain opt-in tools.
# They must never wrap a dispatch controller: nested Seatbelt profiles fail.
# The Node preload is cooperative accidental-launch prevention, not an OS
# boundary. A blocked launch is not a passed test; see AGENTS-NIXCFG.md.
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
#   b. KNOWN ABSOLUTE CALLERS TO MIGRATE (named, not hand-waved):
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
#   c. Non-Codex absolute callers may use native headless Chrome. They do not
#      need migration to a guard. Existing guarded sessions retain their old
#      environment; start a fresh session after activation.
#   d. Codex app-server picks up policy at start: restart it after (a).
#
# WHAT THIS MODULE DOES NOT DO
#   - It does not touch `home.sessionVariables`. Ordinary human shells keep the
#     NIX-288 export (modules/uzumaki/macos-common.nix → playwrightSessionVars)
#     and normal browser use from Finder/Dock/Spotlight is unaffected.
#   - Codex is shadowed with env+preload ONLY, never an outer Seatbelt profile.
#     Same-name launchers live in a dedicated directory placed ahead of
#     every other PATH entry — by fish `shellInit` and zsh `envExtra` (.zshenv,
#     which non-interactive `zsh -c` also reads), and again as the LAST step of
#     fish login/interactive init and zsh .zlogin/.zshrc, because host login
#     init re-prepends Homebrew and the Nix profiles (NIX-515). bash, sh
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

  # Node preload: defence in depth for Codex and strict opt-in sessions.
  # Cooperative, process-local, NOT a boundary — see agent-browser-guard.cjs.
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
    ${envOnlyPrefix}
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
  # Native launchers preserve the caller's browser variables and NODE_OPTIONS.
  mkNativeWrapper =
    name: target: pkgs.writeShellScriptBin name (guardLib.mkNativeLauncherText target);
  # Codex needs its own hints/preload now that dispatch controllers are native.
  # No outer Seatbelt: that would break Codex's existing command sandbox.
  mkEnvOnlyWrapper =
    name: target:
    pkgs.writeShellScriptBin name ''
      ${envOnlyPrefix}
      exec ${lib.escapeShellArg target} "$@"
    '';
  wrappers = lib.mapAttrsToList mkWrapper cfg.guardedPrograms;
  hasLaunchers =
    cfg.shadowedPrograms != { } || cfg.nativePrograms != { } || cfg.envOnlyPrograms != { };

  # PATH-shadowing launchers: same command NAME as the vendor CLI, in a directory
  # of their own that fish puts ahead of ~/.npm-global/bin and /opt/homebrew/bin.
  # Existing callers keep the pinned vendor paths. Only explicitly configured
  # shadowedPrograms use Seatbelt; nativePrograms preserve the environment.
  shadowBin = pkgs.symlinkJoin {
    name = "inspr-agent-guard-shadow-bin";
    paths =
      lib.mapAttrsToList mkWrapper cfg.shadowedPrograms
      ++ lib.mapAttrsToList mkNativeWrapper cfg.nativePrograms
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
      description = ''
        Same-name Codex launchers with refusal hints and Node preload only.
        No outer Seatbelt is applied. This covers shell dispatch independently
        of the optional privileged managed Codex policy installation.
        Absolute callers that bypass these launchers still need managed policy.
      '';
    };

    nativePrograms = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = lib.literalExpression ''
        {
          cursor-agent = lib.getExe pkgs.cursor-agent;
        }
      '';
      description = ''
        Same-name vendor launchers in the PATH-ahead directory, without browser
        refusal hints, Node preload or Seatbelt wrapping (NIX-578). Preserve
        the caller's NIX-288 native Chrome path or project devenv environment.
        Codex must use its native permission profile and guarded env instead.
      '';
    };

    preloadProbePath = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/${guardLib.defaultPreloadProbeRelative}";
      description = ''
        Unprivileged self-test anchor carried in the deny lists so the Node
        preload proof can be exercised with a fake executable.
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
        assertion = lib.all (target: lib.hasPrefix "/" target) (lib.attrValues cfg.nativePrograms);
        message = "uzumaki.agentBrowserGuard.nativePrograms targets must be absolute paths";
      }
      {
        assertion = lib.all (target: lib.hasPrefix "/" target) (lib.attrValues cfg.envOnlyPrograms);
        message = "uzumaki.agentBrowserGuard.envOnlyPrograms targets must be absolute paths";
      }
      {
        assertion =
          let
            names =
              lib.attrNames cfg.shadowedPrograms
              ++ lib.attrNames cfg.nativePrograms
              ++ lib.attrNames cfg.envOnlyPrograms;
          in
          builtins.length (lib.unique names) == builtins.length names;
        message = "uzumaki.agentBrowserGuard: launcher names must be unique across strict, native and env-only programs";
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
      (
        # NIX-514: a profile package whose main program carries a launcher's
        # name competes with that launcher on PATH. Measured 2026-09-19, before
        # NIX-515: in a fish LOGIN shell ~/.nix-profile/bin landed ahead of the
        # shadow directory, and pkgs.cursor-agent in home.packages won
        # `cursor-agent` and `agent` unguarded. NIX-515 now re-prepends the
        # guard last, so this is defense in depth: shells or tools that build
        # PATH without our init would still find the unguarded binary. Point the
        # launcher at the package instead of installing it.
        let
          launcherNames =
            lib.attrNames cfg.shadowedPrograms
            ++ lib.attrNames cfg.nativePrograms
            ++ lib.attrNames cfg.envOnlyPrograms;
          collisions = lib.unique (
            lib.filter (name: lib.elem name launcherNames) (
              map (p: (p.meta or { }).mainProgram or null) config.home.packages
            )
          );
        in
        {
          assertion = collisions == [ ];
          message = "uzumaki.agentBrowserGuard: home.packages also installs ${lib.concatStringsSep ", " collisions}, which fish login shells resolve ahead of the guard launcher — keep it out of the profile and point the launcher at the package";
        }
      )
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
    #
    # NIX-515: that is not the last word. Host `loginShellInit` then moves
    # ~/.nix-profile/bin, the default profile and /opt/homebrew/bin to the front,
    # so in a login shell (every terminal) any same-name binary there won PATH
    # unguarded — measured 2026-09-19 with a stray Homebrew grok. Re-prepend as
    # the last step of the login and interactive phases (mkOrder 2000 sorts
    # after mkAfter). fish_add_path persists into the universal
    # fish_user_paths, so also drop shadow-bin entries of older generations:
    # they pile up with every switch and dangle once garbage-collected.
    programs.fish.shellInit = lib.mkIf (hasLaunchers) (
      lib.mkAfter ''
        for p in $fish_user_paths
          if string match -q -- '/nix/store/*-inspr-agent-guard-shadow-bin/bin' $p
            and test "$p" != "${shadowBin}/bin"
            # `if set var (cmd)` carries cmd's status (documented fish idiom)
            if set -l i (contains -i -- $p $fish_user_paths)
              set -e fish_user_paths[$i]
            end
          end
        end
        fish_add_path --prepend --move ${shadowBin}/bin
      ''
    );
    programs.fish.loginShellInit = lib.mkIf (hasLaunchers) (
      lib.mkOrder 2000 "fish_add_path --prepend --move ${shadowBin}/bin"
    );
    programs.fish.interactiveShellInit = lib.mkIf (hasLaunchers) (
      lib.mkOrder 2000 "fish_add_path --prepend --move ${shadowBin}/bin"
    );

    # zsh: `envExtra` lands in .zshenv, which every zsh reads — including the
    # non-interactive `zsh -c` an agent Bash tool uses. `initExtra` would only
    # cover interactive shells. Other shells (bash, sh scripts, launchd jobs)
    # are NOT covered by PATH at all; they reach the guard only through an
    # absolute guarded path or an agentd-owned launch.
    programs.zsh.envExtra = lib.mkIf (hasLaunchers) (
      lib.mkAfter ''export PATH="${shadowBin}/bin:$PATH"''
    );
    # NIX-515: a login zsh then runs /etc/zprofile (path_helper) and Home
    # Manager's session setup, which put ~/.npm-global/bin back in front —
    # measured 2026-09-19: `zsh -l` resolved claude, grok and pi unguarded.
    # Re-prepend last in .zlogin (every login shell, after .zshrc) and .zshrc
    # (interactive non-login), without duplicating the entry.
    programs.zsh.loginExtra = lib.mkIf (hasLaunchers) (
      lib.mkOrder 2000 "path=(${shadowBin}/bin \${path:#${shadowBin}/bin})"
    );
    programs.zsh.initContent = lib.mkIf (hasLaunchers) (
      lib.mkOrder 2000 "path=(${shadowBin}/bin \${path:#${shadowBin}/bin})"
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
