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
  validatorSource = builtins.readFile ./validate-projection.sh;

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

  asList = value: if builtins.isList value then value else [ value ];
  directiveEntries =
    consumer: directive:
    asList (config.systemd.services.${consumer.unit}.serviceConfig.${directive} or [ ]);
  directCredentialEntries =
    consumer:
    lib.concatMap
      (
        directive:
        map (entry: {
          inherit directive entry;
        }) (directiveEntries consumer directive)
      )
      [
        "LoadCredential"
        "LoadCredentialEncrypted"
        "SetCredential"
        "SetCredentialEncrypted"
      ];
  entryCredentialName =
    directEntry:
    let
      explicit = builtins.match "([^:]+):.*" directEntry.entry;
      sourceOnlyLoad = lib.elem directEntry.directive [
        "LoadCredential"
        "LoadCredentialEncrypted"
      ];
    in
    if explicit != null then
      builtins.elemAt explicit 0
    else if sourceOnlyLoad then
      builtins.baseNameOf directEntry.entry
    else
      directEntry.entry;
  importProducesCredential =
    credential: entry:
    let
      renamed = builtins.match "([^:]+):(.*)" entry;
      source = if renamed == null then entry else builtins.elemAt renamed 0;
      rawTarget = if renamed == null then null else builtins.elemAt renamed 1;
      target = if rawTarget == "" then null else rawTarget;
      wildcard = lib.hasSuffix "*" source;
      sourcePrefix = lib.removeSuffix "*" source;
    in
    if target != null then
      if wildcard then lib.hasPrefix target credential else target == credential
    else if wildcard then
      lib.hasPrefix sourcePrefix credential
    else
      source == credential;
  credentialEntryHasNoExpansionSyntax = entry: !lib.hasInfix "%" entry && !lib.hasInfix "\\" entry;
  credentialEntriesHaveNoExpansionSyntax =
    consumer:
    lib.all (directEntry: credentialEntryHasNoExpansionSyntax directEntry.entry) (
      directCredentialEntries consumer
    )
    && lib.all credentialEntryHasNoExpansionSyntax (directiveEntries consumer "ImportCredential");
  matchingCredentialEntries =
    consumer:
    let
      credential = credentialName consumer.fleetSecret;
    in
    lib.filter (entry: entryCredentialName entry == credential) (directCredentialEntries consumer)
    ++ lib.filter (importProducesCredential credential) (directiveEntries consumer "ImportCredential");
  consumerHasExecStart =
    consumer:
    let
      execStart = config.systemd.services.${consumer.unit}.serviceConfig.ExecStart or null;
    in
    execStart != null && execStart != [ ] && execStart != "";

  projectionGate =
    fleetSecret:
    let
      path = projectedPath fleetSecret;
      consumers = consumersFor fleetSecret;
      units = map unitName consumers;
      check = pkgs.writeShellScript "janus-fleet-secret-${fleetSecret}-projection-check" validatorSource;
    in
    {
      description = "Require the reviewed Janus ${fleetSecret} projection";
      requiredBy = units;
      before = units;
      after = [ "local-fs.target" ];

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        UMask = "0077";
        ExecStart = "${check} ${pkgs.coreutils}/bin/stat 0 0 / ${lib.escapeShellArg path}";
        ReadOnlyPaths = [ "-${projectionRoot}" ];
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
      assertion = consumerHasExecStart consumer;
      message = "inspr.janusFleetSecrets consumer ${unitName consumer} must already declare ExecStart";
    }) validConsumers
    ++ map (consumer: {
      assertion = credentialEntriesHaveNoExpansionSyntax consumer;
      message = "inspr.janusFleetSecrets systemd credential entries in ${unitName consumer} must not contain specifiers or escapes";
    }) validConsumers
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
