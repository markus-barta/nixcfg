# Time Machine ZFS pool — external 6TB USB drive, pure TM backup target.
#
# Pool + datasets created imperatively, once:
#
#   zpool create -o ashift=12 tm /dev/disk/by-id/<stable-id>
#   zfs set compression=zstd tm
#   zfs create tm/markus
#   zfs create tm/mailina
#   zfs set refquota=2.2T quota=3.2T tm/markus
#   zfs set refquota=1.4T quota=2T tm/mailina
#
# TWO caps per dataset (OPS-226, after "Das Backup-Volume ist voll" on
# 2026-09-22):
#   refquota — what Time Machine may *reference*. Mirrored EXACTLY by the
#              share's `fruit:time machine max size` in ./tm-samba.nix (in
#              GiB: 2200G / 1400G, a hair under), so TM thins its own old
#              backups before ZFS ever refuses a write. TM fills whatever it
#              is given by design, so referenced ≈ refquota is steady state.
#   quota    — hard cap INCLUDING snapshots. The gap (1T / 0.6T) is the
#              budget for sanoid's snapshots of a churning sparsebundle
#              (Sep 21 2026 rewrote ~560G in one day).
# The old single `quota=2.5T` counted snapshots while Samba advertised the
# same 2.5T to TM — TM believed 550G were free, ZFS had 0B, backup failed.
# 3.2T + 2T = 5.2T against ~5.45TiB usable; the rest is pool slop.
# tm-watch.nix pages when a refquota is missing, when snapshots eat half the
# gap, when headroom under quota drops below 100G, when the pool passes 85%,
# when smbd is down, and when a Mac's bundle goes stale.
# NOTE: both caps are imperative, not disko-declared — if you change the
# numbers here or in tm-samba.nix you must run the matching `zfs set` by
# hand (same caveat as hsb0's ncps dataset in disk-config.zfs.nix), and the
# `max size` must never exceed the refquota.
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

  # `zfs create` leaves datasets root:root 0755, which Samba honours — so Time
  # Machine authenticates fine and then fails with "allows neither writing,
  # reading nor appending" (observed 2026-07-13 on the first TM setup attempt).
  # Each user owns their own dataset; 0700 so neither can read the other's
  # backups, which are complete images of their Mac.
  #
  # tmpfiles rather than an activation script so it re-asserts on every boot
  # and every switch, including after the USB pool re-imports. `nofail` above
  # means the mountpoints may briefly be plain dirs on the root fs if the drive
  # is absent — z (not Z) so this only adjusts the dirs themselves, never
  # recurses into and rewrites the backup contents.
  systemd.tmpfiles.rules = [
    "z /srv/tm/markus 0700 markus users -"
    "z /srv/tm/mailina 0700 mailina mailina -"
  ];

  # Corruption-rollback safety net for network TM sparsebundles/backups —
  # daily snapshots, 7-day retention (was 14: a fortnight of a churning
  # sparsebundle held 574G on tm/markus and filled the quota, OPS-226; a week
  # is plenty to roll back a corrupted bundle). `hourly = 0` is explicit:
  # sanoid's default template otherwise adds an `_hourly` snapshot next to
  # every daily one, doubling the count for nothing.
  services.sanoid = {
    enable = true;
    interval = "daily";

    templates.tm-daily = {
      hourly = 0;
      daily = 7;
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
