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
  # Public Apple identifiers. Fill both from verified Apple portal/app metadata
  # before sealing the key; empty values deliberately block activation.
  appleIdentifiers = {
    apnsKeyId = "8666MJ2TST";
    appAttestAppIdPrefix = "P66J39QV6V";
  };
  validIdentifier = value: builtins.match "[A-Z0-9]{10}" value != null;
  spec = import ./docker/push-relay-compose.nix {
    inherit (appleIdentifiers) apnsKeyId appAttestAppIdPrefix;
    apnsKeyPath = config.age.secrets.csb0-push-relay-apns-key.path;
  };
  composeFile = pkgs.writeText "docker-compose-paimos-push-relay.json" (builtins.toJSON spec);
  compose = "${pkgs.docker-compose}/bin/docker-compose -p paimos-push-relay -f ${composeFile}";
  locked = "${pkgs.util-linux}/bin/flock -w 570 /run/lock/compose-paimos-push-relay.lock";
in
{
  config = lib.mkIf enabled {
    assertions = [
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
      after = [ "docker.service" "network-online.target" "compose-csb0.service" ];
      requires = [ "docker.service" ];
      # Ordering only: no Requires/PartOf that could restart the main stack.
      wants = [ "network-online.target" ];
      restartTriggers = [ composeFile ciphertext ];
      startLimitIntervalSec = 300;
      startLimitBurst = 3;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "600";
        TimeoutStopSec = "60";
        Restart = "on-failure";
        RestartSec = "30s";
      };
      preStart = ''
        test -r ${lib.escapeShellArg config.age.secrets.csb0-push-relay-apns-key.path}
        ${config.virtualisation.docker.package}/bin/docker network inspect relay-ingress > /dev/null
      '';
      # No initialization here: a missing state file must fail closed. Pull
      # access is the separate GHCR change (#1245), never another token here.
      script = ''
        ${locked} ${compose} up -d --remove-orphans
      '';
      preStop = ''
        ${locked} ${compose} down --timeout 20
      '';
    };
  };
}
