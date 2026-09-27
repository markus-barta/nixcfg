{ root }:
let
  flake = builtins.getFlake (toString root);
  base = flake.homeConfigurations."markus@mbp2607";
  lib = base.pkgs.lib;
  candidate =
    changes:
    base.extendModules {
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
  invalid =
    changes:
    !(builtins.tryEval (builtins.deepSeq (candidate changes).activationPackage.drvPath true)).success;
in
{
  candidate = enabled.activationPackage;
  evidence = {
    defaultEnabled = base.config.uzumaki.aeon.agentd.enable;
    defaultHasService = base.config.launchd.agents ? aeon-agentd;
    assertions = failures enabled;
    service = enabled.config.launchd.agents.aeon-agentd.config;
    classicUnchanged =
      base.config.launchd.agents.paimos-agentd == enabled.config.launchd.agents.paimos-agentd;
    classicActivationUnchanged =
      base.config.home.activation.paimosAgentdPrivateState
      == enabled.config.home.activation.paimosAgentdPrivateState;
    preflight = enabled.config.home.activation.aeonAgentdPreflight;
    state = enabled.config.home.activation.aeonAgentdState;
    invalid = {
      noEstimate = invalid { estimates.requests = lib.mkForce 0; };
      emptyId = invalid { daemonId = lib.mkForce ""; };
      sharedFiles = invalid { accountsFile = lib.mkForce base.config.uzumaki.aeon.agentd.agentKeyFile; };
      storeKey = invalid { agentKeyFile = lib.mkForce "/nix/store/example/key"; };
      classicStateKey = invalid {
        agentKeyFile = lib.mkForce "${base.config.home.homeDirectory}/Library/Caches/paimos/agentd/key";
      };
      relativeWorkspace = invalid { workspace = lib.mkForce "Code"; };
      mutableVendor = invalid { cursorPath = lib.mkForce "/usr/local/bin/cursor-agent"; };
      noAdapter = invalid { cursorPath = lib.mkForce null; };
    };
  };
}
