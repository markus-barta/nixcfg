# NIX-447: focused eval of the csb1 inactive routing-edge consumer boundary.
# Evaluation only — nothing builds or activates a NixOS system.
let
  root = ../.;
  flake = builtins.getFlake (toString root);
  pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
  inherit (flake.inputs.nixpkgs) lib;
  routingModule = flake.inputs.inspr-modules.nixosModules.routing-edge;
  routingPackage = flake.inputs.inspr-modules.packages.x86_64-linux.routing-edge;

  stubNixosModule =
    { lib, ... }:
    {
      options = {
        systemd.services = lib.mkOption {
          type = lib.types.attrsOf lib.types.unspecified;
          default = { };
        };
        networking.firewall.allowedTCPPorts = lib.mkOption {
          type = lib.types.listOf lib.types.int;
          default = [ ];
        };
        environment.etc = lib.mkOption {
          type = lib.types.attrsOf lib.types.unspecified;
          default = { };
        };
        warnings = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
        assertions = lib.mkOption {
          type = lib.types.listOf (
            lib.types.submodule {
              options = {
                assertion = lib.mkOption { type = lib.types.bool; };
                message = lib.mkOption { type = lib.types.str; };
              };
            }
          );
          default = [ ];
        };
      };
    };

  # Same inactive boundary as hosts/csb1/configuration.nix. Forcing the
  # generated document is safe while disabled; it stays empty and never
  # carries origins or TLS paths.
  evaluated = lib.evalModules {
    modules = [
      stubNixosModule
      routingModule
      { _module.args = { inherit pkgs; }; }
      {
        services.inspr.routingEdge = {
          enable = false;
          package = routingPackage;
          deploymentMode = "external-file-provider";
          allowUnpinnedTraefik = false;
          entrypoint.name = "web-secure";
          external = {
            certificateResolver = "default";
            resourceNamespace = "inspr-routing-edge";
            providerFile = "traefik/dynamic/inspr-routing-edge.yml";
          };
        };
      }
    ];
  };

  cfg = evaluated.config.services.inspr.routingEdge;
  failedAssertions = builtins.filter (item: !item.assertion) evaluated.config.assertions;
in
{
  enable = cfg.enable;
  deploymentMode = cfg.deploymentMode;
  entrypointName = cfg.entrypoint.name;
  certificateResolver = cfg.external.certificateResolver;
  resourceNamespace = cfg.external.resourceNamespace;
  providerFile = cfg.external.providerFile;
  allowUnpinnedTraefik = cfg.allowUnpinnedTraefik;
  existingTraefikVersion = cfg.external.existingTraefikVersion;
  upstreamIds = builtins.attrNames cfg.upstreams;
  hasRoutingEdgeService = evaluated.config.systemd.services ? "inspr-routing-edge";
  etcNames = builtins.attrNames evaluated.config.environment.etc;
  firewallPorts = evaluated.config.networking.firewall.allowedTCPPorts;
  generatedFragmentFile = cfg.generatedFragmentFile;
  generatedDeployment = cfg.generatedDeployment;
  failedAssertionCount = builtins.length failedAssertions;
  warningCount = builtins.length evaluated.config.warnings;
  packageName = routingPackage.pname or routingPackage.name;
}
