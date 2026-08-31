{
  nixpkgs,
  system,
}:
let
  pkgs = import nixpkgs { inherit system; };
  inherit (pkgs) lib;

  evaluate =
    status:
    lib.evalModules {
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
              environment.etc = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
              systemd.services = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
              systemd.timers = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
            };
          }
        )
        ../modules/hostdash-status.nix
        { services.hostdash.status = status; }
      ];
    };

  failures =
    evaluated:
    map (item: item.message) (builtins.filter (item: !item.assertion) evaluated.config.assertions);

  base = {
    enable = true;
    host = "fixture";
    containers = [
      "app"
      "worker"
    ];
    units = [ "compose-fixture-update.timer" ];
    httpProbes.app = "http://127.0.0.1:8080/health";
  };

  valid = evaluate base;
  legacy = evaluate (
    base
    // {
      containers = null;
      httpProbes.unlisted = "http://127.0.0.1:8080/";
    }
  );
  duplicateContainer = evaluate (
    base
    // {
      containers = [
        "app"
        "app"
      ];
    }
  );
  duplicateUnit = evaluate (
    base
    // {
      units = [
        "compose-fixture-update.timer"
        "compose-fixture-update.timer"
      ];
    }
  );
  collidingKinds = evaluate (
    base
    // {
      units = [ "app" ];
    }
  );
  invalidRuntimeName = evaluate (
    base
    // {
      containers = [ "not/a-container" ];
      httpProbes = { };
    }
  );
  undeclaredProbe = evaluate (
    base
    // {
      httpProbes.ghost = "http://127.0.0.1:8080/";
    }
  );
  remoteProbe = evaluate (
    base
    // {
      httpProbes.app = "https://service.example/";
    }
  );
in
{
  positive = {
    validHasNoFailures = failures valid == [ ];
    legacyEnumerateAllHasNoFailures = failures legacy == [ ];
    timerRefreshIsOneMinute =
      valid.config.systemd.timers.hostdash-status.timerConfig.OnUnitActiveSec == "60s";
    timerStartsAtBoot = valid.config.systemd.timers.hostdash-status.wantedBy == [ "timers.target" ];
    generatorTimeoutIsBounded =
      valid.config.systemd.services.hostdash-status.serviceConfig.TimeoutStartSec == "60s";
    sameOriginNginxConfigIsPublished =
      valid.config.environment.etc."hostdash-nginx.conf".source == ../modules/files/hostdash-nginx.conf;
  };

  negative = {
    duplicateContainerRejected =
      failures duplicateContainer == [
        "services.hostdash.status.containers must not contain duplicates"
      ];
    duplicateUnitRejected =
      failures duplicateUnit == [
        "services.hostdash.status.units must not contain duplicates"
      ];
    collidingKindsRejected =
      failures collidingKinds == [
        "services.hostdash.status container, unit, and extra keys must be distinct"
      ];
    invalidRuntimeNameRejected =
      failures invalidRuntimeName == [
        "services.hostdash.status runtime keys must match ^[A-Za-z0-9_.-]+$"
      ];
    undeclaredProbeRejected =
      failures undeclaredProbe == [
        "services.hostdash.status.httpProbes.ghost must reference a declared container, unit, or extra"
      ];
    remoteProbeRejected =
      failures remoteProbe == [
        "services.hostdash.status.httpProbes.app must use an http://127.0.0.1 or https://127.0.0.1 URL"
      ];
  };
}
