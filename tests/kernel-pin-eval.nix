# OPS-617: applied to the complete host config in CI, including upstream defaults.
{
  config,
  lib,
  host ? "csb0",
  ...
}:
let
  fixed = {
    "6.12" = "6.12.117";
    "6.18" = "6.18.63";
    "7.3" = "7.3.4";
  };
  v = config.boot.kernelPackages.kernel.version;
  mm = lib.versions.majorMinor v;
  zfsPkg = "${config.boot.zfs.package}/";
in
{
  pinEnabled = config.fleet.kernelPin.enable;
  kernelFixed = fixed ? ${mm} && lib.versionAtLeast v fixed.${mm};
  zfsVersionsMatch = config.boot.zfs.package.version == config.boot.zfs.modulePackage.version;
  initrdUsesPinnedZfs =
    !(config.boot.initrd.systemd.services ? "${host}-zpool-import-after-network")
    || lib.hasPrefix zfsPkg (
      config.boot.initrd.systemd.services."${host}-zpool-import-after-network".serviceConfig.ExecStart
    );
  initrdZpoolUsesPinnedZfs = lib.hasPrefix zfsPkg (
    config.boot.initrd.systemd.extraBin.zpool or zfsPkg
  );
}
