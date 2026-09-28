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
  };
}
