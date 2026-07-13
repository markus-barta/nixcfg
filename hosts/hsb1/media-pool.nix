# Media ZFS pool — external 4TB USB drive, Plex library source.
#
# Pool is created imperatively, once, outside of disko (this is a data-only
# pool on removable/external USB media, not the boot disk):
#
#   zpool create -o ashift=12 media /dev/disk/by-id/<stable-id>
#   zfs set compression=lz4 media
#
# lz4 (not zstd like zroot) — media content is already-compressed video;
# lz4's early-abort on incompressible blocks is cheaper than zstd's for the
# same no-op outcome.
#
# extraPools makes import best-effort at boot: a sleeping/absent/unplugged
# USB drive must never hang boot or `just switch`.
#
# Each pool module owns its own extraPools entry (tm's lives in ./tm-pool.nix);
# the option is a list, so the module system merges them.
{
  boot.zfs.extraPools = [ "media" ];

  fileSystems."/srv/media" = {
    device = "media";
    fsType = "zfs";
    options = [ "nofail" ];
  };

  # Pool root is mba:users (rsync target); markus needs group write to
  # add/remove files over the SMB share (see ./media-samba.nix) — both are in
  # group `users`. Only the pool root is asserted here: `z` (not `Z`) so this
  # never recurses over ~2TB of media on every switch. Nested dirs/files were
  # normalised once by hand (dirs 0775, files 0664); content arriving later via
  # rsync inherits the source's modes, so if a fresh import ever lands
  # group-unwritable dirs again, re-run:
  #   sudo find /srv/media -type d -exec chmod 775 {} +
  #   sudo find /srv/media -type f -exec chmod 664 {} +
  systemd.tmpfiles.rules = [
    "z /srv/media 0775 mba users -"
  ];
}
