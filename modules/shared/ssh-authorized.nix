# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║   INSPR-context SSH inbound trust matrix — HM-scope wrapper (consumes        ║
# ║   modules/shared/ssh-keyring.nix; feeds inspr-modules HM ssh-authorized)    ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Pattern β consumer-side wiring for `inspr.ssh.authorized` (HM module).
# Sibling to:
#   - ssh-fleet.nix             outbound SSH config (~/.ssh/config matchBlocks)
#   - ssh-fleet-nixos.nix       NixOS-side SSH config
#   - ssh-authorized-nixos.nix  NixOS-scope counterpart (since INSPR-73)
#   - ssh-keyring.nix           shared keyring data (single source of truth)
#   - markus-defaults.nix       other INSPR consumer-side defaults
#
# Since INSPR-73 (2026-05-04) the keyring + trust presets live in plain
# Nix data at `./ssh-keyring.nix` and are consumed by BOTH this file
# (HM scope) and `ssh-authorized-nixos.nix` (NixOS scope). Single source
# of truth across both modules; adding/retiring a key updates both
# `~/.ssh/authorized_keys` (HM) and `/etc/ssh/authorized_keys.d/<u>`
# (NixOS) on the next rebuild.
#
# Usage at consumer (per-host home.nix or similar HM scope):
#
#   home-manager.users.mba = { config, ... }: {
#     imports = [
#       inputs.inspr-modules.homeManagerModules.ssh-authorized   # captured at NixOS scope
#       ../../modules/shared/ssh-authorized.nix                   # this file
#     ];
#     inspr.ssh.authorized = {
#       enable = true;
#       trust  = config._inspr.trustPresets.personalHosts;
#     };
#   };
#
# NOTE: this file does NOT import the inspr-modules HM module itself,
# because `inputs` is not in scope inside `home-manager.users.<u>` blocks
# on NixOS hosts (extraSpecialArgs is only set for the standalone darwin
# HM via mkDarwinHome in flake.nix). The consumer wires both imports.
{
  config,
  lib,
  ...
}:

let
  kring = import ./ssh-keyring.nix;
in
{
  # ── Expose trust presets as a config attribute so hosts can read them ──
  # The `_inspr.*` namespace signals "internal helper, not part of
  # inspr-modules' official option API". Hosts use it like:
  #
  #   inspr.ssh.authorized = {
  #     enable = true;
  #     trust  = config._inspr.trustPresets.personalHosts;
  #   };
  #
  # Since INSPR-73 the same `_inspr.trustPresets` is also exposed by the
  # NixOS-scope wrapper (`./ssh-authorized-nixos.nix`), so the host can
  # use the SAME preset alias on both scopes.
  options._inspr.trustPresets = lib.mkOption {
    type = lib.types.attrsOf (lib.types.listOf lib.types.str);
    default = { };
    internal = true;
    description = ''
      Pre-built trust presets for inspr.ssh.authorized.trust. Defined in
      modules/shared/ssh-keyring.nix; consumed by per-host HM blocks.
      Internal to this nixcfg — not part of the public inspr-modules API.
    '';
  };

  config = {
    _inspr.trustPresets = kring.trustPresets;

    # Feed the shared keyring into the HM module's option. The HM module
    # accepts both string and rich-form values per alias; we pass the
    # keyring through as-is.
    inspr.ssh.authorized.keys = kring.keys;
  };
}
