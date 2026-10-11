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
  privateCredential = builtins.elem "token:${secret.path}" service.serviceConfig.LoadCredential;
  existingEmail = builtins.elem "destinations.json:/run/agenix/hsb0-gateway-notify-config" service.serviceConfig.LoadCredential;
  durableState =
    service.serviceConfig.StateDirectory == "lg-devmode-renew"
    && service.serviceConfig.StateDirectoryMode == "0700";
  sufficientTimeout = service.serviceConfig.TimeoutStartSec == "25min";
  noTokenEnvironment = !(service.environment ? LG_DEVMODE_TOKEN);
  noCoreDumps = service.serviceConfig.LimitCORE == 0;
}
