# Time Machine ZFS pool — external 6TB USB drive, pure TM backup target.
#
# Pool + datasets created imperatively, once:
#
#   zpool create -o ashift=12 tm /dev/disk/by-id/<stable-id>
#   zfs set compression=zstd tm
#   zfs create tm/markus
#   zfs create tm/mailina
#   zfs set refquota=2253G quota=3277G tm/markus     # numbers: ./tm-caps.nix
#   zfs set refquota=1434G quota=2048G tm/mailina
#
# TWO caps per dataset (OPS-226, after "Das Backup-Volume ist voll" on
# 2026-09-22) — refquota is Time Machine's own cap (Samba advertises a bit
# less, so TM thins itself first), quota is the hard cap incl. sanoid
# snapshots. The old single `quota=2.5T` counted snapshots while Samba
# advertised the same 2.5T to TM: TM believed 550G were free, ZFS had 0B.
# TM deleting old backups does NOT free blocks a snapshot still holds, so the
# snapshot budget (quota − refquota) is defended by tm-watch.nix, which
# prunes the oldest autosnap_* snapshots when headroom under quota drops
# below 100G, and pages on cap drift, snapshot pressure, pool pressure,
# smbd down and stale backups. All numbers live in ./tm-caps.nix; both ZFS
# caps are imperative, not disko-declared — changing a number there means
# running the matching `zfs set` by hand (same caveat as hsb0's ncps dataset
# in disk-config.zfs.nix). The eval-time assertion below keeps Samba's cap
# under the refquota so the two can never drift the wrong way.
{ lib, ... }:
let
  caps = import ./tm-caps.nix;
in
{
  assertions = lib.mapAttrsToList (user: cap: {
    assertion = cap.maxSizeG + 32 <= cap.refquotaG && cap.refquotaG < cap.quotaG;
    message = "tm-caps.nix ${user}: need maxSizeG + 32G <= refquotaG < quotaG (got ${toString cap.maxSizeG}/${toString cap.refquotaG}/${toString cap.quotaG})";
  }) caps;

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
