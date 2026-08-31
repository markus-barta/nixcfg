let
  flakeRef = builtins.getEnv "JANUS_FLEET_SECRET_PINNED_FLAKE_REF";
  validFlakeRef =
    builtins.match "git\\+file://[^?]+\\?rev=[0-9a-f]{40}&shallow=1" flakeRef != null
    || builtins.match "path:/[^?#]+" flakeRef != null;
  flake =
    assert validFlakeRef;
    builtins.getFlake flakeRef;
  system = "x86_64-linux";
  lib = flake.inputs.nixpkgs.lib;

  declaration.fixture-consumer = "shared-alert-url";

  evaluate =
    {
      hostName,
      consumers ? declaration,
      extraModule ? { },
    }:
    flake.inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        ../modules/janus-fleet-secrets/default.nix
        ./fixtures/janus-fleet-secret-host.nix
        {
          networking.hostName = hostName;
          inspr.janusFleetSecrets.consumers = lib.mkForce consumers;
        }
        extraModule
      ];
    };

  failedAssertions = evaluated: builtins.filter (item: !item.assertion) evaluated.config.assertions;
  assertionMessages = evaluated: map (item: item.message) (failedAssertions evaluated);

  hsb1 = evaluate { hostName = "hsb1"; };
  hsb8 = evaluate { hostName = "hsb8"; };
  hsb1Consumer = hsb1.config.systemd.services.fixture-consumer;
  hsb1Gate = hsb1.config.systemd.services.janus-fleet-secret-shared-alert-url-projection;
  hsb8Consumer = hsb8.config.systemd.services.fixture-consumer;
  hsb8Gate = hsb8.config.systemd.services.janus-fleet-secret-shared-alert-url-projection;

  invalidName = evaluate {
    hostName = "hsb1";
    consumers.fixture-consumer = "../escape";
  };
  invalidHost = evaluate { hostName = "HSB1"; };
  invalidUnit = evaluate {
    hostName = "hsb1";
    consumers."../fixture-consumer" = "shared-alert-url";
  };
  overlongName = evaluate {
    hostName = "hsb1";
    consumers.fixture-consumer = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  };
  collision = evaluate {
    hostName = "hsb1";
    extraModule = {
      systemd.services.fixture-consumer.serviceConfig.LoadCredential = [
        "janus-shared-alert-url:/run/unreviewed/path"
      ];
    };
  };
  encryptedCollision = evaluate {
    hostName = "hsb1";
    extraModule = {
      systemd.services.fixture-consumer.serviceConfig.LoadCredentialEncrypted = [
        "janus-shared-alert-url:/run/unreviewed/encrypted"
      ];
    };
  };
  implicitCollision = evaluate {
    hostName = "hsb1";
    extraModule = {
      systemd.services.fixture-consumer.serviceConfig.LoadCredential = [
        "/run/unreviewed/janus-shared-alert-url"
      ];
    };
  };
  multipleProfiles = evaluate {
    hostName = "hsb1";
    consumers = declaration // {
      second-consumer = "other-secret";
    };
    extraModule.systemd.services.second-consumer.serviceConfig = {
      Type = "oneshot";
      ExecStart = "/bin/true";
    };
  };
  gateCollision = evaluate {
    hostName = "hsb1";
    consumers.janus-fleet-secret-shared-alert-url-projection = "shared-alert-url";
    extraModule.systemd.services.janus-fleet-secret-shared-alert-url-projection.serviceConfig = {
      Type = "oneshot";
      ExecStart = "/bin/true";
    };
  };
in
assert failedAssertions hsb1 == [ ];
assert failedAssertions hsb8 == [ ];
assert builtins.attrNames hsb1.options.inspr.janusFleetSecrets == [ "consumers" ];
assert
  hsb1Consumer.serviceConfig.LoadCredential == [
    "janus-shared-alert-url:/run/janus-projections/managed-service-environment/hsb1/shared-alert-url.env"
  ];
assert
  hsb8Consumer.serviceConfig.LoadCredential == [
    "janus-shared-alert-url:/run/janus-projections/managed-service-environment/hsb8/shared-alert-url.env"
  ];
assert hsb1Consumer.requires == [ "janus-fleet-secret-shared-alert-url-projection.service" ];
assert hsb1Consumer.after == [ "janus-fleet-secret-shared-alert-url-projection.service" ];
assert hsb1Gate.requiredBy == [ "fixture-consumer.service" ];
assert hsb1Gate.before == [ "fixture-consumer.service" ];
assert
  hsb1Gate.serviceConfig.ReadOnlyPaths == [
    "/run/janus-projections/managed-service-environment/hsb1/shared-alert-url.env"
  ];
assert hsb1Gate.serviceConfig.ExecStart != null;
assert hsb1Gate.serviceConfig.PrivateNetwork;
assert hsb1Gate.serviceConfig.RestrictAddressFamilies == [ "AF_UNIX" ];
assert hsb8Gate.requiredBy == [ "fixture-consumer.service" ];
assert builtins.elem
  "inspr.janusFleetSecrets consumer units and fleet-secret names must be bounded lowercase safe names"
  (assertionMessages invalidName);
assert builtins.elem "inspr.janusFleetSecrets requires a bounded canonical networking.hostName" (
  assertionMessages invalidHost
);
assert builtins.elem
  "inspr.janusFleetSecrets consumer units and fleet-secret names must be bounded lowercase safe names"
  (assertionMessages invalidUnit);
assert builtins.elem
  "inspr.janusFleetSecrets consumer units and fleet-secret names must be bounded lowercase safe names"
  (assertionMessages overlongName);
assert builtins.elem "inspr.janusFleetSecrets credential name collides in fixture-consumer.service"
  (assertionMessages collision);
assert builtins.elem "inspr.janusFleetSecrets credential name collides in fixture-consumer.service"
  (assertionMessages encryptedCollision);
assert builtins.elem "inspr.janusFleetSecrets credential name collides in fixture-consumer.service"
  (assertionMessages implicitCollision);
assert builtins.elem
  "inspr.janusFleetSecrets currently supports one reviewed managed-service-environment profile per host"
  (assertionMessages multipleProfiles);
assert builtins.elem
  "inspr.janusFleetSecrets consumer unit collides with a generated projection gate"
  (assertionMessages gateCollision);
"janus_fleet_secret_module_eval=ok"
