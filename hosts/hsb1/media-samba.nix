# Ad hoc SMB share for the `media` ZFS pool (/srv/media) — Finder access so
# Markus can browse/add/remove files directly, independent of Plex.
#
# Kept separate from tm-samba.nix (Time Machine shares, still staged behind
# NIX-295 step 6/7 pending the 6TB pool) so this can go live now without
# depending on it. Global settings use lib.mkDefault so this composes
# cleanly once tm-samba.nix is enabled later — no duplicate/conflicting
# `global` values between the two files.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  services.samba = {
    enable = true;
    openFirewall = false; # firewall is globally disabled repo-wide; port 445 already in configuration.nix's port list

    settings = {
      global = {
        workgroup = lib.mkDefault "WORKGROUP";
        "server string" = lib.mkDefault "hsb1";
        "netbios name" = lib.mkDefault "hsb1";
        security = lib.mkDefault "user";
        "map to guest" = lib.mkDefault "never";
      };

      media = {
        path = "/srv/media";
        "valid users" = "markus";
        "read only" = "no";
        browseable = "yes";

        # The pool is written by TWO paths: rsync-over-SSH (as `mba`) and Finder/
        # SMB (as `markus`). Samba's DEFAULTS are create mask 0744 / directory
        # mask 0755 — i.e. everything arriving over SMB lands WITHOUT group write.
        # Mixed ownership + no group write = the two paths lock each other out,
        # which is exactly what happened on 2026-07-13: a storm of
        # "mkstemp/mkdir ... Permission denied (13)" on an rsync into the share.
        #
        # force user/group makes every SMB write land as mba:users regardless of
        # who authenticated, and the masks keep group-write on. Both paths then
        # produce identical ownership and can freely overwrite each other.
        #
        # NOTE: deliberately NO `vfs objects` here — the media share must stay
        # plain SMB. vfs_fruit's `fruit:metadata = stream` mangles macOS `._*`
        # AppleDouble sidecars and breaks rsync into the share (see ./tm-samba.nix,
        # where fruit is correctly scoped to the TM shares only).
        "force user" = "mba";
        "force group" = "users";
        "create mask" = "0664";
        "force create mode" = "0664";
        "directory mask" = "0775";
        "force directory mode" = "0775";
      };
    };
  };

  # Samba keeps its own password db (smbpasswd/tdbsam), separate from the
  # Unix password. Reuses secrets/hsb1-tm-smb-env.age's "markus <password>"
  # line — same secret tm-samba.nix will later use for both users; markus's
  # password is the same person either way. smbpasswd -a is idempotent —
  # safe to re-run on every activation.
  #
  # Observed 2026-07-13: on the very first activation of this module,
  # smbpasswd -a failed silently (swallowed by `|| true`) even though
  # /var/lib/samba/private already existed by then — exact cause unclear,
  # possibly the minimal activation-script environment racing something in
  # smbd's own first-start init. Re-running the identical command manually
  # moments later succeeded on the first try. Rather than chase an
  # intermittent race, retry briefly and — the actual fix — stop hiding
  # failures: log to the journal via `logger` so a future silent failure is
  # visible in `journalctl -t media-samba-passwd` instead of only
  # discoverable as "wrong password" at the Finder login prompt.
  system.activationScripts.mediaSambaPasswd = {
    text = ''
      pw=$(${pkgs.gnugrep}/bin/grep -m1 '^markus ' ${config.age.secrets.hsb1-tm-smb-env.path} | ${pkgs.coreutils}/bin/cut -d' ' -f2-)
      if [ -z "$pw" ]; then
        ${pkgs.util-linux}/bin/logger -t media-samba-passwd "ERROR: markus line not found/empty in ${config.age.secrets.hsb1-tm-smb-env.path}"
        exit 0
      fi
      ok=0
      for attempt in 1 2 3; do
        if printf '%s\n%s\n' "$pw" "$pw" | ${pkgs.samba}/bin/smbpasswd -s -a markus; then
          ok=1
          break
        fi
        ${pkgs.util-linux}/bin/logger -t media-samba-passwd "WARN: smbpasswd -a markus failed (attempt $attempt/3), retrying"
        sleep 2
      done
      if [ "$ok" -eq 1 ]; then
        ${pkgs.util-linux}/bin/logger -t media-samba-passwd "OK: markus smbpasswd seeded"
      else
        ${pkgs.util-linux}/bin/logger -t media-samba-passwd "ERROR: smbpasswd -a markus failed after 3 attempts — SMB auth for markus will not work until this is re-run"
      fi
    '';
    deps = [ "agenix" ];
  };
}
