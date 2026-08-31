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
  unsafeCredentialSyntaxMessage = "inspr.janusFleetSecrets systemd credential entries in fixture-consumer.service must be canonical printable ASCII without outer whitespace, specifiers, or escapes";

  hsb1 = evaluate { hostName = "hsb1"; };
  hsb8 = evaluate { hostName = "hsb8"; };
  hsb1Consumer = hsb1.config.systemd.services.fixture-consumer;
  hsb1ConsumerUnitLines =
    lib.splitString "\n"
      hsb1.config.systemd.units."fixture-consumer.service".text;
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
  encryptedImplicitCollision = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.LoadCredentialEncrypted = [
      "janus-shared-alert-url"
    ];
  };
  implicitCollision = evaluate {
    hostName = "hsb1";
    extraModule = {
      systemd.services.fixture-consumer.serviceConfig.LoadCredential = [
        "janus-shared-alert-url"
      ];
    };
  };
  setCollision = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.SetCredential = [
      "janus-shared-alert-url:public-fallback"
    ];
  };
  setEncryptedCollision = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.SetCredentialEncrypted = [
      "janus-shared-alert-url:encrypted-fallback"
    ];
  };
  setImplicitCollision = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.SetCredential = [
      "janus-shared-alert-url"
    ];
  };
  setEncryptedImplicitCollision = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.SetCredentialEncrypted = [
      "janus-shared-alert-url"
    ];
  };
  loadSpecifier = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.LoadCredential = [
      "janus-%H:/run/unreviewed/plain"
    ];
  };
  loadEncryptedSpecifier = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.LoadCredentialEncrypted = [
      "janus-%H:/run/unreviewed/encrypted"
    ];
  };
  setSpecifier = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.SetCredential = [
      "janus-%H:public-fallback"
    ];
  };
  setEncryptedSpecifier = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.SetCredentialEncrypted = [
      "janus-%H:encrypted-fallback"
    ];
  };
  importSpecifier = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.ImportCredential = [ "janus-%H" ];
  };
  loadEscapedId = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.LoadCredential = [
      "janus\\-shared-alert-url:/run/unreviewed/plain"
    ];
  };
  loadEncryptedEscapedId = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.LoadCredentialEncrypted = [
      "janus\\-shared-alert-url:/run/unreviewed/encrypted"
    ];
  };
  setEscapedId = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.SetCredential = [
      "janus\\-shared-alert-url:public-fallback"
    ];
  };
  setEncryptedEscapedId = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.SetCredentialEncrypted = [
      "janus\\-shared-alert-url:encrypted-fallback"
    ];
  };
  importEscapedId = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.ImportCredential = [
      "janus\\-shared-alert-url"
    ];
  };
  importEscapedWildcard = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.ImportCredential = [ "janus\\-*" ];
  };
  loadLeadingWhitespace = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.LoadCredential = lib.mkAfter [
      " janus-shared-alert-url:/run/unreviewed/plain"
    ];
  };
  loadEncryptedTrailingWhitespace = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.LoadCredentialEncrypted = lib.mkAfter [
      "janus-shared-alert-url:/run/unreviewed/encrypted "
    ];
  };
  setLineFeedInjection = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.SetCredential = lib.mkAfter [
      "public-id:public-value\nLoadCredential=janus-shared-alert-url:/run/unreviewed/injected"
    ];
  };
  setEncryptedLeadingWhitespace = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.SetCredentialEncrypted = lib.mkAfter [
      " encrypted-id:encrypted-fallback"
    ];
  };
  importLineFeedInjection = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.ImportCredential = lib.mkAfter [
      "public-id\njanus-shared-alert-url"
    ];
  };
  emptyLoadReset = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.LoadCredential = lib.mkAfter [ "" ];
  };
  emptyLoadEncryptedReset = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.LoadCredentialEncrypted = lib.mkAfter [
      ""
    ];
  };
  importExactCollision = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.ImportCredential = [
      "janus-shared-alert-url"
    ];
  };
  importWildcardCollision = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.ImportCredential = [ "janus-*" ];
  };
  importExactRenameCollision = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.ImportCredential = [
      "legacy-name:janus-shared-alert-url"
    ];
  };
  importWildcardRenameCollision = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.ImportCredential = [
      "legacy.*:janus-"
    ];
  };
  importEmptyRenameCollision = evaluate {
    hostName = "hsb1";
    extraModule.systemd.services.fixture-consumer.serviceConfig.ImportCredential = [
      "janus-shared-alert-url:"
    ];
  };
  missingConsumer = evaluate {
    hostName = "hsb1";
    consumers.mistyped-consumer = "shared-alert-url";
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
assert builtins.length hsb1Consumer.serviceConfig.LoadCredential == 1;
assert lib.count (line: lib.hasPrefix "LoadCredential=" line) hsb1ConsumerUnitLines == 1;
assert lib.count (line: lib.hasPrefix "SetCredential=" line) hsb1ConsumerUnitLines == 0;
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
    "-/run/janus-projections/managed-service-environment"
  ];
assert hsb1Gate.serviceConfig.ExecStart != null;
assert !(hsb1Gate.serviceConfig.RemainAfterExit or false);
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
  (assertionMessages encryptedImplicitCollision);
assert builtins.elem "inspr.janusFleetSecrets credential name collides in fixture-consumer.service"
  (assertionMessages implicitCollision);
assert builtins.elem "inspr.janusFleetSecrets credential name collides in fixture-consumer.service"
  (assertionMessages setCollision);
assert builtins.elem "inspr.janusFleetSecrets credential name collides in fixture-consumer.service"
  (assertionMessages setEncryptedCollision);
assert builtins.elem "inspr.janusFleetSecrets credential name collides in fixture-consumer.service"
  (assertionMessages setImplicitCollision);
assert builtins.elem "inspr.janusFleetSecrets credential name collides in fixture-consumer.service"
  (assertionMessages setEncryptedImplicitCollision);
assert builtins.elem unsafeCredentialSyntaxMessage (assertionMessages loadSpecifier);
assert builtins.elem unsafeCredentialSyntaxMessage (assertionMessages loadEncryptedSpecifier);
assert builtins.elem unsafeCredentialSyntaxMessage (assertionMessages setSpecifier);
assert builtins.elem unsafeCredentialSyntaxMessage (assertionMessages setEncryptedSpecifier);
assert builtins.elem unsafeCredentialSyntaxMessage (assertionMessages importSpecifier);
assert builtins.elem unsafeCredentialSyntaxMessage (assertionMessages loadEscapedId);
assert builtins.elem unsafeCredentialSyntaxMessage (assertionMessages loadEncryptedEscapedId);
assert builtins.elem unsafeCredentialSyntaxMessage (assertionMessages setEscapedId);
assert builtins.elem unsafeCredentialSyntaxMessage (assertionMessages setEncryptedEscapedId);
assert builtins.elem unsafeCredentialSyntaxMessage (assertionMessages importEscapedId);
assert builtins.elem unsafeCredentialSyntaxMessage (assertionMessages importEscapedWildcard);
assert builtins.elem unsafeCredentialSyntaxMessage (assertionMessages loadLeadingWhitespace);
assert builtins.elem unsafeCredentialSyntaxMessage (
  assertionMessages loadEncryptedTrailingWhitespace
);
assert builtins.elem unsafeCredentialSyntaxMessage (assertionMessages setLineFeedInjection);
assert builtins.elem unsafeCredentialSyntaxMessage (
  assertionMessages setEncryptedLeadingWhitespace
);
assert builtins.elem unsafeCredentialSyntaxMessage (assertionMessages importLineFeedInjection);
assert builtins.elem unsafeCredentialSyntaxMessage (assertionMessages emptyLoadReset);
assert builtins.elem unsafeCredentialSyntaxMessage (assertionMessages emptyLoadEncryptedReset);
assert builtins.elem "inspr.janusFleetSecrets credential name collides in fixture-consumer.service"
  (assertionMessages importExactCollision);
assert builtins.elem "inspr.janusFleetSecrets credential name collides in fixture-consumer.service"
  (assertionMessages importWildcardCollision);
assert builtins.elem "inspr.janusFleetSecrets credential name collides in fixture-consumer.service"
  (assertionMessages importExactRenameCollision);
assert builtins.elem "inspr.janusFleetSecrets credential name collides in fixture-consumer.service"
  (assertionMessages importWildcardRenameCollision);
assert builtins.elem "inspr.janusFleetSecrets credential name collides in fixture-consumer.service"
  (assertionMessages importEmptyRenameCollision);
assert builtins.elem
  "inspr.janusFleetSecrets consumer mistyped-consumer.service must already declare ExecStart"
  (assertionMessages missingConsumer);
assert builtins.elem
  "inspr.janusFleetSecrets currently supports one reviewed managed-service-environment profile per host"
  (assertionMessages multipleProfiles);
assert builtins.elem
  "inspr.janusFleetSecrets consumer unit collides with a generated projection gate"
  (assertionMessages gateCollision);
"janus_fleet_secret_module_eval=ok"
