# OPS-617: applied to the complete csb0 config in CI, including upstream defaults.
{ config, lib, ... }:
let
  fixed = {
    "6.12" = "6.12.117";
    "6.18" = "6.18.63";
    "7.3" = "7.3.4";
  };
  v = config.boot.kernelPackages.kernel.version;
  mm = lib.versions.majorMinor v;
  zpool = "${config.boot.zfs.package}/bin/zpool";
in
{
  csb0PinEnabled = config.fleet.kernelPin.enable;
  csb0KernelFixed = fixed ? ${mm} && lib.versionAtLeast v fixed.${mm};
  csb0ZfsVersionsMatch = config.boot.zfs.package.version == config.boot.zfs.modulePackage.version;
  csb0InitrdUsesPinnedZfs = lib.hasPrefix zpool (
    config.boot.initrd.systemd.services.csb0-zpool-import-after-network.serviceConfig.ExecStart
  );
  csb0InitrdZpoolUsesPinnedZfs = lib.hasPrefix zpool (
    config.boot.initrd.systemd.extraBin.zpool or zpool
  );
}
