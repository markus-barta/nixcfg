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
      };
    };
  };

  # Samba keeps its own password db (smbpasswd/tdbsam), separate from the
  # Unix password. Reuses secrets/hsb1-tm-smb-env.age's "markus <password>"
  # line — same secret tm-samba.nix will later use for both users; markus's
  # password is the same person either way. smbpasswd -a is idempotent —
  # safe to re-run on every activation.
  system.activationScripts.mediaSambaPasswd = {
    text = ''
      pw=$(${pkgs.gnugrep}/bin/grep -m1 '^markus ' ${config.age.secrets.hsb1-tm-smb-env.path} | ${pkgs.coreutils}/bin/cut -d' ' -f2-)
      if [ -n "$pw" ]; then
        printf '%s\n%s\n' "$pw" "$pw" | ${pkgs.samba}/bin/smbpasswd -s -a markus || true
      fi
    '';
    deps = [ "agenix" ];
  };
}
