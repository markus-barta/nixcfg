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
  secretPath =
    if hasSecret then config.age.secrets.${secretName}.path else "/run/agenix/${secretName}";
  injectUsers = pkgs.writeShellScript "adguard-users-secret" ''
    set +x
    exec ${pkgs.python3}/bin/python3 ${./adguard-users-secret.py} \
      "$STATE_DIRECTORY/AdGuardHome.yaml" "$CREDENTIALS_DIRECTORY/adguard-users" \
      ${pkgs.yq-go}/bin/yq
  '';
in
{
  options.services.adguardhome.usersSecretFile = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default = null;
    description = ''
      Agenix-encrypted JSON array of admin users (name and bcrypt password).
      The declaration is omitted until this file exists. Startup still fails
      closed without its runtime secret; provision it before switching.
    '';
  };

  config = lib.mkIf (cfg.enable && cfg.usersSecretFile != null) {
    assertions = [
      {
        assertion = cfg.settings != null && !cfg.mutableSettings;
        message = "AdGuard secret users require declarative, immutable settings.";
      }
      {
        assertion = !(cfg.settings ? users);
        message = "AdGuard users must come exclusively from the runtime secret.";
      }
    ];

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
    systemd.services.adguardhome.serviceConfig = {
      LoadCredential = [ "adguard-users:${secretPath}" ];
      ExecStartPre = lib.mkAfter [ "${injectUsers}" ];
    };
  };
}
