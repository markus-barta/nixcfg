# OPS-158: evaluate real NixOS options and rendered units; never build a system.
{
  nixpkgs ? (builtins.getFlake (toString ../.)).inputs.nixpkgs.outPath,
  fullHost ? false,
}:
let
  system =
    if fullHost then
      # A plain path flake has no self.rev, even in a clean Git worktree.
      # Preserve the canonical Git revision required by NIX-348 provenance.
      (builtins.getFlake ("git+file://" + toString ../.)).nixosConfigurations.hsb1
    else
      import (nixpkgs + "/nixos/lib/eval-config.nix") {
        system = "x86_64-linux";
        modules = [
          ../hosts/hsb1/home-config.nix
          # Only the existing agenix lookup is stubbed for scoped evaluation;
          # every systemd option and rendered unit uses the real NixOS modules.
          (
            { lib, ... }:
            {
              options.age.secrets = lib.mkOption {
                type = lib.types.attrs;
                default.hsb1-tailnet-watch-env.path = "/run/agenix/hsb1-tailnet-watch-env";
              };
            }
          )
        ];
      };
  cfg = system.config;
  host = import ../hosts/hsb1/configuration.nix {
    pkgs = { };
    lib = { };
    config = { };
    inputs = { };
  };
  restic =
    if fullHost then
      cfg.nixcfg.composeStack.spec.services.restic-cron-hetzner
    else
      (import ../hosts/hsb1/docker/compose-spec.nix).services.restic-cron-hetzner;
in
assert builtins.elem ../hosts/hsb1/home-config.nix host.imports;
{
  service = {
    inherit (cfg.systemd.services.hsb1-home-config)
      serviceConfig
      after
      wants
      restartIfChanged
      ;
    mounts = cfg.systemd.services.hsb1-home-config.unitConfig.RequiresMountsFor;
  };
  inherit (cfg.systemd.paths.hsb1-home-config) pathConfig;
  inherit (cfg.systemd.timers.hsb1-home-config) timerConfig;
  maintenance = {
    inherit (cfg.systemd.services.hsb1-home-config-gc) serviceConfig restartIfChanged;
    inherit (cfg.systemd.timers.hsb1-home-config-gc) timerConfig;
  };
  witness = {
    inherit (cfg.systemd.services.home-config-watch) serviceConfig;
    inherit (cfg.systemd.timers.home-config-watch) timerConfig;
  };
  units = {
    service = cfg.systemd.units."hsb1-home-config.service".text;
    path = cfg.systemd.units."hsb1-home-config.path".text;
    timer = cfg.systemd.units."hsb1-home-config.timer".text;
    gc = cfg.systemd.units."hsb1-home-config-gc.service".text;
    gcTimer = cfg.systemd.units."hsb1-home-config-gc.timer".text;
    witness = cfg.systemd.units."home-config-watch.service".text;
    witnessTimer = cfg.systemd.units."home-config-watch.timer".text;
  };
  tmpfiles = cfg.systemd.tmpfiles.rules;
  readers = cfg.users.groups.home-config.members;
  readerConfig = cfg.environment.etc.gitconfig.text;
  sources = {
    script = toString cfg.environment.etc."hsb1-home-config/snapshot.py".source;
    scanner = toString cfg.environment.etc."hsb1-home-config/gitleaks.toml".source;
  };
  backup = {
    volumes = restic.volumes;
    script = builtins.readFile ../hosts/hsb1/docker/restic-cron/hetzner/run_backup.sh;
  };
  scannerVersion = system.pkgs.gitleaks.version;
}
