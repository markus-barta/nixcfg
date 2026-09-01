{
  root ? ../.,
  versionScheme ? "legacy",
  artifactVersion ? "0.2.0",
}:
let
  flake = builtins.getFlake (toString root);
  pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
  artifact = {
    inherit versionScheme;
    version = artifactVersion;
    digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    commitDigest = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  };
  evaluated = flake.inputs.nixpkgs.lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      (root + "/modules/pharos-paimos-delivery/default.nix")
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
        inspr.pharosPaimosDelivery = {
          enable = true;
          paimosOrigin = "https://pm.barta.cm";
          apiKeyFile = "/run/pharos/paimos/owner-api-key";
          intents = [
            {
              handoffId = "01ARZ3NDEKTSV4RRFFQ69G5FAV";
              handoffSecretFile = "/run/pharos/paimos/deployment-handoff-secret";
              stage = "deployment";
              host = "csb1";
              inherit artifact;
              updateRestartJobId = "action_job_123";
            }
            {
              handoffId = "01ARZ3NDEKTSV4RRFFQ69G5FAW";
              handoffSecretFile = "/run/pharos/paimos/verification-handoff-secret";
              stage = "verification";
              host = "csb1";
              inherit artifact;
              deploymentHandoffId = "01ARZ3NDEKTSV4RRFFQ69G5FAV";
            }
          ];
        };
      }
    ];
  };
in
evaluated.config.inspr.pharosPaimosDelivery.generated
