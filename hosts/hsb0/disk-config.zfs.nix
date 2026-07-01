{ lib, ... }:
{
  disko.devices = {
    disk.disk1 = {
      device = lib.mkDefault "/dev/sda";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          boot = {
            name = "boot";
            size = "1M";
            type = "EF02";
          };
          esp = {
            name = "ESP";
            size = "500M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          zfs = {
            size = "100%";
            content = {
              type = "zfs";
              pool = "zroot";
            };
          };
        };
      };
    };
    zpool = {
      zroot = {
        type = "zpool";
        rootFsOptions = {
          compression = "zstd";
          "com.sun:auto-snapshot" = "false";
        };
        postCreateHook = "zfs snapshot zroot@blank";

        datasets = {
          root = {
            type = "zfs_fs";
            mountpoint = "/";
            options = {
              mountpoint = "legacy";
            };
          };
          home = {
            type = "zfs_fs";
            mountpoint = "/home";
            options = {
              mountpoint = "legacy";
            };
          };
          nix = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options = {
              mountpoint = "legacy";
            };
          };
          docker = {
            type = "zfs_fs";
            mountpoint = "/var/lib/docker/volumes";
            options = {
              mountpoint = "legacy";
            };
          };
          ncps = {
            type = "zfs_fs";
            mountpoint = "/var/lib/ncps";
            options = {
              mountpoint = "legacy";
              # 64G quota vs ncps --cache-max-size=42G (docker-compose.yml) = 22G
              # burst headroom. The old 50G/42G (8G) margin deadlocked twice: ncps
              # only trims on its LRU cron, so a fleet-warmer burst between runs
              # filled the FS to 0B, at which point SQLite can't write and LRU can
              # NEVER run again (self-wedge). Keep quota >> cache-max-size, and if
              # you raise cache-max-size, raise this in lockstep. NIX (2026-07-01).
              # NOTE: disko applies at INSTALL only — a live `zfs set quota=64G
              # zroot/ncps` is required to change a running host.
              quota = "64G";
              "com.sun:auto-snapshot" = "false";
            };
            # RESILIENCE: Do not block boot if this mount fails.
            # This prevents the server from entering emergency mode for a non-critical cache.
            mountOptions = [ "nofail" ];
          };
        };
      };
    };
  };
}
