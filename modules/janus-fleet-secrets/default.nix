{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.inspr.janusFleetSecrets;
  hostName = config.networking.hostName;
  safeNamePattern = "[a-z][a-z0-9-]{0,47}";
  safeUnitPattern = "[a-z][a-z0-9-]{0,62}";
  validName = pattern: value: builtins.match pattern value != null;
  projectionRoot = "/run/janus-projections/managed-service-environment";

  projectedPath = fleetSecret: "${projectionRoot}/${hostName}/${fleetSecret}.env";
  credentialName = fleetSecret: "janus-${fleetSecret}";
  gateName = fleetSecret: "janus-fleet-secret-${fleetSecret}-projection";
  unitName = consumer: "${consumer.unit}.service";

  consumerEntries = lib.mapAttrsToList (unit: fleetSecret: {
    inherit unit fleetSecret;
  }) cfg.consumers;
  validConsumer =
    consumer: validName safeUnitPattern consumer.unit && validName safeNamePattern consumer.fleetSecret;
  validConsumers = lib.filter validConsumer consumerEntries;
  fleetSecrets = lib.unique (map (consumer: consumer.fleetSecret) validConsumers);
  gateNames = map gateName fleetSecrets;
  consumersFor =
    fleetSecret: lib.filter (consumer: consumer.fleetSecret == fleetSecret) validConsumers;

  loadCredentialEntries =
    consumer:
    (config.systemd.services.${consumer.unit}.serviceConfig.LoadCredential or [ ])
    ++ (config.systemd.services.${consumer.unit}.serviceConfig.LoadCredentialEncrypted or [ ]);
  entryCredentialName =
    entry:
    let
      explicit = builtins.match "([^:]+):.*" entry;
    in
    if explicit == null then builtins.baseNameOf entry else builtins.elemAt explicit 0;
  matchingCredentialEntries =
    consumer:
    lib.filter (entry: entryCredentialName entry == credentialName consumer.fleetSecret) (
      loadCredentialEntries consumer
    );

  projectionGate =
    fleetSecret:
    let
      path = projectedPath fleetSecret;
      consumers = consumersFor fleetSecret;
      units = map unitName consumers;
      check = pkgs.writeShellScript "janus-fleet-secret-${fleetSecret}-projection-check" ''
        set -eu

        projected_file=${lib.escapeShellArg path}
        if ! test -f "$projected_file"; then
          echo 'reason_code=projection_missing value_returned=false' >&2
          exit 1
        fi
        if test -L "$projected_file"; then
          echo 'reason_code=projection_not_regular value_returned=false' >&2
          exit 1
        fi
        if test "$(${pkgs.coreutils}/bin/stat -c '%a' "$projected_file")" != 600; then
          echo 'reason_code=projection_not_private value_returned=false' >&2
          exit 1
        fi
      '';
    in
    {
      description = "Require the reviewed Janus ${fleetSecret} projection";
      requiredBy = units;
      before = units;
      after = [ "local-fs.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
        Group = "root";
        UMask = "0077";
        ExecStart = check;
        ReadOnlyPaths = [ path ];
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        PrivateNetwork = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
      };
    };
in
{
  options.inspr.janusFleetSecrets.consumers = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    description = ''
      Value-free bindings from reviewed Janus fleet-secret names to exact
      systemd consumers. Janus owns projection; this module only validates the
      derived private file and passes it with LoadCredential=.
    '';
  };

  config = lib.mkIf (cfg.consumers != { }) {
    assertions = [
      {
        assertion = validName safeNamePattern hostName;
        message = "inspr.janusFleetSecrets requires a bounded canonical networking.hostName";
      }
      {
        assertion =
          lib.length consumerEntries <= 64 && lib.all (consumer: validConsumer consumer) consumerEntries;
        message = "inspr.janusFleetSecrets consumer units and fleet-secret names must be bounded lowercase safe names";
      }
      {
        assertion = lib.length fleetSecrets == 1;
        message = "inspr.janusFleetSecrets currently supports one reviewed managed-service-environment profile per host";
      }
      {
        assertion = lib.all (consumer: !(lib.elem consumer.unit gateNames)) validConsumers;
        message = "inspr.janusFleetSecrets consumer unit collides with a generated projection gate";
      }
    ]
    ++ map (consumer: {
      assertion = lib.length (matchingCredentialEntries consumer) == 1;
      message = "inspr.janusFleetSecrets credential name collides in ${unitName consumer}";
    }) validConsumers;

    systemd.services =
      lib.listToAttrs (
        map (fleetSecret: {
          name = gateName fleetSecret;
          value = projectionGate fleetSecret;
        }) fleetSecrets
      )
      // lib.listToAttrs (
        map (consumer: {
          name = consumer.unit;
          value = {
            requires = lib.mkAfter [ "${gateName consumer.fleetSecret}.service" ];
            after = lib.mkAfter [ "${gateName consumer.fleetSecret}.service" ];
            serviceConfig.LoadCredential = lib.mkAfter [
              "${credentialName consumer.fleetSecret}:${projectedPath consumer.fleetSecret}"
            ];
          };
        }) validConsumers
      );
  };
}
