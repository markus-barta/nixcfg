# NIX-583: isolated Aeon owner. Classic paimos-agentd was retired in NIX-584.
# NIX-589: optional paired mode. The same LaunchAgent label then runs
# `aeon-agentd serve --setup-root <paired.stateRoot>` from a person-approved
# pairing (`aeon-agentd pair`, AEON-333) instead of the explicit-key daemon.
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
  withinWorkspace = path: path == cfg.workspace || lib.hasPrefix "${cfg.workspace}/" path;
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
      PATH =
        lib.optionalString (cfg.codexPath != null || cfg.claudePath != null) "${pkgs.nodejs}/bin:"
        + "/usr/bin:/bin:/usr/sbin:/sbin";
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

  # NIX-589: paired mode. Paired serve accepts no runtime overrides; harness
  # executables and the Claude Node/SDK pins come from the approved pairing.
  paired = cfg.enable && cfg.paired.enable;
  managed = cfg.enable && !cfg.paired.enable;
  pairedLogRoot = "${home}/Library/Logs/aeon-agentd";
  # Deliberately pinned Claude runtime (fixed-output: nixpkgs/HM updates never
  # move it). setup/pair stores the physical store paths behind the stable
  # links below, and the daemon refuses Claude once a pin stops resolving to
  # itself, so bumping this is a deliberate step that needs re-pairing the
  # Claude harness until Aeon re-resolves stable links at start (AEON
  # follow-up on NIX-589). `aeon-agentd add-harness` is NOT a recovery path:
  # it validates the existing saved pins first.
  claudeRuntime = pkgs.callPackage ../../pkgs/aeon-agentd-claude-runtime { };
  runtimeShare = ".local/share/aeon-agentd";
  stableNode = "${home}/${runtimeShare}/bin/node";
  stableSdk = "${home}/${runtimeShare}/lib/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs";
  # `pair` (AEON-333) exists since release 12 (stable107); older pins get the
  # equivalent `setup` command.
  pairSinceVersion = "260929193046.0.0";
  usePair = pairSinceVersion != null && lib.versionAtLeast pkgs.aeon-agentd.version pairSinceVersion;
  # One version-aware command for both the activation refusal and the option
  # documentation (the docs use placeholders instead of configured paths).
  mkPairCommand =
    {
      workspace,
      stateRoot,
      node,
      sdk,
    }:
    lib.escapeShellArgs (
      [ "aeon-agentd" ]
      ++ (
        # `pair` would take the current directory as the working folder, so
        # both commands name workspace and pairing root explicitly.
        [
          (if usePair then "pair" else "setup")
          "--workspace"
          workspace
          "--state-root"
          stateRoot
        ])
      ++ [
        "--url"
        "https://aeon.barta.cm"
        "--harness"
        "claude"
        "--node-path"
        node
        "--claude-sdk-path"
        sdk
      ]
    );
  pairCommand = mkPairCommand {
    inherit (cfg) workspace;
    inherit (cfg.paired) stateRoot;
    node = stableNode;
    sdk = stableSdk;
  };
  pairCommandDoc = mkPairCommand {
    workspace = "<workspace>";
    stateRoot = "<paired.stateRoot>";
    node = "<home>/${runtimeShare}/bin/node";
    sdk = "<home>/${runtimeShare}/lib/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs";
  };
  pairHint = "run `${pairCommand}`, approve the computer in Aeon, then switch again";
  enrollmentDir = "${home}/Library/Application Support/aeon/agentd";
  pairedService = {
    Label = label;
    ProgramArguments = [
      "${pkgs.aeon-agentd}/bin/aeon-agentd"
      "serve"
      "--setup-root"
      cfg.paired.stateRoot
    ];
    WorkingDirectory = home;
    RunAtLoad = true;
    # A revoked or disconnected pairing makes paired serve exit 0 on purpose;
    # launchd must not restart it then (and HM must not revive it: preflight).
    KeepAlive = {
      SuccessfulExit = false;
    };
    ProcessType = "Background";
    ThrottleInterval = 30;
    Umask = 63;
    StandardOutPath = "${pairedLogRoot}/stdout.log";
    StandardErrorPath = "${pairedLogRoot}/stderr.log";
    # No browser-refusal variables here: they would reach every paired harness
    # and block the native headless route Cursor/Claude keep (NIX-578). Setup
    # pins the physical target of `codex` on the pairing shell's PATH, which is
    # the guard's env-only Codex launcher, so the refusal travels with Codex
    # alone; Cursor and Claude are pinned as their plain executables.
    EnvironmentVariables = {
      PATH = "${claudeRuntime.node}/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      DISABLE_AUTOUPDATER = "1";
      DISABLE_UPDATES = "1";
      FORCE_AUTOUPDATE_PLUGINS = "1";
    };
  };
  pairedPlist = pkgs.writeText "${label}.plist" (
    lib.generators.toPlist { escape = true; } pairedService
  );
  pairedPreflightConfig = builtins.toJSON {
    mode = "paired";
    inherit home;
    inherit (cfg) workspace;
    pairedRoot = cfg.paired.stateRoot;
    logRoot = pairedLogRoot;
    inherit pairHint;
    managedPaths = [
      enrollmentDir
      cfg.stateRoot
    ]
    ++ lib.filter (p: p != "") [
      cfg.agentKeyFile
      cfg.accountsFile
    ];
  };
  pairedPreflightScript = pkgs.writeText "aeon-agentd-paired-preflight.py" ''
    ${builtins.readFile ../../scripts/aeon-agentd-preflight.py}
    if __name__ == "__main__":
        main(json.loads(${builtins.toJSON pairedPreflightConfig}))
  '';
  pairedPreflight = "${pkgs.python3}/bin/python3 ${pairedPreflightScript}";
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
      default = "${home}/Library/Application Support/aeon/agentd/state";
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
    paired = {
      enable = lib.mkEnableOption "the person-approved paired runtime on the same LaunchAgent label (`serve --setup-root`). Pair first with `${pairCommandDoc}` and approve the computer in Aeon; activation refuses to switch until that pairing root is approved";
      stateRoot = lib.mkOption {
        type = lib.types.str;
        default = "${home}/Library/Application Support/aeon/paired";
        description = ''
          Private pairing root written by `aeon-agentd pair`/`setup` (AEON-333
          default on macOS). Owner-owned mode 0700, outside the workspace, the
          Nix store and the explicit-key daemon state.
        '';
      };
      # TODO(AEON-334): pi as a paired harness arrives with guided setup; no
      # module change is expected beyond keeping its executable GC-rooted.
    };
    estimates = lib.genAttrs [ "requests" "tokens" "cost-micros" ] (
      unit:
      lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 0;
        description = "Approved per-run ${unit} reservation estimate. At least one unit must be positive; this creates no allowance window.";
      }
    );
  };

  config = lib.mkMerge [
    # Both modes: `aeon-agentd setup`/`pair` on PATH (the signed release
    # binary on macOS, NIX-588) and stable links to the pinned Claude runtime,
    # kept GC-rooted by the Home Manager closure. Pass them explicitly:
    #   --node-path ~/.local/share/aeon-agentd/bin/node
    #   --claude-sdk-path ~/.local/share/aeon-agentd/lib/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs
    (lib.mkIf cfg.enable {
      home.packages = [ pkgs.aeon-agentd ];
      home.file."${runtimeShare}/bin/node".source = "${claudeRuntime.node}/bin/node";
      home.file."${runtimeShare}/lib/node_modules/@anthropic-ai/claude-agent-sdk".source =
        "${claudeRuntime.sdk}/lib/node_modules/@anthropic-ai/claude-agent-sdk";
    })
    (lib.mkIf managed {
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
            && cfg.agentKeyFile != cfg.accountsFile
            && !lib.any withinWorkspace [
              cfg.agentKeyFile
              cfg.accountsFile
              cfg.stateRoot
            ];
          message = "Aeon agentd requires distinct private paths outside its workspace, classic and the Nix store";
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
            run ${preflight} prepare
          '';
      launchd.agents.aeon-agentd = {
        enable = true;
        config = service;
      };

      # Preserve direct executable ownership, avoiding HM's sh/wait4path wrapper.
      home.extraBuilderCommands = lib.mkOrder 1600 ''
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
    })
    (lib.mkIf paired {
      assertions = [
        {
          assertion = pkgs.stdenv.hostPlatform.isDarwin;
          message = "Aeon agentd requires macOS launchd";
        }
        {
          assertion =
            externalPath cfg.paired.stateRoot
            && !lib.hasPrefix "${enrollmentDir}/" cfg.paired.stateRoot
            && cfg.paired.stateRoot != enrollmentDir
            && !lib.hasPrefix "${cfg.paired.stateRoot}/" enrollmentDir
            && externalPath cfg.workspace
            && !withinWorkspace cfg.paired.stateRoot;
          message = "Aeon paired agentd requires a private pairing root outside its workspace, the explicit-key daemon state, classic and the Nix store";
        }
        {
          # The guard's env-only Codex launcher is what setup pins for Codex.
          assertion = guard.enable;
          message = "Aeon paired agentd requires the browser refusal guard";
        }
      ];

      # Refuse before HM changes anything: an unapproved or unsafe pairing root
      # aborts this activation, so the previous generation (and its running
      # explicit-key daemon) stays exactly as it was.
      home.activation.aeonAgentdPreflight = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
        ${pairedPreflight} check
      '';
      home.activation.aeonAgentdState =
        lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ]
          ''
            run ${pairedPreflight} prepare
          '';
      launchd.agents.aeon-agentd = {
        enable = true;
        config = pairedService;
      };

      home.extraBuilderCommands = lib.mkOrder 1600 ''
        aeon_agents=$(${pkgs.coreutils}/bin/readlink -f "$out/LaunchAgents")
        aeon_direct="$out/LaunchAgents-aeon-direct"
        ${pkgs.coreutils}/bin/mkdir -p "$aeon_direct"
        for agent in "$aeon_agents"/*.plist; do
          [ -e "$agent" ] || continue
          name=$(${pkgs.coreutils}/bin/basename "$agent")
          ${pkgs.coreutils}/bin/ln -s "$(${pkgs.coreutils}/bin/readlink -f "$agent")" "$aeon_direct/$name"
        done
        ${pkgs.coreutils}/bin/ln -sfn ${lib.escapeShellArg pairedPlist} "$aeon_direct/${label}.plist"
        ${pkgs.coreutils}/bin/unlink "$out/LaunchAgents"
        ${pkgs.coreutils}/bin/ln -s LaunchAgents-aeon-direct "$out/LaunchAgents"
      '';
    })
  ];
}
