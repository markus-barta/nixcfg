# OPS-496: real NixOS option and rendered-unit evaluation without a build.
# The scoped mode uses hsb1's actual firewall declaration, avoiding unrelated
# private flake inputs. T117 also requires the full hsb1 flake by default.
{
  nixpkgs ? (builtins.getFlake (toString ../.)).inputs.nixpkgs.outPath,
}:
let
  pkgs = import nixpkgs { system = "x86_64-linux"; };
  host = import ../hosts/hsb1/configuration.nix {
    inherit pkgs;
    inherit (pkgs) lib;
    config = { };
    inputs = { };
  };
  system = import (nixpkgs + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      ../hosts/hsb1/aqara-nightlight.nix
      { networking.firewall = host.networking.firewall; }
    ];
  };
in
{
  service = {
    inherit (system.config.systemd.services.aqara-nightlight)
      serviceConfig
      environment
      wants
      after
      wantedBy
      ;
  };
  unit = system.config.systemd.units."aqara-nightlight.service".text;
  firewall = {
    inherit (system.config.networking.firewall) enable allowedTCPPorts;
  };
  miioVersion = pkgs.python3Packages.python-miio.version;
}
