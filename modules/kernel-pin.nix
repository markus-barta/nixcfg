# OPS-617: pin the NoisyTCP (CVE-2026-99288) fix without moving the system package set.
# Temporary: drop when the main nixpkgs pin carries >= 6.18.63.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  kpkgs = import inputs.nixpkgs-kernel {
    system = pkgs.stdenv.hostPlatform.system;
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
    boot.kernelPackages = lib.mkForce kpkgs.linuxPackages_6_18;
    # kpkgs.zfs is ZFS 2.4.4, matching the main pin's userland version.
    # Its kernelModuleAttribute selects linuxPackages_6_18.zfs_2_4 from
    # the same kpkgs; 2.4 supports this kernel without a ZFS downgrade.
    # supportedFilesystems is normalized by NixOS to an attribute set of booleans.
    boot.zfs.package = lib.mkIf (
      builtins.elem "zfs" (
        lib.attrNames (lib.filterAttrs (_: enabled: enabled) config.boot.supportedFilesystems)
      )
    ) (lib.mkForce kpkgs.zfs);

    assertions = [
      {
        assertion = lib.versionAtLeast config.boot.kernelPackages.kernel.version "6.18.63";
        message = "OPS-617: fleet.kernelPin requires kernel >= 6.18.63 for the NoisyTCP fix.";
      }
    ];
  };
}
