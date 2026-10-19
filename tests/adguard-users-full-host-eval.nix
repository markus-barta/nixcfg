{ config, lib }:
let
  cfg = config.services.adguardhome;
  name = "${config.networking.hostName}-adguard-users";
  unit = config.systemd.services.adguardhome;
  starts = unit.serviceConfig.ExecStartPre;
in
{
  ciphertextsPresent = lib.all builtins.pathExists ([ cfg.usersSecretFile ] ++ cfg.usersSecretPeers);
  agenixDeclared = config.age.secrets ? ${name};
  credentialMatchesAgenix =
    unit.serviceConfig.LoadCredential == [
      "adguard-users:${config.age.secrets.${name}.path}"
    ];
  injectorLast = starts != [ ] && lib.hasSuffix "-adguard-users-secret" (lib.last starts);
  noUsersInStoreSettings = !(cfg.settings ? users);
  secretRotationRestarts = builtins.elem cfg.usersSecretFile unit.restartTriggers;
  runtimeFallback = unit.serviceConfig.SetCredential == [ "adguard-users:" ];
  upstreamRuntimeDirectory = unit.serviceConfig.RuntimeDirectory == "AdGuardHome";
}
