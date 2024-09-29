# Configuration for csb0 (legacy name: onlineserver01) Netcup server mba
{ modulesPath, config, pkgs, username, ... }:

{
  # Import necessary configuration modules
  imports = [
    ./hardware-configuration.nix
    ../../modules/mixins/server-remote.nix
    ../../modules/mixins/server-mba.nix
    ../../modules/mixins/zellij.nix
    ./disk-config.zfs.nix
  ];

  # Bootloader configuration
  boot.supportedFilesystems = [ "zfs" ];
  boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
  services.zfs.autoScrub.enable = true;

  boot.loader.grub = {
    enable = true;
    zfsSupport = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    mirroredBoots = [
      { devices = [ "nodev" ]; path = "/boot"; }
    ];
  };

  # Network settings for the initial RAM disk (initrd)
  boot.initrd.network = {
    enable = true;
    postCommands = ''
      sleep 2
      zpool import -a;
    '';
  };

  # Networking configuration
  networking = {
    hostId = "dabfdc01";  # Needed for ZFS
    hostName = "csb0";
    networkmanager.enable = true;

    # Firewall configuration
    firewall = {
      # allowedTCPPorts = [ 25 ]; # Uncomment to allow SMTP
    };
  };

  # Mosquitto configuration mba <
  users.groups.mosquitto = {
    gid = 1883;
  };

  users.users.${username}.extraGroups = [ "mosquitto" ];

  system.activationScripts.mosquittoPermissions = ''
    chown -R ${username}:mosquitto /home/${username}/docker/mosquitto
    chmod -R 775 /home/${username}/docker/mosquitto
  '';
  # > mba

  # Environment system packages
  environment.systemPackages = with pkgs; [
    # Add system packages here
  ];
}
