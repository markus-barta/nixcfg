# NIX-583: additive Aeon owner; classic paimos-agentd remains independent.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.uzumaki.aeon.agentd;
  home = config.home.homeDirectory;
  label = "at.inspr.aeon-agentd";
  guard = config.uzumaki.agentBrowserGuard;
  guardLib = import ../../lib/agent-browser-guard.nix { inherit lib; };
  externalPath =
    path:
    lib.hasPrefix "${home}/" path
    && !(lib.hasInfix "/../" path || lib.hasInfix "/./" path || lib.hasInfix "//" path)
    && !(lib.hasSuffix "/.." path || lib.hasSuffix "/." path || lib.hasSuffix "/" path)
    && !(lib.hasPrefix "${home}/Library/Caches/paimos/" path)
    && !(lib.hasPrefix "${home}/Library/Application Support/paimos/" path);
  pinnedPath = path: path == null || lib.hasPrefix "/nix/store/" path;
  vendorOption =
    name:
    lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Pinned Nix store ${name} executable; null disables this adapter. Account enrollment stays external.";
    };
  native =
    name: path:
    "${pkgs.writeShellScriptBin "aeon-agentd-${name}" (guardLib.mkNativeLauncherText path)}/bin/aeon-agentd-${name}";
  codex = pkgs.writeShellScriptBin "aeon-agentd-codex" ''
    export PATH=${lib.escapeShellArg "${pkgs.nodejs}/bin:/usr/bin:/bin:/usr/sbin:/sbin"}
    ${guard.envOnlyExports}
    exec ${lib.escapeShellArg cfg.codexPath} "$@"
  '';
  args = [
    "${pkgs.aeon-agentd}/bin/aeon-agentd"
    "serve"
    "--url"
    "https://aeon.barta.cm"
    "--agent-key-file"
    cfg.agentKeyFile
    "--workspace"
    cfg.workspace
    "--state-root"
    cfg.stateRoot
    "--daemon-id"
    cfg.daemonId
    "--accounts"
    cfg.accountsFile
  ]
  ++ lib.optionals (cfg.codexPath != null) [
    "--codex-path"
    "${codex}/bin/aeon-agentd-codex"
  ]
  ++ lib.optionals (cfg.claudePath != null) [
    "--claude-path"
    (native "claude" cfg.claudePath)
    "--node-path"
    "${pkgs.nodejs}/bin/node"
    "--claude-sdk-path"
    "${pkgs.claude-agent-sdk}/${pkgs.claude-agent-sdk.sdkRelativePath}"
  ]
  ++ lib.optionals (cfg.piPath != null) [
    "--pi-path"
    (native "pi" cfg.piPath)
  ]
  ++ lib.optionals (cfg.cursorPath != null) [
    "--cursor-path"
    (native "cursor" cfg.cursorPath)
  ]
  ++ lib.concatLists (
    lib.mapAttrsToList (
      unit: value:
      lib.optionals (value > 0) [
        "--estimate-${unit}"
        (toString value)
      ]
    ) cfg.estimates
  );
  service = {
    Label = label;
    ProgramArguments = args;
    WorkingDirectory = cfg.workspace;
    RunAtLoad = true;
    KeepAlive = true;
    ProcessType = "Background";
    ThrottleInterval = 30;
    Umask = 63;
    StandardOutPath = "${cfg.stateRoot}/stdout.log";
    StandardErrorPath = "${cfg.stateRoot}/stderr.log";
    EnvironmentVariables = {
      PATH = "${pkgs.nodejs}/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      DISABLE_AUTOUPDATER = "1";
      DISABLE_UPDATES = "1";
      FORCE_AUTOUPDATE_PLUGINS = "1";
    };
  };
  plist = pkgs.writeText "${label}.plist" (lib.generators.toPlist { escape = true; } service);
  preflightConfig = builtins.toJSON {
    inherit home;
    inherit (cfg)
      agentKeyFile
      accountsFile
      workspace
      stateRoot
      ;
  };
  # Embed only the declared non-secret paths. The helper has no caller-selected
  # configuration-file read interface; enrollment bytes never enter the store.
  preflightScript = pkgs.writeText "aeon-agentd-preflight.py" ''
    ${builtins.readFile ../../scripts/aeon-agentd-preflight.py}
    if __name__ == "__main__":
        main(json.loads(${builtins.toJSON preflightConfig}))
  '';
  preflight = "${pkgs.python3}/bin/python3 ${preflightScript}";
in
{
  options.uzumaki.aeon.agentd = {
    enable = lib.mkEnableOption "the isolated Aeon LaunchAgent (requires reviewed enrollment)";
    agentKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "External dedicated Aeon key, regular owner-owned mode 0600. Never use the shared CLI key.";
    };
    accountsFile = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "External mode-0600 Aeon registry binding approved account UUID/key/harness/vendor context to this daemon.";
    };
    workspace = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Existing physical approved workspace root; checked without following symlinks at activation.";
    };
    stateRoot = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "${home}/Library/Caches/aeon/agentd";
      description = "Dedicated mode-0700 journal/socket root; never shared with classic.";
    };
    daemonId = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Stable opaque enrollment identifier. Preserve across restarts and bind explicitly in Aeon.";
    };
    codexPath = vendorOption "Codex";
    claudePath = vendorOption "Claude";
    piPath = vendorOption "Pi";
    cursorPath = vendorOption "Cursor";
    estimates = lib.genAttrs [ "requests" "tokens" "cost-micros" ] (
      unit:
      lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 0;
        description = "Approved per-run ${unit} reservation estimate. At least one unit must be positive; this creates no allowance window.";
      }
    );
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "Aeon agentd requires macOS launchd";
      }
      {
        assertion =
          lib.all externalPath [
            cfg.agentKeyFile
            cfg.accountsFile
            cfg.workspace
          ]
          && cfg.agentKeyFile != cfg.accountsFile;
        message = "Aeon agentd requires distinct private paths and a workspace under home, outside classic and the Nix store";
      }
      {
        assertion = builtins.match "[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}" cfg.daemonId != null;
        message = "Aeon agentd requires a stable opaque daemonId";
      }
      {
        assertion = lib.any (n: n > 0) (lib.attrValues cfg.estimates);
        message = "Aeon agentd requires at least one approved positive allowance estimate";
      }
      {
        assertion =
          lib.all pinnedPath [
            cfg.codexPath
            cfg.claudePath
            cfg.piPath
            cfg.cursorPath
          ]
          && lib.any (p: p != null) [
            cfg.codexPath
            cfg.claudePath
            cfg.piPath
            cfg.cursorPath
          ];
        message = "Aeon agentd requires at least one pinned Nix store vendor executable";
      }
      {
        assertion = cfg.codexPath == null || guard.enable;
        message = "Aeon agentd Codex requires the browser refusal guard";
      }
    ];

    # Check before HM changes anything. This helper reads metadata only, never
    # credential/registry bytes; the pinned daemon validates their semantics.
    home.activation.aeonAgentdPreflight = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
      ${preflight} check
    '';
    home.activation.aeonAgentdState =
      lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ]
        ''
          ${preflight} prepare
        '';
    launchd.agents.aeon-agentd = {
      enable = true;
      config = service;
    };

    # Preserve direct executable ownership, avoiding HM's sh/wait4path wrapper.
    # A separate output directory composes with classic's existing replacement.
    home.extraBuilderCommands = lib.mkAfter ''
      aeon_agents=$(${pkgs.coreutils}/bin/readlink -f "$out/LaunchAgents")
      aeon_direct="$out/LaunchAgents-aeon-direct"
      ${pkgs.coreutils}/bin/mkdir -p "$aeon_direct"
      for agent in "$aeon_agents"/*.plist; do
        [ -e "$agent" ] || continue
        name=$(${pkgs.coreutils}/bin/basename "$agent")
        ${pkgs.coreutils}/bin/ln -s "$(${pkgs.coreutils}/bin/readlink -f "$agent")" "$aeon_direct/$name"
      done
      ${pkgs.coreutils}/bin/ln -sfn ${lib.escapeShellArg plist} "$aeon_direct/${label}.plist"
      ${pkgs.coreutils}/bin/unlink "$out/LaunchAgents"
      ${pkgs.coreutils}/bin/ln -s LaunchAgents-aeon-direct "$out/LaunchAgents"
    '';
  };
}
