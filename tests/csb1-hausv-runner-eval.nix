# OPS-678: evaluate the complete csb1 config, including upstream runner defaults.
{ config, lib }:
let
  token = config.age.secrets.csb1-hausv-ghcr-pull;
  operator = config.users.users.mba;
in
assert lib.assertMsg (config.networking.hostName == "csb1") "OPS-678: expected csb1";
assert lib.assertMsg (
  !(config.services.github-runners ? csb1-hausv)
) "OPS-678: retired runner must be absent";
assert lib.assertMsg (
  !(config.systemd.services ? github-runner-csb1-hausv)
) "OPS-678: retired runner unit must be absent";
{
  pullTokenPath = token.path == "/run/agenix/csb1-hausv-ghcr-pull";
  pullTokenPermissions = token.owner == "root" && token.group == "users" && token.mode == "0440";
  operatorCanReadPullToken = operator.group == "users" || builtins.elem "users" operator.extraGroups;
}
