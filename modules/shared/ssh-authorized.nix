# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║         INSPR-context SSH inbound trust matrix — Markus's nixcfg            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Pattern β consumer-side trust matrix for `inspr.ssh.authorized` (the HM
# module from inspr-modules). Sibling to:
#   - ssh-fleet.nix         outbound SSH config (~/.ssh/config matchBlocks)
#   - ssh-fleet-nixos.nix   NixOS-side SSH config
#   - markus-defaults.nix   other INSPR consumer-side defaults
#
# This file owns ONLY the inbound trust posture: which keys exist, what
# their lifecycle status is, and which named presets each host can opt
# into. It does NOT enable the module — that's the host's home.nix job
# (`inspr.ssh.authorized.enable = true; inspr.ssh.authorized.trust = ...`).
#
# Adding a new key
# ────────────────
#   1. Generate keypair on the relevant host (`ssh-keygen -t ed25519
#      -C "<user>@<full-hostname> (added YYYY-MM-DD)"`)
#   2. Back up private key to 1Password (vault: Familie Barta / Private)
#   3. Add the pubkey here under `keys = { "<user>@<host>" = "..."; }`
#   4. Add to whichever trust preset(s) below should admit it
#   5. Rebuild affected hosts → new key gets added to their authorized_keys
#
# Retiring a key
# ──────────────
#   1. Don't delete — change `keys.<alias>.status` to `"legacy"` first
#      (rendered with [legacy] tag in authorized_keys; key still admitted)
#   2. After confirmed unused for weeks → `status = "revoked"` (declaration
#      stays as historical record; key NOT admitted; declaration is also
#      removed from `trust` preset)
#   3. See INSPR-76 epic for the full retirement workflow + audit trail
#
# Provenance
# ──────────
#   - Initial trust map: INSPR-43 Phase 3 (2026-05-03)
#   - Per-host ed25519 keys: INSPR-78 (2026-05-03)
#   - Legacy RSA discovery + retirement plan: INSPR-76 + see
#     ~/Code/inspr/legacy-rsa-key-inventory.md (canonical living doc)
#
# NOTE: this file does NOT import the inspr-modules ssh-authorized HM module
# itself, because `inputs` is not in scope inside `home-manager.users.<u>`
# blocks on NixOS hosts (extraSpecialArgs is only set for the standalone
# darwin HM via mkDarwinHome in flake.nix). Instead, the consumer wires
# in BOTH:
#
#   home-manager.users.mba = { config, ... }: {
#     imports = [
#       inputs.inspr-modules.homeManagerModules.ssh-authorized   # captured from NixOS scope
#       ../../modules/shared/ssh-authorized.nix                   # this file (keyring + presets)
#     ];
#     inspr.ssh.authorized = { enable = true; trust = config._inspr.trustPresets.<preset>; };
#   };
#
# When this is rolled out fleet-wide, common.nix can grow `inputs` in its
# arg list and extend its `home-manager.users = lib.genAttrs hokage.usersWithRoot`
# block to include both imports — at which point per-host wire-ups become
# just `inspr.ssh.authorized.{enable, trust}` declarations.
{
  config,
  lib,
  ...
}:

let
  # Trust presets — host home.nix picks one with
  # `inspr.ssh.authorized.trust = config._inspr.trustPresets.<preset>;`.
  #
  # Add a new preset here when a new combination becomes useful (e.g. when
  # bytepoets-mba ed25519 gets added, when family hosts get their own
  # subset, etc.).
  trustPresets = {
    # All current Markus-personal admittance: legacy RSA + both new ed25519s.
    # Use this on hosts where Markus actively SSHes in from M5 / imac0 today.
    personalHosts = [
      "markus-rsa-shared-pre-2026"
      "mba@mba-mbp-m5-work"
      "markus@imac0"
    ];

    # Post-retirement state (INSPR-76 Phase D): per-host ed25519 only,
    # no legacy RSA. Don't use on any host until the RSA has been
    # confirmed unused everywhere AND the new keys have weeks of
    # successful daily use.
    ed25519Only = [
      "mba@mba-mbp-m5-work"
      "markus@imac0"
    ];

    # Transitional / archival: legacy RSA only, no new ed25519s. Use on
    # hosts that haven't been Phase-3-rolled yet but want declarative
    # management of authorized_keys (no functional change vs current).
    legacyOnly = [
      "markus-rsa-shared-pre-2026"
    ];
  };
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
  # If we ever need to expose this beyond a single context flake, we'd
  # promote it to an `inspr.ssh.authorized.trustPreset` enum option in
  # the upstream module — but that's premature until a second consumer
  # asks for it.
  options._inspr.trustPresets = lib.mkOption {
    type = lib.types.attrsOf (lib.types.listOf lib.types.str);
    default = { };
    internal = true;
    description = ''
      Pre-built trust presets for inspr.ssh.authorized.trust. Defined in
      modules/shared/ssh-authorized.nix; consumed by per-host home.nix
      files. Internal to this nixcfg — not part of the public
      inspr-modules API.
    '';
  };

  config = {
    _inspr.trustPresets = trustPresets;

    # ── The keyring ─────────────────────────────────────────────────────
    # All known SSH public keys with retirement metadata. Two forms
    # accepted (per inspr-modules INSPR-77): bare string for simple
    # always-active keys, or { key; status; note; } submodule for
    # grandfathering / audit metadata.
    inspr.ssh.authorized.keys = {
      # ── Legacy ────────────────────────────────────────────────────────
      # Shared 2048-bit RSA key, originally generated on iMac 5k circa
      # 2024 or earlier. Currently propagated to M5, imac0, gpc0
      # (identical key material on all three). See INSPR-76 epic for the
      # multi-stage retirement plan + ~/Code/inspr/legacy-rsa-key-inventory.md
      # for the discovered admittance map.
      "markus-rsa-shared-pre-2026" = {
        key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt markus@iMac-5k-MBA-home.local";
        status = "legacy";
        note = "shared pre-2026 RSA; carried across M5+imac0+gpc0; retire via INSPR-76 once per-host ed25519 deployment is fleet-validated (target: late 2026)";
      };

      # ── Per-host ed25519s (added 2026-05-03 via INSPR-78) ─────────────
      # Generated on each workstation with no passphrase (matches existing
      # id_rsa pattern; filesystem perms + 1P backup are the security
      # model). Both backed up in 1Password vault Familie Barta (Private)
      # under per-host entries.
      "mba@mba-mbp-m5-work" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP9FWi8t5l5fA4ps3+Qos2U4VbVY712kxQeIOczHaXs6 mba@mba-mbp-m5-work (added 2026-05-03)";
      "markus@imac0" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOdow+y+02Ekej5q3JD+5SSCWDDW4Hmiwwbfe9fTYUBA markus@imac0 (added 2026-05-03)";
    };
  };
}
