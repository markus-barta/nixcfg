{
  root ? ../.,
  versionScheme ? "legacy",
  artifactVersion ? "0.2.0",
  releaseChannel ? "stable",
  releaseSequence ? 123,
  digest ? "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  commitDigest ? "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  releaseManifestCoordinate ? "ghcr:inspr-at/pharos/releases/0.2.0",
  releaseManifestDigest ? "sha256:9999999999999999999999999999999999999999999999999999999999999999",
  updateRestartJobId ? "action_job_123",
  deploymentHandoffId ? "01ARZ3NDEKTSV4RRFFQ69G5FAV",
  omitArtifactField ? null,
}:
let
  flake = builtins.getFlake (toString root);
  pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
  rawArtifact = {
    inherit
      versionScheme
      releaseChannel
      releaseSequence
      digest
      commitDigest
      releaseManifestCoordinate
      releaseManifestDigest
      ;
    version = artifactVersion;
  };
  artifact =
    if omitArtifactField == null then
      rawArtifact
    else
      builtins.removeAttrs rawArtifact [ omitArtifactField ];
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
              inherit artifact updateRestartJobId;
            }
            {
              handoffId = "01ARZ3NDEKTSV4RRFFQ69G5FAW";
              handoffSecretFile = "/run/pharos/paimos/verification-handoff-secret";
              stage = "verification";
              host = "csb1";
              inherit artifact deploymentHandoffId;
            }
          ];
        };
      }
    ];
  };
  failedAssertions = builtins.filter (item: !(item.assertion or true)) evaluated.config.assertions;
in
if failedAssertions != [ ] then
  throw (
    builtins.concatStringsSep "\n" (
      map (item: item.message or "inspr.pharosPaimosDelivery assertion failed") failedAssertions
    )
  )
else
  evaluated.config.inspr.pharosPaimosDelivery.generated
