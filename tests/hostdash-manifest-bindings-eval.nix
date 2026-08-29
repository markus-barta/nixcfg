{
  nixpkgs,
  system,
}:
let
  pkgs = import nixpkgs { inherit system; };
  inherit (pkgs) lib;
  evaluated = lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      (
        { lib, ... }:
        {
          options = {
            assertions = lib.mkOption {
              type = lib.types.listOf lib.types.attrs;
              default = [ ];
            };
            networking.hostName = lib.mkOption {
              type = lib.types.str;
              default = "hsb8";
            };
            environment.etc = lib.mkOption {
              type = lib.types.attrs;
              default = { };
            };
          };
          config.networking.hostName = "hsb8";
        }
      )
      ../modules/hostdash-manifest.nix
      {
        services.hostdash.manifest = {
          enable = true;
          wings = [
            {
              id = "ops";
              name = "Operations";
            }
          ];
          services = [
            {
              wing = "ops";
              name = "Container binding";
              passive = true;
              container = "smoke-container";
            }
            {
              wing = "ops";
              name = "Unit binding";
              passive = true;
              unit = "smoke-unit.service";
            }
            {
              wing = "ops";
              name = "Extra binding";
              passive = true;
              extra = "smoke-extra";
            }
            {
              wing = "ops";
              name = "Unbound service";
              passive = true;
            }
          ];
        };
      }
    ];
  };
in
evaluated.config.services.hostdash.manifest.generated
