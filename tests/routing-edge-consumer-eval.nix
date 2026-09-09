# NIX-447: project selected routing-edge fields from the actual csb1 host.
# Evaluation only — nothing builds or activates a NixOS system.
#
# The host configuration is read from a committed Git flake ref (self.rev).
# This file must not emit raw config, env, or secret values.
let
  flakeRef = builtins.getEnv "NIX447_FLAKE_REF";
  validFlakeRef = builtins.match "git\\+file://[^?]+\\?rev=[0-9a-f]{40}&shallow=1" flakeRef != null;
  flake =
    assert validFlakeRef;
    builtins.getFlake flakeRef;
  inherit (flake.inputs.nixpkgs) lib;
  host = flake.nixosConfigurations.csb1;
  cfg = host.config.services.inspr.routingEdge;
  providerFile = "traefik/dynamic/inspr-routing-edge.yml";

  routingEtcNames = lib.filter (
    name:
    name == providerFile || name == cfg.external.providerFile || lib.hasInfix "inspr-routing-edge" name
  ) (builtins.attrNames host.config.environment.etc);

  volumeTexts =
    v:
    if builtins.isString v then
      [ v ]
    else if builtins.isAttrs v then
      lib.filter (x: x != null && builtins.isString x) [
        (v.source or null)
        (v.target or null)
      ]
    else
      [ ];

  traefikVolumes = host.config.nixcfg.composeStack.renderedSpec.services.traefik.volumes or [ ];
  composeMentionsOwnedFragment = lib.any (
    v: lib.any (t: lib.hasInfix "inspr-routing-edge" t) (volumeTexts v)
  ) traefikVolumes;

  routingFailedAssertions = lib.filter (
    item: !item.assertion && lib.hasInfix "routingEdge" (item.message or "")
  ) host.config.assertions;

  routingWarnings = lib.filter (w: lib.hasInfix "routingEdge" w) host.config.warnings;

  invalid = host.extendModules {
    modules = [
      (
        { lib, ... }:
        {
          services.inspr.routingEdge.enable = lib.mkForce true;
        }
      )
    ];
  };

  enableTrueMissingContract = builtins.tryEval (
    builtins.deepSeq invalid.config.services.inspr.routingEdge.generatedFragmentFile true
  );
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
  packageName = cfg.package.pname or cfg.package.name;
  packageSystem = cfg.package.system;
  hasRoutingEdgeService = host.config.systemd.services ? "inspr-routing-edge";
  routingEtcNames = routingEtcNames;
  composeMentionsOwnedFragment = composeMentionsOwnedFragment;
  generatedFragmentFile = cfg.generatedFragmentFile;
  generatedDeployment = cfg.generatedDeployment;
  routingFailedAssertionCount = builtins.length routingFailedAssertions;
  routingWarningCount = builtins.length routingWarnings;
  enableTrueMissingContractFailed = !enableTrueMissingContract.success;
}
