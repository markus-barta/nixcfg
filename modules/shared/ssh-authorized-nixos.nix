# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║   INSPR-context SSH inbound trust matrix — NixOS-scope wrapper (consumes    ║
# ║   modules/shared/ssh-keyring.nix; feeds inspr-modules NixOS ssh-authorized) ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# NixOS-scope counterpart to ./ssh-authorized.nix (HM-scope wrapper).
# Both share the keyring + presets via ./ssh-keyring.nix (single source
# of truth across both modules). Sibling to:
#   - ssh-fleet-nixos.nix  outbound SSH config
#   - ssh-authorized.nix   HM-scope wrapper (sibling, not a parent)
#   - ssh-keyring.nix      shared keyring data
#
# Why a NixOS-scope variant (INSPR-73)
# ────────────────────────────────────
# The HM module owns `~/.ssh/authorized_keys` per user. The NixOS module
# owns `users.users.<u>.openssh.authorizedKeys.keys` (rendered as
# `/etc/ssh/authorized_keys.d/<u>`). sshd reads BOTH per the default
# `AuthorizedKeysFile %h/.ssh/authorized_keys /etc/ssh/authorized_keys.d/%u`,
# so the two are complementary. With this NixOS-scope wrapper, the
# system-side keys also get the rich-key form (status: active|legacy|
# revoked) — which is what unblocks INSPR-76 RSA retirement: flipping
# `status = "legacy"` → `"revoked"` in the keyring is now sufficient
# to retire across the fleet.
#
# Usage at consumer (per-host configuration.nix or similar NixOS scope):
#
#   imports = [
#     inputs.inspr-modules.nixosModules.ssh-authorized
#     ../../modules/shared/ssh-authorized-nixos.nix
#   ];
#
#   inspr.ssh.authorized = {
#     enable = true;
#     users.mba = {
#       trust = config._inspr.trustPresets.personalHosts;
#       force = true;                              # drop hokage injection
#       extraKeys = [
#         "ssh-ed25519 AAAA... container-deploy"   # one-off, not in keyring
#       ];
#     };
#   };
#
# IMPORTANT: when wiring this in on a host that already has a manual
# `users.users.<u>.openssh.authorizedKeys.keys = lib.mkForce [ ... ]`
# declaration, REMOVE the manual declaration as part of the wire-up.
# Otherwise the manual mkForce wins and our module's contribution is
# silently dropped. (The NixOS module's `force = true` will mkForce its
# own contribution, which would conflict with the existing mkForce —
# nixos-rebuild surfaces this as a definition-conflict error.)
{
  config,
  lib,
  ...
}:

let
  kring = import ./ssh-keyring.nix;
in
{
  # ── Expose trust presets as a NixOS config attribute ────────────────────
  # Same `_inspr.trustPresets` shape as the HM-scope wrapper exposes.
  # Hosts use it like:
  #
  #   inspr.ssh.authorized.users.mba.trust = config._inspr.trustPresets.personalHosts;
  #
  # The same preset alias works on both scopes (HM and NixOS) — just
  # path the assignment differently per the module's option shape.
  options._inspr.trustPresets = lib.mkOption {
    type = lib.types.attrsOf (lib.types.listOf lib.types.str);
    default = { };
    internal = true;
    description = ''
      Pre-built trust presets for inspr.ssh.authorized — usable from
      either the HM scope (inspr.ssh.authorized.trust = ...) or the
      NixOS scope (inspr.ssh.authorized.users.<u>.trust = ...). Defined
      in modules/shared/ssh-keyring.nix. Internal to this nixcfg — not
      part of the public inspr-modules API.
    '';
  };

  config = {
    _inspr.trustPresets = kring.trustPresets;

    # Feed the shared keyring into the NixOS module's option. Same data
    # as the HM-scope wrapper feeds into the HM module — single source
    # of truth.
    inspr.ssh.authorized.keys = kring.keys;
  };
}
