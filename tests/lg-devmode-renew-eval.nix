# OPS-309: evaluate the host's actual import locally; CI also supplies full config.
{
  config ? null,
}:
let
  pkgs = import <nixpkgs> { system = "x86_64-linux"; };
  inherit (pkgs) lib;
  host = import ../hosts/hsb0/configuration.nix {
    inherit pkgs lib;
    config = evaluated.config;
    inputs.inspr-modules.nixosModules.ssh-authorized = { };
  };
  renewalImports = builtins.filter (
    module: module == ../hosts/hsb0/lg-devmode-renew.nix
  ) host.imports;
  evaluated = lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = renewalImports ++ [
      {
        options = {
          age.secrets = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
          systemd.services = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
          systemd.timers = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
          nixcfg.ibGatewaySession.alert = lib.mkOption { type = lib.types.anything; };
          virtualisation.docker.package = lib.mkOption { type = lib.types.package; };
        };
        config = {
          age.secrets.hsb0-lg-devmode-token.path = "/run/agenix/hsb0-lg-devmode-token";
          virtualisation.docker.package = pkgs.docker;
          nixcfg.ibGatewaySession.alert = {
            destinationFile = "/run/agenix/hsb0-gateway-notify-config";
            notificationEnvFile = null;
          };
        };
      }
    ];
  };
  cfg = if config == null then evaluated.config else config;
  service = cfg.systemd.services.lg-devmode-renew;
  notifyTest = cfg.systemd.services.lg-devmode-notify-test;
  timer = cfg.systemd.timers.lg-devmode-renew;
  secret = cfg.age.secrets.hsb0-lg-devmode-token;
in
{
  hasService = service.serviceConfig.Type == "oneshot";
  explicitRenewal = builtins.match ".* --renew" service.serviceConfig.ExecStart != null;
  dailyTimer = timer.timerConfig.OnCalendar == "daily";
  jitter = timer.timerConfig.RandomizedDelaySec == "1h";
  persistent = timer.timerConfig.Persistent;
  enabledTimer = builtins.elem "timers.target" timer.wantedBy;
  rootSecret = secret.owner == "root" && secret.group == "root" && secret.mode == "0400";
  correctCiphertext = builtins.baseNameOf secret.file == "hsb0-lg-devmode-token.age";
  privateCredential = service.environment.LG_DEVMODE_TOKEN_FILE == secret.path;
  existingEmail =
    service.environment.LG_DEVMODE_DESTINATIONS_FILE == "/run/agenix/hsb0-gateway-notify-config";
  noCredentialStartFailure = (service.serviceConfig.LoadCredential or [ ]) == [ ];
  noSilentSkip = (service.unitConfig.ConditionPathExists or [ ]) == [ ];
  telegramDeferred = !(service.environment ? LG_DEVMODE_NOTIFICATION_ENV_FILE);
  durableState =
    service.serviceConfig.StateDirectory == "lg-devmode-renew"
    && service.serviceConfig.StateDirectoryMode == "0700";
  sufficientTimeout = service.serviceConfig.TimeoutStartSec == "30min";
  noTokenEnvironment = !(service.environment ? LG_DEVMODE_TOKEN);
  noCoreDumps = service.serviceConfig.LimitCORE == 0;
  noCapabilities = service.serviceConfig.CapabilityBoundingSet == "";
  privateDevices = service.serviceConfig.PrivateDevices;
  kernelProtected = service.serviceConfig.ProtectKernelLogs;
  namespacesRestricted = service.serviceConfig.RestrictNamespaces;
  clockProtected = service.serviceConfig.ProtectClock;
  hostProtected = service.serviceConfig.ProtectHostname;
  realtimeRestricted = service.serviceConfig.RestrictRealtime;
  procProtected = service.serviceConfig.ProtectProc == "invisible";
  addressFamilies =
    service.serviceConfig.RestrictAddressFamilies == [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
    ];
  nativeSyscalls = service.serviceConfig.SystemCallArchitectures == "native";
  filteredSyscalls = service.serviceConfig.SystemCallFilter == "@system-service";
  testNotifyCommand = builtins.match ".* --test-notify" notifyTest.serviceConfig.ExecStart != null;
  testNotifyTransport = notifyTest.environment == service.environment;
  testNotifySandbox =
    (builtins.removeAttrs notifyTest.serviceConfig [
      "ExecStart"
      "TimeoutStartSec"
    ]) == (builtins.removeAttrs service.serviceConfig [
      "ExecStart"
      "TimeoutStartSec"
      "StateDirectory"
      "StateDirectoryMode"
    ]);
  testNotifyNoState = !(notifyTest.serviceConfig ? StateDirectory);
  testNotifyManual = (notifyTest.wantedBy or [ ]) == [ ];
}
