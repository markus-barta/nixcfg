# onlineserver01 Netcup server mba
{ modulesPath, config, pkgs, ... }:

{
  imports =
    [
      ./hardware-configuration.nix
      ../../modules/mixins/server-remote.nix
      ./disk-config.zfs.nix
    ];

  # Bootloader.
  boot.supportedFilesystems = [ "zfs" ];
  boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
  services.zfs.autoScrub.enable = true;

  boot.loader.grub = {
    enable = true;
    zfsSupport = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    mirroredBoots = [
      { devices = [ "nodev"]; path = "/boot"; }
    ];
  };

  boot.initrd.network = {
    enable = true;
    postCommands = ''
      sleep 2
      zpool import -a;
    '';
  };

  networking = {
    hostId = "dabfdc01";  # needed for ZFS
    hostName = "onlineserver01";
    networkmanager.enable = true;

    # ssh is already enabled by the server-common mixin
    firewall = {
      # allowedTCPPorts = [ 25 ]; # SMTP
    };
  };

  environment.systemPackages = with pkgs; [
  ];
}
