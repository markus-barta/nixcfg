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
  sdkPath = "${pkgs.claude-agent-sdk}/${pkgs.claude-agent-sdk.sdkRelativePath}";
  codexLauncher = pkgs.writeShellScriptBin "paimos-agentd-codex" ''
    export PATH=${lib.escapeShellArg "${pkgs.nodejs}/bin:/usr/bin:/bin:/usr/sbin:/sbin"}
    exec ${lib.escapeShellArg cfg.codexPath} "$@"
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
