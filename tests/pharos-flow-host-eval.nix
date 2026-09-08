{
  root ? ../.,
  activate ? false,
  hostId ? "pharos-test",
  instanceLabel ? "Pharos test",
  paimosOrigin ? "https://pm.barta.cm",
  apiKeyFile ? "/run/pharos/flow-host/api-key",
  configFile ? "/run/pharos/flow-host/config.json",
  projectId ? 17,
  projectRef ? "paimos:proj-9b2899fb59591130607952d66fcb5607",
  label ? "Test project",
  hosts ? [ "hsb8" ],
  operatorRefs ? [ "operator-a" ],
  bindings ? null,
}:
let
  flake = builtins.getFlake (toString root);
  pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
  defaultBinding = {
    inherit
      projectId
      projectRef
      label
      hosts
      operatorRefs
      ;
  };
  resolvedBindings = if bindings == null then [ defaultBinding ] else bindings;
  evaluated = flake.inputs.nixpkgs.lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      (root + "/modules/pharos-flow-host/default.nix")
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
        inspr.pharosFlowHost = {
          enable = true;
          inherit
            activate
            hostId
            instanceLabel
            paimosOrigin
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
      map (item: item.message or "inspr.pharosFlowHost assertion failed") failedAssertions
    )
  )
else
  {
    generated = evaluated.config.inspr.pharosFlowHost.generated;
    activated = evaluated.config.systemd.services ? pharos-flow-host-config;
  }
