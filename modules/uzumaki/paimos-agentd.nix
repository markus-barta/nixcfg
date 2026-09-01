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
  logDirectory = "${home}/Library/Logs/paimos-agentd";
  reportCredentialFile = "${stateRoot}/report-api-key";
  sdkPath = "${pkgs.claude-agent-sdk}/${pkgs.claude-agent-sdk.sdkRelativePath}";
  codexLauncher = pkgs.writeShellScriptBin "paimos-agentd-codex" ''
    export PATH=${lib.escapeShellArg "${pkgs.nodejs}/bin:/usr/bin:/bin:/usr/sbin:/sbin"}
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
        assertion = lib.hasPrefix "/" cfg.codexPath && lib.hasPrefix "/" cfg.claudePath;
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
    ];

    home.packages = [
      pkgs.paimos-cli
      pkgs.claude-agent-sdk
      pkgs.nodejs
    ];

    home.activation.paimosAgentdPrivateState = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${pkgs.coreutils}/bin/install -d -m 0700 "${stateRoot}" "${logDirectory}"
      for log in "${logDirectory}/stdout.log" "${logDirectory}/stderr.log"; do
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

    launchd.agents.paimos-agentd = {
      enable = true;
      config = {
        Label = "at.inspr.paimos-agentd";
        ProgramArguments = [
          "${pkgs.paimos-cli}/bin/paimos-agentd"
          "serve"
          "--instance"
          cfg.instance
          "--state-root"
          stateRoot
          "--codex-path"
          "${codexLauncher}/bin/paimos-agentd-codex"
          "--claude-path"
          cfg.claudePath
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
        ];
        KeepAlive = true;
        RunAtLoad = true;
        ProcessType = "Background";
        ThrottleInterval = 10;
        StandardOutPath = "${logDirectory}/stdout.log";
        StandardErrorPath = "${logDirectory}/stderr.log";
      };
    };
  };
}
