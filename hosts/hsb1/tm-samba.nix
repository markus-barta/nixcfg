# Samba + vfs_fruit — Time Machine server for tm/markus and tm/mailina.
#
# Greenfield: no services.samba precedent exists anywhere in nixcfg yet.
# This is the reference implementation for any future TM/Samba host.
{ config, pkgs, ... }:
let
  # Time Machine sees this as the volume size; it must stay under the ZFS
  # refquota — numbers and the assertion live in ./tm-caps.nix (OPS-226).
  caps = import ./tm-caps.nix;
in
{
  # Mailina has no existing Unix account anywhere in the fleet (markus/mba
  # do). Samba maps SMB users to Unix accounts via smbpasswd, so she needs
  # one here — scoped to hsb1 only, not the fleet-wide markus-login module,
  # since this is the only service she needs access to.
  users.users.mailina = {
    isNormalUser = true;
    hashedPassword = "!"; # no console/SSH login, Samba-only
    group = "mailina";
  };
  users.groups.mailina = { };

  services.samba = {
    enable = true;
    openFirewall = false; # firewall is globally disabled repo-wide; port list still documented in configuration.nix

    settings = {
      global = {
        workgroup = "WORKGROUP";
        "server string" = "hsb1";
        "netbios name" = "hsb1";
        security = "user";
        "map to guest" = "never";
        # fruit:aapl is a GLOBAL-only knob and is what enables Apple's SMB2
        # extensions (needed for TM discovery). Harmless for non-fruit shares:
        # the fruit VFS module is only loaded where `vfs objects` says so.
        "fruit:aapl" = "yes";
        # OPS-228 (2026-09-23): Time Machine's first full copy aborted every
        # ~40 min with macOS errno 80 (EAUTH) while smbd (debug 3) saw nothing.
        # The Mac reaches hsb1 on two paths (LAN + Tailscale); with Samba's
        # default multichannel the client may bind a second channel over the
        # other path, and macOS's non-interactive credential lookup rejects the
        # "different server" — a documented cause of exactly this abort. One
        # channel, the LAN one.
        "server multi channel support" = "no";
      };

      # vfs_fruit is scoped to the TM shares ONLY — deliberately NOT global.
      #
      # It used to live in `global`, which silently applied it to the media share
      # too (see ./media-samba.nix), with two bad consequences (found 2026-07-13):
      #   1. `fruit:metadata = stream` converts macOS AppleDouble `._*` sidecars
      #      into alternate data streams. rsync writes a literal `._x.TMP` and
      #      renames it, which fruit then mangles -> a storm of
      #      "mkstemp ... Permission denied (13)" / "rename ... No such file" on
      #      every `._*` and `.DS_Store` while the real payload copied fine.
      #   2. `fruit:time machine = yes` advertised /srv/media as a Time Machine
      #      target, which it very much is not.
      # Keep these per-share. The media share must stay plain SMB.
      tm-markus = {
        path = "/srv/tm/markus";
        "valid users" = "markus";
        "read only" = "no";
        browseable = "yes";
        "vfs objects" = "catia fruit streams_xattr";
        "fruit:time machine" = "yes";
        "fruit:metadata" = "stream";
        "fruit:time machine max size" = "${toString caps.markus.maxSizeG}G";
        # Durable handles only work with posix locking off (Samba docs); the
        # sparsebundle is never locked by local processes, and without durable
        # handles any SMB hiccup disconnects the disk image → TM abort (OPS-228).
        "posix locking" = "no";
      };

      tm-mailina = {
        path = "/srv/tm/mailina";
        "valid users" = "mailina";
        "read only" = "no";
        browseable = "yes";
        "vfs objects" = "catia fruit streams_xattr";
        "fruit:time machine" = "yes";
        "fruit:metadata" = "stream";
        "fruit:time machine max size" = "${toString caps.mailina.maxSizeG}G";
        "posix locking" = "no"; # see tm-markus
      };
    };
  };

  # Discovery — Macs see hsb1 natively in System Settings > Time Machine
  # without a manual smb:// entry (matches original NIX-224/225 design).
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    # Keep IPv6 mDNS ON (OPS-228, 2026-09-23 03:22–06:00 lesson): Home
    # Assistant runs its own IPv4 mDNS stack on this host ("Detected another
    # IPv4 mDNS stack" in avahi's journal), so avahi's IPv4 announcements are
    # unreliable and IPv6 is the path on which the Macs actually see
    # hsb1's _smb/_adisk services. With `ipv6 = false` Time Machine could not
    # find its volume at all (RESULT 18, no SMB connection). The stable server
    # identity that Time Machine needs comes from
    # `networking.tempAddresses = "disabled"` (configuration.nix): one static
    # IPv4 + one stable EUI-64 IPv6, no rotating privacy addresses.
    publish = {
      enable = true;
      userServices = true;
    };
  };

  environment.etc."avahi/services/tm-smb.service".text = ''
    <?xml version="1.0" standalone='no'?>
    <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
    <service-group>
      <name replace-wildcards="yes">%h</name>
      <service>
        <type>_smb._tcp</type>
        <port>445</port>
      </service>
      <service>
        <type>_device-info._tcp</type>
        <port>0</port>
        <txt-record>model=TimeCapsule8,119</txt-record>
      </service>
      <service>
        <type>_adisk._tcp</type>
        <port>9</port>
        <txt-record>dk0=adVN=tm-markus,adVF=0x82</txt-record>
        <txt-record>dk1=adVN=tm-mailina,adVF=0x82</txt-record>
        <txt-record>sys=waMa=0,adVF=0x100</txt-record>
      </service>
    </service-group>
  '';

  # Credentials — secrets/hsb1-tm-smb-env.age (declared in configuration.nix's
  # central AGENIX SECRETS block), two lines: "markus <password>" and
  # "mailina <password>". Seeded into smbpasswd idempotently on every
  # activation (smbpasswd -a is safe to re-run — it just resets the password
  # to the same value if the account already exists).
  #
  # Retries + logs failure (see media-samba.nix for why): on this same
  # secret's first consumer (the media share), smbpasswd -a failed silently
  # on the very first activation for a still-unclear reason, and a bare
  # retry moments later succeeded immediately. `|| true` alone hides that
  # failure until someone can't authenticate; logger makes it visible in
  # `journalctl -t tm-samba-passwd`.
  system.activationScripts.tmSambaPasswd = {
    text = ''
      while read -r smbuser smbpass; do
        [ -z "$smbuser" ] && continue
        ok=0
        for attempt in 1 2 3; do
          if printf '%s\n%s\n' "$smbpass" "$smbpass" | ${pkgs.samba}/bin/smbpasswd -s -a "$smbuser"; then
            ok=1
            break
          fi
          ${pkgs.util-linux}/bin/logger -t tm-samba-passwd "WARN: smbpasswd -a $smbuser failed (attempt $attempt/3), retrying"
          sleep 2
        done
        if [ "$ok" -eq 1 ]; then
          ${pkgs.util-linux}/bin/logger -t tm-samba-passwd "OK: $smbuser smbpasswd seeded"
        else
          ${pkgs.util-linux}/bin/logger -t tm-samba-passwd "ERROR: smbpasswd -a $smbuser failed after 3 attempts — SMB auth for $smbuser will not work until this is re-run"
        fi
      done < ${config.age.secrets.hsb1-tm-smb-env.path}
    '';
    deps = [ "agenix" ];
  };
}
