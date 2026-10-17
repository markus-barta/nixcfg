{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.adguardhome;
  secretName = "${config.networking.hostName}-adguard-users";
  hasSecret = builtins.pathExists cfg.usersSecretFile;
  python = pkgs.python3.withPackages (p: [ p.bcrypt ]);
  injectUsers = pkgs.writeShellScript "adguard-users-secret" ''
    set +x
    exec ${python}/bin/python3 ${./adguard-users-secret.py} \
      "$STATE_DIRECTORY/AdGuardHome.yaml" "''${CREDENTIALS_DIRECTORY:-/nonexistent}/adguard-users" \
      ${pkgs.yq-go}/bin/yq "$RUNTIME_DIRECTORY/admin-locked" ${toString cfg.port}
  '';
in
{
  options.services.adguardhome.usersSecretFile = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default = null;
    description = ''
      Agenix-encrypted JSON array of admin users (name and bcrypt password).
      Evaluation rejects missing ciphertext. At runtime an unavailable or
      malformed credential locks admin login while preserving DNS/DHCP.
    '';
  };
  options.services.adguardhome.usersSecretPeers = lib.mkOption {
    type = lib.types.listOf lib.types.path;
    default = [ ];
    description = "Other users ciphertexts required for the same reviewed cutover.";
  };

  config = lib.mkIf (cfg.enable && cfg.usersSecretFile != null) {
    assertions =
      map (file: {
        assertion = builtins.pathExists file;
        message = "OPS-372: missing AdGuard users ciphertext ${toString file}; provision both hosts before switching.";
      }) ([ cfg.usersSecretFile ] ++ cfg.usersSecretPeers)
      ++ [
        {
          assertion = cfg.settings != null && !cfg.mutableSettings;
          message = "AdGuard secret users require declarative, immutable settings.";
        }
        {
          assertion = !(cfg.settings ? users);
          message = "AdGuard users must come exclusively from the runtime secret.";
        }
      ];
    warnings = lib.optional (
      !hasSecret
    ) "OPS-372: AdGuard users ciphertext is missing; switching is blocked.";

    age.secrets = lib.optionalAttrs hasSecret {
      ${secretName} = {
        file = cfg.usersSecretFile;
        owner = "root";
        group = "root";
        mode = "0400";
      };
    };

    # nixpkgs f5c082a: adguardhome.nix:178-204 copies the store template in
    # preStart when mutableSettings=false. Run AFTER that and the host's DHCP
    # hook. systemd reads the root-only agenix source and supplies a private
    # credential to DynamicUser. The merge retains the upstream sandbox.
    systemd.services.adguardhome = {
      restartTriggers = lib.optional hasSecret cfg.usersSecretFile;
      serviceConfig = {
        LoadCredential = lib.optional hasSecret "adguard-users:${config.age.secrets.${secretName}.path}";
        # Empty, deliberately invalid fallback: systemd tolerates a missing
        # LoadCredential source when SetCredential supplies the same ID.
        SetCredential = [ "adguard-users:" ];
        # Keep upstream's /run/AdGuardHome (also used for its pidfile).
        RuntimeDirectoryMode = "0700";
        ExecStartPre = lib.mkAfter [ "${injectUsers}" ];
      };
    };

    # A failed unit exposes degraded admin authentication without taking down
    # DNS/DHCP. Recheck after restarts, including recovery from a bad rotation.
    systemd.services.adguardhome-users-health = {
      description = "AdGuard admin credential health (OPS-372)";
      after = [ "adguardhome.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.coreutils}/bin/test ! -e /run/AdGuardHome/admin-locked";
      };
    };
    systemd.timers.adguardhome-users-health = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "1min";
      };
    };
  };
}
