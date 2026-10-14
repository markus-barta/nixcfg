# OPS-331: evaluate the real module with inert package paths; no builds or hosts.
{
  reconRetentionHours ? null,
}:
let
  lib = import <nixpkgs/lib>;
  evaluated = lib.evalModules {
    specialArgs.pkgs.runCommand =
      name: _: _:
      "/fixture/${name}";
    modules = [
      ../modules/paper-desk-executor/default.nix
      {
        options = {
          assertions = lib.mkOption { type = lib.types.listOf lib.types.attrs; };
          networking.firewall = {
            allowedTCPPorts = lib.mkOption {
              type = lib.types.listOf lib.types.port;
              default = [ ];
            };
            interfaces = lib.mkOption {
              type = lib.types.attrs;
              default = { };
            };
            extraCommands = lib.mkOption { type = lib.types.str; };
            extraStopCommands = lib.mkOption { type = lib.types.str; };
          };
          users = lib.mkOption { type = lib.types.attrs; };
          systemd = lib.mkOption { type = lib.types.attrs; };
          nixcfg.composeStack = {
            enable = lib.mkOption { type = lib.types.bool; };
            spec = lib.mkOption { type = lib.types.attrs; };
            autoUpdate.excludeFromPull = lib.mkOption { type = lib.types.listOf lib.types.str; };
            extraRestartTriggers = lib.mkOption { type = lib.types.listOf lib.types.str; };
          };
        };
        config = {
          nixcfg.paperDeskExecutor = {
            enable = true;
          }
          // lib.optionalAttrs (reconRetentionHours != null) { inherit reconRetentionHours; };
          nixcfg.composeStack = {
            enable = true;
            spec.services = {
              ib-gateway = {
                environment = [ "TRADING_MODE=paper" ];
                ports = [ "100.64.0.6:4002:4002" ];
              };
              joe-board-pusher.image = "hsb0-joe-board-pusher:flat-net-reconcile-perf-202610010310";
            };
          };
          networking.firewall.allowedTCPPorts = [ ];
        };
      }
    ];
  };
  cfg = evaluated.config;
  failed = builtins.filter (item: !item.assertion) cfg.assertions;
in
assert lib.assertMsg (failed == [ ]) (lib.concatMapStringsSep "; " (item: item.message) failed);
{
  inherit (cfg.nixcfg.paperDeskExecutor) reconRetentionHours;
  retentionEnvironment = builtins.filter (
    item: lib.hasPrefix "PAPER_DESK_RECON_RETENTION_HOURS=" item
  ) cfg.nixcfg.paperDeskExecutor.serviceSpec.environment;
}
