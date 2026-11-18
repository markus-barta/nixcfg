# OPS-617: evaluate real hosts without building a NixOS system.
# nix eval --offline --impure --json --expr 'import ./tests/kernel-pin-eval.nix { }'
{
  root ? ../.,
  flake ? builtins.getFlake (toString root),
  mainFlake ? builtins.getFlake "git+file://${toString root}?ref=origin/main",
}:
let
  inherit (flake.inputs.nixpkgs) lib;
  csb0 = flake.nixosConfigurations.csb0.config;
  hsb0 = flake.nixosConfigurations.hsb0.config;
  mainHsb0 = mainFlake.nixosConfigurations.hsb0.config;
  kpkgs = import flake.inputs.nixpkgs-kernel {
    system = csb0.nixpkgs.hostPlatform.system;
    config = csb0.nixpkgs.config;
  };
  kernelZfs = csb0.boot.kernelPackages.${csb0.boot.zfs.package.kernelModuleAttribute};
  checks = {
    csb0Kernel = csb0.boot.kernelPackages.kernel.version == "6.18.63";
    csb0ZfsUserland = csb0.boot.zfs.package.version == kpkgs.zfs.version;
    csb0ZfsModule = kernelZfs.version == kpkgs.linuxPackages_6_18.zfs_2_4.version;
    csb0ZfsVersionsMatch = csb0.boot.zfs.package.version == kernelZfs.version;
    csb0PinEnabled = csb0.fleet.kernelPin.enable;
    csb0ZfsModuleCompatible = !kernelZfs.meta.broken;
    csb0ZfsUserlandUnchanged =
      csb0.boot.zfs.package.version == mainFlake.nixosConfigurations.csb0.config.boot.zfs.package.version;
    csb0InitrdUsesPinnedZfs =
      csb0.boot.initrd.systemd.services.csb0-zpool-import-after-network.serviceConfig.ExecStart
      == "${csb0.boot.zfs.package}/bin/zpool import -a";
    hsb0KernelUnchanged =
      hsb0.boot.kernelPackages.kernel.version == mainHsb0.boot.kernelPackages.kernel.version;
    mainKernelBaseline = mainHsb0.boot.kernelPackages.kernel.version == "7.2.13";
  };
in
assert lib.all (value: value) (builtins.attrValues checks);
{
  inherit checks;
  csb0KernelVersion = csb0.boot.kernelPackages.kernel.version;
  csb0ZfsVersion = csb0.boot.zfs.package.version;
  hsb0KernelVersion = hsb0.boot.kernelPackages.kernel.version;
  mainHsb0KernelVersion = mainHsb0.boot.kernelPackages.kernel.version;
}
