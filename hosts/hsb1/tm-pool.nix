# Time Machine ZFS pool — external 6TB USB drive, pure TM backup target.
#
# Pool + datasets created imperatively, once:
#
#   zpool create -o ashift=12 tm /dev/disk/by-id/<stable-id>
#   zfs set compression=zstd tm
#   zfs create tm/markus
#   zfs create tm/mailina
#   zfs set quota=2.5T tm/markus
#   zfs set quota=2.5T tm/mailina
#
# 2.5T + 2.5T = 5T against ~5.45TiB usable — the remaining ~450GB is
# deliberate pool-level headroom for sanoid's daily snapshots (below) plus
# ZFS slop space, not unallocated waste. NOTE: quota here is imperative,
# not disko-declared — if you ever change the numbers below, you must also
# run the matching `zfs set quota=...` by hand (same caveat as hsb0's ncps
# dataset in disk-config.zfs.nix).
{
  # Best-effort import at boot — an absent/unplugged USB drive must never hang
  # boot or `just switch`. (media's entry lives in ./media-pool.nix; the option
  # is a list, so the module system merges them.)
  boot.zfs.extraPools = [ "tm" ];

  fileSystems."/srv/tm/markus" = {
    device = "tm/markus";
    fsType = "zfs";
    options = [ "nofail" ];
  };

  fileSystems."/srv/tm/mailina" = {
    device = "tm/mailina";
    fsType = "zfs";
    options = [ "nofail" ];
  };

  # Corruption-rollback safety net for network TM sparsebundles/backups —
  # daily snapshots, 14-day retention, per the original TM hardening plan.
  services.sanoid = {
    enable = true;
    interval = "daily";

    templates.tm-daily = {
      daily = 14;
      monthly = 0;
      yearly = 0;
      autosnap = true;
      autoprune = true;
    };

    datasets = {
      "tm/markus" = {
        useTemplate = [ "tm-daily" ];
        recursive = false;
      };
      "tm/mailina" = {
        useTemplate = [ "tm-daily" ];
        recursive = false;
      };
    };
  };
}
