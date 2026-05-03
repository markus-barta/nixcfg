# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║         INSPR-context SSH keyring + trust presets — Markus's nixcfg         ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# **Plain-Nix data file — NOT a NixOS or Home Manager module.** Returns
# a record `{ keys; trustPresets; }` consumed by both:
#
#   - `modules/shared/ssh-authorized.nix`        (HM-scope wrapper, feeds
#                                                  inspr-modules' HM module)
#   - `modules/shared/ssh-authorized-nixos.nix`  (NixOS-scope wrapper, feeds
#                                                  inspr-modules' NixOS module)
#
# Single source of truth across both scopes. Adding/retiring a key here
# updates both `~/.ssh/authorized_keys` (HM) and `/etc/ssh/authorized_keys.d/<u>`
# (NixOS) on the next rebuild — no duplication, no drift.
#
# Adding a new key
# ────────────────
#   1. Generate keypair on the relevant host (`ssh-keygen -t ed25519
#      -C "<user>@<full-hostname> (added YYYY-MM-DD)"`)
#   2. Back up private key to 1Password (vault: Familie Barta / Private)
#   3. Add the pubkey here under `keys = { "<user>@<host>" = "..."; }`
#   4. Add the alias to whichever trust preset(s) below should admit it
#   5. Rebuild affected hosts → key gets added to authorized_keys (BOTH
#      ~/.ssh/authorized_keys via HM AND /etc/ssh/authorized_keys.d/<u>
#      via NixOS, on hosts that wire in both modules)
#
# Retiring a key
# ──────────────
#   1. Don't delete — change `keys.<alias>.status` to `"legacy"` first
#      (admitted with audit metadata; on HM render gets `[legacy]` tag
#      in the comment line; on NixOS render the audit lives in this
#      file's source)
#   2. After confirmed unused for weeks → `status = "revoked"` (declaration
#      stays as historical record; key NOT admitted; the alias must also
#      be removed from every trust preset — the modules throw at eval
#      time if a revoked alias is still listed in trust)
#   3. See INSPR-76 epic for the full retirement workflow + audit trail
#
# Provenance
# ──────────
#   - Initial trust map: INSPR-43 Phase 3 (2026-05-03)
#   - Per-host ed25519 keys: INSPR-78 (2026-05-03)
#   - System-side rendering (NixOS): INSPR-73 (2026-05-04)
#   - Legacy RSA discovery + retirement plan: INSPR-76 + see
#     ~/Code/inspr/legacy-rsa-key-inventory.md (canonical living doc)
{
  # ── Trust presets ───────────────────────────────────────────────────────
  # Host configurations pick one with
  # `inspr.ssh.authorized.users.<u>.trust = config._inspr.trustPresets.<preset>;`
  # (NixOS-scope) or
  # `inspr.ssh.authorized.trust = config._inspr.trustPresets.<preset>;`
  # (HM-scope).
  #
  # Add a new preset here when a new combination becomes useful (e.g.
  # when bytepoets-mba ed25519 gets added, when family hosts get their
  # own subset, etc.).
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

  # ── The keyring ─────────────────────────────────────────────────────────
  # All known SSH public keys with retirement metadata. Two forms accepted
  # (per inspr-modules INSPR-77 + INSPR-73): bare string for simple
  # always-active keys, or { key; status; note; } submodule for
  # grandfathering / audit metadata.
  keys = {
    # ── Legacy ────────────────────────────────────────────────────────────
    # Shared 2048-bit RSA key, originally generated on iMac 5k circa 2024
    # or earlier. Currently propagated to M5, imac0, gpc0 (identical key
    # material on all three). See INSPR-76 epic for the multi-stage
    # retirement plan + ~/Code/inspr/legacy-rsa-key-inventory.md for the
    # discovered admittance map.
    "markus-rsa-shared-pre-2026" = {
      key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt markus@iMac-5k-MBA-home.local";
      status = "legacy";
      note = "shared pre-2026 RSA; carried across M5+imac0+gpc0; retire via INSPR-76 once per-host ed25519 deployment is fleet-validated (target: late 2026)";
    };

    # ── Per-host ed25519s (added 2026-05-03 via INSPR-78) ─────────────────
    # Generated on each workstation with no passphrase (matches existing
    # id_rsa pattern; filesystem perms + 1P backup are the security
    # model). Both backed up in 1Password vault Familie Barta (Private)
    # under per-host entries.
    "mba@mba-mbp-m5-work" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP9FWi8t5l5fA4ps3+Qos2U4VbVY712kxQeIOczHaXs6 mba@mba-mbp-m5-work (added 2026-05-03)";
    "markus@imac0" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOdow+y+02Ekej5q3JD+5SSCWDDW4Hmiwwbfe9fTYUBA markus@imac0 (added 2026-05-03)";
  };
}
