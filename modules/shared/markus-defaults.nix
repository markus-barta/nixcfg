# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║         INSPR-context defaults: Markus's personal nixcfg                    ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Studio-side defaults (per the atelier pattern; "Pattern β" in older docs).
# The shared atelier — public inspr-modules library at
# github.com/markus-barta/inspr-modules — provides only mechanics. This
# module provides the values that make those mechanics specific to Markus's
# personal studio (his context).
#
# Imported by every macOS host home.nix in this nixcfg. Future studios
# (family, paid-product context flakes) will define their own
# equivalent defaults file with their own identities / instances /
# patterns — each studio consumes the same atelier and provides its own
# private values.
#
# What this provides:
#   - inspr.git-identity.{identities, default, contexts}
#       Personal (Markus Barta <markus@barta.com>) as default.
#       (BYTEPOETS context retired post-exit — INSPR-241.)
#
#   - inspr.git.atelier.personal (INSPR-170)
#       Strategy B SSH auth (per-host user keys) for fleet-wide federated
#       git push/pull. Each host gets a personal keypair,
#       materialized via inspr.secrets.agents from the host's age/host/<h>/
#       directory. github.com pubkeys are registered on the matching
#       account (markus-barta). The `hostKeys` lookup
#       below maps `hostname` (extraSpecialArg) to the host-specific
#       key filenames + pubkeys.
#
#   - inspr.paimos-cli.{instances, defaultInstance}
#       PPM (https://pm.barta.cm) as default non-secret routing. Workstations
#       authenticate interactively with `paimos auth login`; credentials stay
#       in the OS keyring and are never rendered by Home Manager.
#
# Note: this module DOESN'T enable anything by itself — it just declares
# values. The host's home.nix still needs `inspr.git-identity.enable = true`
# / `inspr.git.atelier.personal.enable = true` etc. to actually
# apply.
#
{
  config,
  lib,
  inputs,
  hostname ? null,
  ...
}:

let
  # ── Per-host SSH key data for INSPR-170 (atelier Strategy B) ───────────
  # Keyed by the extraSpecialArg hostname (matches the agent-secrets
  # host directory and the .age basename). Pubkeys are PUBLIC — registered
  # on github.com on the matching account, committed here for audit.
  # To add a new host: generate a keypair, paste pubkey here, encrypt
  # privkey to secrets/agents/host/<hostname>/<keyName>.age.
  hostKeys = {
    "mbp0" = {
      personal = {
        keyName = "m5-personal-userkey";
        pubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM4sg88Rp+eGESk20Wo+1KNbKkluZFsGiZ+u6vnd9Whb m5-personal-userkey 2026-05-12";
      };
    };
    # mbp2607: personal only. (mbp0's BYTEPOETS push key removed post-exit — INSPR-241.)
    "mbp2607" = {
      personal = {
        keyName = "mbp2607-personal-userkey";
        pubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDSreCb3wozn5fCvBkwDD9XHcwz0+ktpFhEQJixOA3zw mbp2607-personal-userkey 2026-07-03";
      };
    };
  };

  # Lookup or null. Hosts not in the table get atelier-disabled-by-default
  # (no keys, options exist but `.enable = false` means nothing renders).
  thisHostKeys = if hostname == null then null else hostKeys.${hostname} or null;

  # Helper: build a userKey option set pointing at the materialized .env
  # file under ~/.inspr/secrets/agents/ (where inspr.secrets.agents
  # places them at HM activation). `.env` extension is an agent-secrets
  # filename quirk; SSH does not care — file content is an ed25519 key.
  mkUserKey = entry: {
    privateKeyPath = "${config.home.homeDirectory}/.inspr/secrets/agents/${entry.keyName}.env";
    pubKey = entry.pubKey;
  };
in

{
  # ── Bundle: import all three INSPR public modules so Markus's hosts
  # need to import only `markus-defaults.nix` (this file) plus call
  # `inspr.X.enable = true` for whichever they want active. Importing
  # an HM module without enabling it costs nothing at runtime — the
  # module's `config` is wrapped in `lib.mkIf cfg.enable`, so unused
  # modules are inert. This keeps host home.nix files compact and
  # consistent across the fleet.
  imports = [
    inputs.inspr-modules.homeManagerModules.agent-secrets
    inputs.inspr-modules.homeManagerModules.devenv-direnv-fix
    inputs.inspr-modules.homeManagerModules.git-identity
    inputs.inspr-modules.homeManagerModules.git-atelier-credentials
    inputs.inspr-modules.homeManagerModules.paimos-config
  ];

  # Tell inspr.secrets.agents where Markus's nixcfg keeps its encrypted
  # .age files. Path is relative to THIS module file's location:
  #   nixcfg/modules/shared/markus-defaults.nix → ../../secrets/agents
  #   = nixcfg/secrets/agents
  inspr.secrets.agents.encryptedRoot = ../../secrets/agents;

  # Eval-time validation: derive the expected secret list directly from
  # secrets.nix so the agenix recipient declarations are the single source
  # of truth. If a declared .age is untracked-in-git (invisible to the
  # flake source closure), agent-secrets throws with a clear remediation
  # hint instead of silently skipping (NIX-1861, 2026-05-25 root cause).
  inspr.secrets.agents.requireFiles =
    let
      # Read the recipient map. Keys are paths like
      # "agents/shared/X.age" or "agents/host/<host>/X.age".
      secrets = import ../../secrets/secrets.nix;
      keys = builtins.attrNames secrets;

      # Which keys apply to THIS host:
      #  - everything under agents/shared/ is always expected
      #  - agents/host/<hostname>/* is expected only when hostname matches
      isFor =
        k:
        lib.hasPrefix "agents/shared/" k
        || (hostname != null && lib.hasPrefix "agents/host/${hostname}/" k);

      # "agents/shared/HOMEWIFI.age" → "HOMEWIFI"
      nameOf = k: lib.removeSuffix ".age" (lib.last (lib.splitString "/" k));
    in
    map nameOf (builtins.filter isFor keys);

  inspr.git-identity = {
    default = lib.mkDefault "personal";

    identities = {
      personal = {
        name = "Markus Barta";
        email = "markus@barta.com";
      };
    };
  };

  inspr.paimos-cli = {
    defaultInstance = lib.mkDefault "ppm";

    instances.ppm = {
      url = "https://pm.barta.cm";
    };

    # PMO (INSPR-174) removed 2026-07-13: the BYTEPOETS Paimos instance was
    # decommissioned with the departure (2026-06-15). PPM is the only instance.
  };

  # ── INSPR-170: fleet-wide federated git auth via atelier Strategy B ───
  # One personal atelier per host, carrying ONE user-level SSH key registered
  # on the markus-barta GitHub account. Owner-prefix URL rewrites pull every
  # repo under markus-barta/* through the personal alias. Per-atelier author
  # identity stays owned by inspr.git-identity (path-/URL-includeIf already
  # in place) — atelier.git.{userName,userEmail} intentionally left unset to
  # avoid duplicate includeIf entries. (BYTEPOETS atelier retired post-exit,
  # INSPR-241.)
  #
  # Enable flag here is `mkDefault false` so a host that doesn't want the
  # atelier can opt out. Hosts in `hostKeys` set `.enable = true` from
  # their home.nix.
  inspr.git.atelier = lib.mkIf (thisHostKeys != null) {
    personal = {
      enable = lib.mkDefault false;
      forge = {
        kind = "github";
        url = "https://github.com";
        owner = "markus-barta";
      };
      credentials.userKey = mkUserKey thisHostKeys.personal;
    };
  };
}
