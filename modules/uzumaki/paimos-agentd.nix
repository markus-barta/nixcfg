{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.uzumaki.paimosAgentd;
  home = config.home.homeDirectory;
  stateRoot = "${home}/Library/Caches/paimos/agentd";
  instanceKey = builtins.substring 0 32 (builtins.hashString "sha256" cfg.instance);
  instanceStateDir = "${stateRoot}/${instanceKey}";
  stdoutLog = "${instanceStateDir}/agentd.stdout.log";
  stderrLog = "${instanceStateDir}/agentd.stderr.log";
  reportCredentialFile = "${stateRoot}/report-api-key";
  lifecycleConfigFile = if cfg.lifecycleConfigFile == null then "" else cfg.lifecycleConfigFile;
  codexAccountsFile = if cfg.codexAccountsFile == null then "" else cfg.codexAccountsFile;
  piAccountsFile = if cfg.piAccountsFile == null then "" else cfg.piAccountsFile;
  cursorAccountsFile = if cfg.cursorAccountsFile == null then "" else cfg.cursorAccountsFile;
  sdkPath = "${pkgs.claude-agent-sdk}/${pkgs.claude-agent-sdk.sdkRelativePath}";

  # NIX-445 — agent browser-launch guard. `browserGuard` is the shared module
  # (modules/uzumaki/agent-browser-guard.nix); this file only decides which
  # owned launch paths get which layer.
  browserGuard = config.uzumaki.agentBrowserGuard;
  guardEnabled = cfg.browserGuard.enable;
  # Env-only layer: harness variables point at the refusal shim. Used for Codex,
  # which applies its OWN Seatbelt profile per command — macOS refuses nested
  # profile application (`sandbox_apply: Operation not permitted`), so wrapping
  # Codex in the guard sandbox would break its existing inner sandbox. Measured
  # on Darwin 25.6; see lib/agent-browser-guard.nix.
  guardEnvExports = lib.optionalString guardEnabled browserGuard.envOnlyExports;
  # Boundary layer: run the operator's absolute CLI path under the Seatbelt
  # guard. argv, signals and the inherited environment pass through unchanged.
  mkGuardedCli =
    name: target:
    pkgs.writeShellScriptBin "paimos-agentd-${name}" ''
      exec ${lib.escapeShellArg browserGuard.guardCommand} ${lib.escapeShellArg target} "$@"
    '';
  guardedCliPath =
    name: target:
    if guardEnabled && lib.elem name cfg.browserGuard.sandboxedClis then
      "${mkGuardedCli name target}/bin/paimos-agentd-${name}"
    else
      target;
  safeExternalPath =
    path: lib.hasPrefix "/" path && path != "/nix/store" && !lib.hasPrefix "/nix/store/" path;
  pairComplete = path: accounts: (path == null) == (accounts == null);
  accountRegistryActivationScript = label: path: ''
    accounts_file=${lib.escapeShellArg path}
    if [ ! -f "$accounts_file" ] || [ -L "$accounts_file" ]; then
      printf '%s\n' 'paimos-agentd ${label} must be an existing regular non-symlink file' >&2
      exit 1
    fi
    accounts_mode=$(${pkgs.coreutils}/bin/stat -c '%a' "$accounts_file")
    accounts_owner=$(${pkgs.coreutils}/bin/stat -c '%u' "$accounts_file")
    accounts_links=$(${pkgs.coreutils}/bin/stat -c '%h' "$accounts_file")
    accounts_size=$(${pkgs.coreutils}/bin/stat -c '%s' "$accounts_file")
    if [ "$accounts_mode" != 600 ] || [ "$accounts_owner" != "$(${pkgs.coreutils}/bin/id -u)" ] || [ "$accounts_links" != 1 ]; then
      printf '%s\n' 'paimos-agentd ${label} ownership, mode or link count is unsafe' >&2
      exit 1
    fi
    if [ "$accounts_size" -gt 65536 ] || ! ${pkgs.jq}/bin/jq -e -s 'length == 1 and (.[0] | type == "object")' "$accounts_file" >/dev/null 2>&1; then
      printf '%s\n' 'paimos-agentd ${label} must contain one bounded JSON object' >&2
      exit 1
    fi
  '';
  # PATH-only wrapper: the owned runtime may pass CODEX_HOME for a selected
  # account. Do not unset, override, or source registry text here. NIX-445 adds
  # the browser-harness exports only — no CLI or home variable is reassigned.
  # Pi and Cursor CLIs stay explicit operator pins: this module never copies
  # their auth directories or starts a login, and it wraps them only when
  # `browserGuard.sandboxedClis` names them.
  codexLauncher = pkgs.writeShellScriptBin "paimos-agentd-codex" ''
    export PATH=${lib.escapeShellArg "${pkgs.nodejs}/bin:/usr/bin:/bin:/usr/sbin:/sbin"}
    ${guardEnvExports}
    exec ${lib.escapeShellArg cfg.codexPath} "$@"
  '';
  reportCredentialInstaller = pkgs.writeShellScript "paimos-agentd-install-report-credential" ''
    set -eu

    if [ "$#" -ne 3 ]; then
      printf '%s\n' 'paimos-agentd report credential installer requires source, destination, and variable' >&2
      exit 1
    fi
    source_file=$1
    destination=$2
    variable=$3

    case "$source_file:$destination" in
      /*:/*) ;;
      *) printf '%s\n' 'paimos-agentd report credential paths must be absolute' >&2; exit 1 ;;
    esac
    case "$variable" in
      ""|[0-9]*|*[!A-Za-z0-9_]*) printf '%s\n' 'paimos-agentd report credential variable is invalid' >&2; exit 1 ;;
    esac
    if [ ! -f "$source_file" ] || [ -L "$source_file" ] || [ ! -r "$source_file" ]; then
      printf '%s\n' 'paimos-agentd report credential source is not a readable regular file' >&2
      exit 1
    fi
    source_mode=$(${pkgs.coreutils}/bin/stat -c '%a' "$source_file")
    source_owner=$(${pkgs.coreutils}/bin/stat -c '%U' "$source_file")
    current_user=$(${pkgs.coreutils}/bin/id -un)
    case "$source_mode" in
      400|600) ;;
      *) printf '%s\n' 'paimos-agentd report credential source must be owner-only' >&2; exit 1 ;;
    esac
    if [ "$source_owner" != "$current_user" ]; then
      printf '%s\n' 'paimos-agentd report credential source has the wrong owner' >&2
      exit 1
    fi
    newline_count=$(${pkgs.coreutils}/bin/wc -l < "$source_file" | ${pkgs.coreutils}/bin/tr -d ' ')
    if [ "$newline_count" != 0 ]; then
      printf '%s\n' 'paimos-agentd report credential source must be one assignment without a newline' >&2
      exit 1
    fi
    raw=$(${pkgs.coreutils}/bin/cat "$source_file")
    prefix="$variable="
    case "$raw" in
      "$prefix"*) ;;
      *) printf '%s\n' 'paimos-agentd report credential source has the wrong assignment' >&2; exit 1 ;;
    esac
    secret="''${raw#"$prefix"}"
    if [ -z "$secret" ] || [ "''${#secret}" -gt 4096 ] || ! printf '%s' "$secret" | LC_ALL=C ${pkgs.gnugrep}/bin/grep -q '^[[:graph:]]*$'; then
      printf '%s\n' 'paimos-agentd report credential value is invalid' >&2
      exit 1
    fi
    destination_dir=$(${pkgs.coreutils}/bin/dirname "$destination")
    if [ "$(${pkgs.coreutils}/bin/stat -c '%a' "$destination_dir")" != 700 ]; then
      printf '%s\n' 'paimos-agentd report credential destination directory must be owner-only' >&2
      exit 1
    fi
    next="$destination.next"
    ${pkgs.coreutils}/bin/install -m 0600 /dev/null "$next"
    printf '%s' "$secret" > "$next"
    ${pkgs.coreutils}/bin/chmod 0600 "$next"
    ${pkgs.coreutils}/bin/mv -f "$next" "$destination"
    unset raw secret
  '';
  serviceLabel = "at.inspr.paimos-agentd";
  serviceArguments = [
    "${pkgs.paimos-cli}/bin/paimos-agentd"
    "serve"
    "--instance"
    cfg.instance
    "--state-root"
    stateRoot
    "--codex-path"
    "${codexLauncher}/bin/paimos-agentd-codex"
    "--claude-path"
    (guardedCliPath "claude" cfg.claudePath)
    "--node-path"
    "${pkgs.nodejs}/bin/node"
    "--claude-sdk-path"
    sdkPath
  ]
  ++ lib.optionals cfg.reporting.enable [
    "--report-host"
    cfg.reporting.host
    "--report-url"
    cfg.reporting.url
    "--report-api-key-file"
    reportCredentialFile
    "--paimos-path"
    "${pkgs.paimos-cli}/bin/paimos"
  ]
  ++ lib.optionals (cfg.lifecycleConfigFile != null) [
    "--lifecycle-config"
    lifecycleConfigFile
  ]
  ++ lib.optionals (cfg.codexAccountsFile != null) [
    "--codex-accounts"
    codexAccountsFile
  ]
  ++ lib.optionals (cfg.piPath != null && cfg.piAccountsFile != null) [
    "--pi-path"
    (guardedCliPath "pi" cfg.piPath)
    "--pi-accounts"
    piAccountsFile
  ]
  ++ lib.optionals (cfg.cursorPath != null && cfg.cursorAccountsFile != null) [
    "--cursor-path"
    # Unwrapped on purpose: the Cursor CLI applies its own Seatbelt profile via
    # its `cursorsandbox` helper, and macOS refuses nested profiles. It receives
    # the plist environment hints only — a hint, not a boundary (NIX-445).
    cfg.cursorPath
    "--cursor-accounts"
    cursorAccountsFile
  ];
  serviceConfig = {
    Label = serviceLabel;
    ProgramArguments = serviceArguments;
    KeepAlive = true;
    RunAtLoad = true;
    ProcessType = "Background";
    ThrottleInterval = 10;
    Umask = 63;
    StandardOutPath = stdoutLog;
    StandardErrorPath = stderrLog;
  }
  # NIX-445: every session this daemon starts inherits the refusal shim in place
  # of the NIX-288 native Chrome path, whichever CLI it launches. Harness layer,
  # not a boundary — a session that hardcodes the browser path still reaches it
  # unless its CLI is also sandbox-wrapped above.
  // lib.optionalAttrs guardEnabled { EnvironmentVariables = browserGuard.launchdEnvironment; };
  directServicePlist = pkgs.writeText "${serviceLabel}.plist" (
    lib.generators.toPlist { escape = true; } serviceConfig
  );
in
{
  options.uzumaki.paimosAgentd = {
    enable = lib.mkEnableOption "the operator-local PAIMOS owned-session daemon";

    instance = lib.mkOption {
      type = lib.types.str;
      default = "ppm";
      description = "Existing PAIMOS CLI instance name; credentials remain in the OS keyring.";
    };

    codexPath = lib.mkOption {
      type = lib.types.str;
      default = "${home}/.npm-global/bin/codex";
      description = "Absolute operator-authenticated Codex CLI path.";
    };

    claudePath = lib.mkOption {
      type = lib.types.str;
      default = "${home}/.npm-global/bin/claude";
      description = "Absolute operator-authenticated Claude CLI path.";
    };

    lifecycleConfigFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Absolute owner-only lifecycle configuration file materialized outside the Nix store.";
    };

    codexAccountsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Absolute owner-only Codex account registry JSON file materialized outside
        the Nix store. Null keeps the existing serve argv. A set path adds exactly
        one `--codex-accounts` pair. Requires a Paimos release whose paimos-agentd
        serve accepts `--codex-accounts`; do not enable against older pins.
        Operator-owned homes, emails, and registry bytes stay outside Nix.
        Paimos validates registry semantics and account proof.
      '';
    };

    piPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Absolute operator-authenticated Pi CLI path. Null keeps the existing serve
        argv. A set path must be paired with piAccountsFile and emits exactly one
        `--pi-path`/`--pi-accounts` pair. Requires a Paimos release whose
        paimos-agentd serve accepts `--pi-path` and `--pi-accounts`; do not enable
        against older pins.
      '';
    };

    piAccountsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Absolute owner-only Pi account registry JSON file materialized outside the
        Nix store. Null keeps the existing serve argv. A set path must be paired
        with piPath. Operator-owned homes, emails, and registry bytes stay outside
        Nix. Paimos validates registry semantics and account proof.
      '';
    };

    cursorPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Absolute operator-authenticated Cursor CLI path. Null keeps the existing
        serve argv. A set path must be paired with cursorAccountsFile and emits
        exactly one `--cursor-path`/`--cursor-accounts` pair. Requires a Paimos
        release whose paimos-agentd serve accepts `--cursor-path` and
        `--cursor-accounts`; do not enable against older pins.
      '';
    };

    cursorAccountsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Absolute owner-only Cursor account registry JSON file materialized outside
        the Nix store. Null keeps the existing serve argv. A set path must be
        paired with cursorPath. Operator-owned homes, emails, and registry bytes
        stay outside Nix. Paimos validates registry semantics and account proof.
      '';
    };

    browserGuard = {
      enable = lib.mkEnableOption ''
        the NIX-445 browser-launch guard on this daemon's owned launch paths.
        Requires uzumaki.agentBrowserGuard.enable
      '';

      sandboxedClis = lib.mkOption {
        type = lib.types.listOf (
          lib.types.enum [
            "claude"
            "pi"
          ]
        );
        default = [ "claude" ];
        description = ''
          Which owned CLI paths are executed under the Seatbelt guard, as
          opposed to receiving the environment layer only.

          Codex and Cursor are deliberately absent from this enum and cannot be
          added:
          it applies its own Seatbelt profile per command, and macOS refuses
          nested profile application (`sandbox_apply: Operation not
          permitted`, measured on Darwin 25.6), so wrapping it would break
          its existing inner sandbox. The Cursor CLI ships its own
          `cursorsandbox` seatbelt helper (inspected read-only 2026-09-08)
          and has the same problem. Codex is covered by its native
          permission profile; Cursor currently gets the environment hints
          only, which is a hint and not a boundary — stated, not hidden.

          A CLI listed here that also applies its own sandbox will fail
          loudly with the same `sandbox_apply` error; remove it from this
          list rather than weakening the guard.
        '';
      };
    };

    reporting = {
      enable = lib.mkEnableOption "authenticated durable harness status and owned controls";

      host = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Stable non-secret host attribution sent to the configured PAIMOS instance.";
      };

      url = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Exact HTTPS PAIMOS deployment URL used only by the authenticated reporter.";
      };

      apiKeyEnvFile = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Absolute owner-only NAME=value file materialized outside the Nix store.";
      };

      apiKeyVariable = lib.mkOption {
        type = lib.types.str;
        default = "PPMAPIKEY";
        description = "Exact variable name expected in apiKeyEnvFile.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "uzumaki.paimosAgentd currently requires macOS launchd";
      }
      {
        assertion =
          lib.hasPrefix "/" cfg.codexPath
          && lib.hasPrefix "/" cfg.claudePath
          && (cfg.piPath == null || lib.hasPrefix "/" cfg.piPath)
          && (cfg.cursorPath == null || lib.hasPrefix "/" cfg.cursorPath);
        message = "uzumaki.paimosAgentd vendor CLI paths must be absolute";
      }
      {
        assertion =
          !cfg.reporting.enable
          || (
            builtins.match "[A-Za-z0-9][A-Za-z0-9._:-]*" cfg.reporting.host != null
            && lib.hasPrefix "https://" cfg.reporting.url
            && lib.hasPrefix "/" cfg.reporting.apiKeyEnvFile
            && builtins.match "[A-Za-z_][A-Za-z0-9_]*" cfg.reporting.apiKeyVariable != null
          );
        message = "uzumaki.paimosAgentd reporting requires a safe host, exact HTTPS URL, absolute credential source, and shell variable name";
      }
      {
        assertion =
          cfg.lifecycleConfigFile == null
          || (
            cfg.reporting.enable
            && lib.hasPrefix "/" lifecycleConfigFile
            && lifecycleConfigFile != "/nix/store"
            && !lib.hasPrefix "/nix/store/" lifecycleConfigFile
          );
        message = "uzumaki.paimosAgentd lifecycleConfigFile requires reporting and an absolute path outside the Nix store";
      }
      {
        assertion =
          cfg.codexAccountsFile == null
          || (
            lib.hasPrefix "/" codexAccountsFile
            && codexAccountsFile != "/nix/store"
            && !lib.hasPrefix "/nix/store/" codexAccountsFile
          );
        message = "uzumaki.paimosAgentd codexAccountsFile requires an absolute path outside the Nix store";
      }
      {
        assertion = !cfg.browserGuard.enable || browserGuard.enable;
        message = "uzumaki.paimosAgentd.browserGuard requires uzumaki.agentBrowserGuard.enable";
      }
      {
        assertion =
          !cfg.browserGuard.enable || !(lib.elem "pi" cfg.browserGuard.sandboxedClis) || cfg.piPath != null;
        message = "uzumaki.paimosAgentd.browserGuard cannot sandbox Pi without piPath";
      }
      {
        assertion = pairComplete cfg.piPath cfg.piAccountsFile;
        message = "uzumaki.paimosAgentd Pi requires piPath and piAccountsFile together";
      }
      {
        assertion = cfg.piAccountsFile == null || safeExternalPath piAccountsFile;
        message = "uzumaki.paimosAgentd piAccountsFile requires an absolute path outside the Nix store";
      }
      {
        assertion = pairComplete cfg.cursorPath cfg.cursorAccountsFile;
        message = "uzumaki.paimosAgentd Cursor requires cursorPath and cursorAccountsFile together";
      }
      {
        assertion = cfg.cursorAccountsFile == null || safeExternalPath cursorAccountsFile;
        message = "uzumaki.paimosAgentd cursorAccountsFile requires an absolute path outside the Nix store";
      }
    ];

    home.packages = [
      pkgs.paimos-cli
      pkgs.claude-agent-sdk
      pkgs.nodejs
    ];

    # Home Manager currently wraps every LaunchAgent in /bin/sh + wait4path.
    # Agentd's ownership verifier deliberately requires direct exec, so replace
    # only this generated plist while retaining HM's native service lifecycle.
    home.extraBuilderCommands = lib.mkAfter ''
      current_agents=$(${pkgs.coreutils}/bin/readlink -f "$out/LaunchAgents")
      direct_agents="$out/LaunchAgents-direct"
      ${pkgs.coreutils}/bin/mkdir -p "$direct_agents"
      for agent in "$current_agents"/*.plist; do
        [ -e "$agent" ] || continue
        name=$(${pkgs.coreutils}/bin/basename "$agent")
        ${pkgs.coreutils}/bin/ln -s "$(${pkgs.coreutils}/bin/readlink -f "$agent")" "$direct_agents/$name"
      done
      ${pkgs.coreutils}/bin/ln -sfn ${lib.escapeShellArg directServicePlist} "$direct_agents/${serviceLabel}.plist"
      ${pkgs.coreutils}/bin/unlink "$out/LaunchAgents"
      ${pkgs.coreutils}/bin/ln -s LaunchAgents-direct "$out/LaunchAgents"
    '';

    home.activation.paimosAgentdLifecycleConfig = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
      ${lib.optionalString (cfg.lifecycleConfigFile != null) ''
        lifecycle_file=${lib.escapeShellArg lifecycleConfigFile}
        if [ ! -f "$lifecycle_file" ] || [ -L "$lifecycle_file" ]; then
          printf '%s\n' 'paimos-agentd lifecycle configuration must be an existing regular non-symlink file' >&2
          exit 1
        fi
        lifecycle_mode=$(${pkgs.coreutils}/bin/stat -c '%a' "$lifecycle_file")
        lifecycle_owner=$(${pkgs.coreutils}/bin/stat -c '%u' "$lifecycle_file")
        lifecycle_links=$(${pkgs.coreutils}/bin/stat -c '%h' "$lifecycle_file")
        lifecycle_size=$(${pkgs.coreutils}/bin/stat -c '%s' "$lifecycle_file")
        if [ "$lifecycle_mode" != 600 ] || [ "$lifecycle_owner" != "$(${pkgs.coreutils}/bin/id -u)" ] || [ "$lifecycle_links" != 1 ]; then
          printf '%s\n' 'paimos-agentd lifecycle configuration ownership, mode or link count is unsafe' >&2
          exit 1
        fi
        if [ "$lifecycle_size" -gt 65536 ] || ! ${pkgs.jq}/bin/jq -e -s 'length == 1 and (.[0] | type == "object")' "$lifecycle_file" >/dev/null 2>&1; then
          printf '%s\n' 'paimos-agentd lifecycle configuration must contain one bounded JSON object' >&2
          exit 1
        fi
      ''}
    '';

    home.activation.paimosAgentdCodexAccounts = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
      ${lib.optionalString (cfg.codexAccountsFile != null) (
        accountRegistryActivationScript "Codex account registry" codexAccountsFile
      )}
    '';

    home.activation.paimosAgentdPiAccounts = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
      ${lib.optionalString (cfg.piAccountsFile != null) (
        accountRegistryActivationScript "Pi account registry" piAccountsFile
      )}
    '';

    home.activation.paimosAgentdCursorAccounts = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
      ${lib.optionalString (cfg.cursorAccountsFile != null) (
        accountRegistryActivationScript "Cursor account registry" cursorAccountsFile
      )}
    '';

    home.activation.paimosAgentdPrivateState =
      lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ]
        ''
          ${pkgs.coreutils}/bin/install -d -m 0700 "${stateRoot}" "${instanceStateDir}"
          for log in "${stdoutLog}" "${stderrLog}"; do
            if [ ! -e "$log" ]; then
              ${pkgs.coreutils}/bin/install -m 0600 /dev/null "$log"
            else
              ${pkgs.coreutils}/bin/chmod 0600 "$log"
            fi
          done
          ${lib.optionalString cfg.reporting.enable ''
            ${reportCredentialInstaller} \
              ${lib.escapeShellArg cfg.reporting.apiKeyEnvFile} \
              ${lib.escapeShellArg reportCredentialFile} \
              ${lib.escapeShellArg cfg.reporting.apiKeyVariable}
          ''}
        '';

    # Keep the service in Home Manager's LaunchAgent inventory and domain map.
    # The final-generation substitution above removes only HM's shell wrapper.
    launchd.agents.paimos-agentd = {
      enable = true;
      config = serviceConfig;
    };
  };
}
