# Disk configuration for hsb2 (Raspberry Pi Zero W)
# Uses ext4 on SD card (ZFS requires 2GB+ RAM, Pi Zero has 512MB)

{ lib, ... }:

{
  disko.devices = {
    disk.disk1 = {
      device = lib.mkDefault "/dev/mmcblk0";
      type = "disk";
      content = {
        type = "table";
        format = "msdos";
        partitions = [
          {
            name = "boot";
            size = "256M";
            bootable = true;
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          }
          {
            name = "root";
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          }
        ];
      };
    };
  };

  # Bootloader for Raspberry Pi
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  # SD card-specific optimizations
  boot.tmp.useTmpfs = true;
  boot.tmp.tmpfsSize = "100M";

  # Disable unnecessary services for SD card longevity
  services.journald.extraConfig = ''
    Storage=volatile
    SystemMaxUse=100M
    RuntimeMaxUse=50M
  '';

  # Periodic TRIM for SD card (if supported)
  services.fstrim.enable = true;
}
