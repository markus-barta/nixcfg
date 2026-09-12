{
  root ? ../.,
  activate ? false,
  hostId ? "janus-test",
  instanceLabel ? "Janus test",
  paimosOrigin ? "https://pm.barta.cm",
  paimosBrowserUrl ? "https://flow.example/paimos",
  apiKeyFile ? "/run/janus/flow-host/api-key",
  configFile ? "/run/janus/flow-host/config.json",
  projectId ? 17,
  projectRef ? "paimos:proj-9b2899fb59591130607952d66fcb5607",
  label ? "Test project",
  principalRefs ? [ "opaque-subject-a" ],
  bindings ? null,
}:
let
  flake = builtins.getFlake (toString root);
  pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
  resolvedBindings =
    if bindings == null then
      [
        {
          inherit
            projectId
            projectRef
            label
            principalRefs
            ;
        }
      ]
    else
      bindings;
  evaluated = flake.inputs.nixpkgs.lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      (root + "/modules/janus-flow-host/default.nix")
      (
        { lib, ... }:
        {
          options.assertions = lib.mkOption {
            type = lib.types.listOf lib.types.anything;
            default = [ ];
          };
          options.systemd.services = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
          };
        }
      )
      {
        inspr.janusFlowHost = {
          enable = true;
          inherit
            activate
            hostId
            instanceLabel
            paimosOrigin
            paimosBrowserUrl
            apiKeyFile
            configFile
            ;
          bindings = resolvedBindings;
        };
      }
    ];
  };
  failedAssertions = builtins.filter (item: !(item.assertion or true)) evaluated.config.assertions;
in
if failedAssertions != [ ] then
  throw (
    builtins.concatStringsSep "\n" (
      map (item: item.message or "inspr.janusFlowHost assertion failed") failedAssertions
    )
  )
else
  {
    generated = evaluated.config.inspr.janusFlowHost.generated;
    activated = evaluated.config.systemd.services ? janus-flow-host-config;
  }
