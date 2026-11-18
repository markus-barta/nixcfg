# OPS-617: pin the NoisyTCP (CVE-2026-99288) fix without moving the system package set.
# Temporary: drop the pin once the host passes fleet.kernelCveGuard without it.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  kpkgs = import inputs.nixpkgs-kernel {
    localSystem = pkgs.stdenv.hostPlatform;
    config = config.nixpkgs.config;
  };
in
{
  options.fleet.kernelPin.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Use the separately pinned kernel with the NoisyTCP fix.";
  };

  config = lib.mkIf config.fleet.kernelPin.enable {
    # This security pin deliberately overrides host kernel settings.
    boot.kernelPackages = lib.mkForce kpkgs.linuxPackages_6_18;
    # kpkgs.zfs is ZFS 2.4.4, matching the main pin's userland version.
    # Its kernelModuleAttribute selects linuxPackages_6_18.zfs_2_4 from
    # the same kpkgs; 2.4 supports this kernel without a ZFS downgrade.
    # mkForce overrides hokage's normal-priority ZFS package setting.
    boot.zfs.package = lib.mkForce kpkgs.zfs;

    assertions = [
      {
        # supportedFilesystems is normalized by NixOS to an attribute set of booleans.
        assertion =
          !(config.boot.supportedFilesystems.zfs or false) || pkgs.zfs.version == kpkgs.zfs.version;
        message = "OPS-617: the main pin's ZFS userland (sanoid/syncoid) differs from the pinned kernel module; bump nixpkgs-kernel or drop the pin";
      }
    ];
  };
}
