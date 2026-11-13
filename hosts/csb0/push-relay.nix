# OPS-528: composeStack is single-instance; keep relay upgrades out of project csb0.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  ciphertext = ../../secrets/csb0-push-relay-apns-key.age;
  enabled = builtins.pathExists ciphertext;
  # Public Apple identifiers (verified 2026-11-10); the assertion rejects malformed values.
  appleIdentifiers = {
    apnsKeyId = "8666MJ2TST";
    appAttestAppIdPrefix = "P66J39QV6V";
  };
  hasRegistryToken = config.age.secrets ? "csb1-inspr-site-ghcr-pull";
  authDirectory = "compose-paimos-push-relay-docker-auth";
  validIdentifier = value: builtins.match "[A-Z0-9]{10}" value != null;
  spec = import ./docker/push-relay-compose.nix {
    inherit (appleIdentifiers) apnsKeyId appAttestAppIdPrefix;
    apnsKeyPath = config.age.secrets.csb0-push-relay-apns-key.path;
  };
  composeFile = pkgs.writeText "docker-compose-paimos-push-relay.json" (builtins.toJSON spec);
  compose = "${pkgs.docker-compose}/bin/docker-compose -p paimos-push-relay -f ${composeFile}";
  locked =
    timeout:
    "${pkgs.util-linux}/bin/flock -w ${toString timeout} /run/lock/compose-paimos-push-relay.lock";
in
{
  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = hasRegistryToken;
        message = "OPS-528: the relay requires age.secrets.csb1-inspr-site-ghcr-pull from PR #1245 before deployment.";
      }
      {
        assertion = lib.all validIdentifier (lib.attrValues appleIdentifiers);
        message = "OPS-528: sealed APNs key requires verified APNS_KEY_ID and APP_ATTEST_APP_ID_PREFIX (10 uppercase alphanumeric characters each) in hosts/csb0/push-relay.nix.";
      }
    ];

    age.secrets.csb0-push-relay-apns-key = {
      file = ciphertext;
      path = "/run/agenix/csb0-push-relay-apns-key";
      owner = "65532";
      group = "65532";
      mode = "0400";
    };

    # JSON is accepted by Compose. text also permits evaluation of the public
    # spec without realizing a derivation or accessing the decrypted key.
    environment.etc."compose/paimos-push-relay/docker-compose.json".text = builtins.toJSON spec;

    systemd.services.compose-paimos-push-relay = {
      description = "Reconcile the independent INSPR push relay stack (OPS-528)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "docker.service"
        "network-online.target"
        "compose-csb0.service"
      ];
      requires = [ "docker.service" ];
      # Ordering only: no Requires/PartOf that could restart the main stack.
      wants = [ "network-online.target" ];
      restartTriggers = [
        composeFile
        ciphertext
      ];
      startLimitIntervalSec = 300;
      startLimitBurst = 3;
      # Docker credentials are client-side; this unit is the only csb0 consumer of the token #1245 declares.
      environment = lib.optionalAttrs hasRegistryToken {
        DOCKER_CONFIG = "/run/${authDirectory}";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "600";
        TimeoutStopSec = "60";
        Restart = "on-failure";
        RestartSec = "30s";
      }
      // lib.optionalAttrs hasRegistryToken {
        RuntimeDirectory = authDirectory;
        RuntimeDirectoryMode = "0700";
      };
      preStart =
        lib.optionalString hasRegistryToken ''
          umask 077
          test -r /run/agenix/csb1-inspr-site-ghcr-pull
          ${config.virtualisation.docker.package}/bin/docker login ghcr.io \
            --username markus-barta --password-stdin \
            < /run/agenix/csb1-inspr-site-ghcr-pull
        ''
        + ''
          test -r ${lib.escapeShellArg config.age.secrets.csb0-push-relay-apns-key.path}
          ${config.virtualisation.docker.package}/bin/docker network inspect relay-ingress > /dev/null
        '';
      postStart = lib.optionalString hasRegistryToken ''
        ${pkgs.coreutils}/bin/rm -f /run/${authDirectory}/config.json
      '';
      # No initialization here: a missing state file must fail closed.
      # Login above is per unit; no daemon-wide credential is created.
      script = ''
        ${locked 570} ${compose} up -d --remove-orphans
      '';
      preStop = ''
        ${locked 50} ${compose} down --timeout 20
      '';
    };
  };
}
