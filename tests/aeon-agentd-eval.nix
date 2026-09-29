{ root }:
let
  flake = builtins.getFlake (toString root);
  host = flake.homeConfigurations."markus@mbp2607";
  base = host.extendModules {
    modules = [ { uzumaki.aeon.agentd.enable = lib.mkForce false; } ];
  };
  lib = host.pkgs.lib;
  candidate =
    changes:
    host.extendModules {
      modules = [
        {
          uzumaki.aeon.agentd = {
            enable = lib.mkForce true;
            estimates.requests = 1; # Synthetic build-only reservation, never activated.
          }
          // changes;
        }
      ];
    };
  enabled = candidate { };
  # NIX-589: paired mode on the same label; build/eval only, never activated.
  pairedCandidate =
    changes:
    host.extendModules {
      # Separate modules so `changes` merges into `paired` instead of
      # replacing the attribute set.
      modules = [
        {
          uzumaki.aeon.agentd = {
            enable = lib.mkForce true;
            paired.enable = true;
          };
        }
        { uzumaki.aeon.agentd = changes; }
      ];
    };
  paired = pairedCandidate { };
  home = base.config.home.homeDirectory;
  invalidPaired = {
    pairedInWorkspace = {
      paired.stateRoot = "${home}/Code/paired";
    };
    pairedInStore = {
      paired.stateRoot = "/nix/store/example/paired";
    };
    pairedInExplicitKeyState = {
      paired.stateRoot = "${home}/Library/Application Support/aeon/agentd/paired";
    };
    pairedIsExplicitKeyState = {
      paired.stateRoot = "${home}/Library/Application Support/aeon/agentd";
    };
    pairedInClassic = {
      paired.stateRoot = "${home}/Library/Application Support/paimos/paired";
    };
    pairedRelative = {
      paired.stateRoot = "Library/paired";
    };
  };
  failures =
    evaluated: map (a: a.message) (builtins.filter (a: !a.assertion) evaluated.config.assertions);
  invalid = {
    noEstimate = {
      estimates.requests = lib.mkForce 0;
    };
    emptyId = {
      daemonId = lib.mkForce "";
    };
    sharedFiles = {
      accountsFile = lib.mkForce base.config.uzumaki.aeon.agentd.agentKeyFile;
    };
    storeKey = {
      agentKeyFile = lib.mkForce "/nix/store/example/key";
    };
    classicStateKey = {
      agentKeyFile = lib.mkForce "${base.config.home.homeDirectory}/Library/Caches/paimos/agentd/key";
    };
    relativeWorkspace = {
      workspace = lib.mkForce "Code";
    };
    workspaceContainsEnrollment = {
      workspace = lib.mkForce "${base.config.home.homeDirectory}/Library";
    };
    mutableVendor = {
      cursorPath = lib.mkForce "/usr/local/bin/cursor-agent";
    };
    noAdapter = {
      cursorPath = lib.mkForce null;
      codexPath = lib.mkForce null;
    };
  };
in
{
  candidate = enabled.activationPackage;
  disabledCandidate = base.activationPackage;
  invalidCandidates = lib.mapAttrs (_name: changes: (candidate changes).activationPackage) invalid;
  pairedActivation = paired.activationPackage;
  invalidPairedCandidates = lib.mapAttrs (
    _name: changes: (pairedCandidate changes).activationPackage
  ) invalidPaired;
  evidence = {
    moduleDefaultEnabled = host.options.uzumaki.aeon.agentd.enable.default;
    hostEnabled = host.config.uzumaki.aeon.agentd.enable;
    defaultEnabled = base.config.uzumaki.aeon.agentd.enable;
    defaultHasService = base.config.launchd.agents ? aeon-agentd;
    assertions = failures enabled;
    service = enabled.config.launchd.agents.aeon-agentd.config;
    hasClassicAgent = host.config.launchd.agents ? paimos-agentd;
    preflight = enabled.config.home.activation.aeonAgentdPreflight;
    state = enabled.config.home.activation.aeonAgentdState;
    invalid = builtins.attrNames invalid;
    pairedDefaultEnabled = host.options.uzumaki.aeon.agentd.paired.enable.default;
    pairedEnableDescription = host.options.uzumaki.aeon.agentd.paired.enable.description;
    hostPairedEnabled = host.config.uzumaki.aeon.agentd.paired.enable;
    pairedStateRootDefault = host.options.uzumaki.aeon.agentd.paired.stateRoot.default;
    pairedAssertions = failures paired;
    pairedService = paired.config.launchd.agents.aeon-agentd.config;
    managedService = host.config.launchd.agents.aeon-agentd.config;
    pairedPreflight = paired.config.home.activation.aeonAgentdPreflight;
    pairedState = paired.config.home.activation.aeonAgentdState;
    guardEnvironment = host.config.uzumaki.agentBrowserGuard.launchdEnvironment;
    guardPrograms = {
      envOnly = builtins.attrNames host.config.uzumaki.agentBrowserGuard.envOnlyPrograms;
      native = builtins.attrNames host.config.uzumaki.agentBrowserGuard.nativePrograms;
      shadowed = builtins.attrNames host.config.uzumaki.agentBrowserGuard.shadowedPrograms;
    };
    pairedPreflightScript = builtins.head (
      builtins.match ".*(/nix/store/[a-z0-9]+-aeon-agentd-paired-preflight\\.py).*" paired.config.home.activation.aeonAgentdPreflight.data
    );
    homePackages = map (p: p.name or "") host.config.home.packages;
    agentdName = host.pkgs.aeon-agentd.name;
    runtimeFiles = {
      node = host.config.home.file.".local/share/aeon-agentd/bin/node".source;
      sdk =
        host.config.home.file.".local/share/aeon-agentd/lib/node_modules/@anthropic-ai/claude-agent-sdk".source;
    };
    claudeRuntime =
      let
        rt = host.pkgs.callPackage (root + "/pkgs/aeon-agentd-claude-runtime") { };
      in
      {
        node = "${rt.node}/bin/node";
        sdk = "${rt.sdk}/lib/node_modules/@anthropic-ai/claude-agent-sdk";
        nodeFixedOutput = rt.node.outputHash or null;
        sdkFixedOutput = rt.sdk.outputHash or null;
      };
    workspace = host.config.uzumaki.aeon.agentd.workspace;
    agentdVersion = host.pkgs.aeon-agentd.version;
    invalidPaired = builtins.attrNames invalidPaired;
  };
}
