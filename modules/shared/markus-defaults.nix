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
# (BYTEPOETS, family, paid-product context flakes) will define their own
# equivalent defaults file with their own identities / instances /
# patterns — each studio consumes the same atelier and provides its own
# private values.
#
# What this provides:
#   - inspr.git-identity.{identities, default, contexts}
#       Personal (Markus Barta <markus@barta.com>) as default.
#       BYTEPOETS context fires for github.com/{BYTEPOETS,bytepoets,bytepoets-mba}/*
#       remotes (HTTPS + SSH form, both anchored).
#
#   - inspr.git.atelier.{personal,bytepoets} (INSPR-170)
#       Strategy B SSH auth (per-host user keys) for fleet-wide federated
#       git push/pull. Each host gets two keypairs (one per identity), both
#       materialized via inspr.secrets.agents from the host's age/host/<h>/
#       directory. github.com pubkeys are registered on the matching
#       account (markus-barta / bytepoets-mba). The `hostKeys` lookup
#       below maps `hostname` (extraSpecialArg) to the host-specific
#       key filenames + pubkeys.
#
#   - inspr.paimos-cli.{instances, defaultInstance}
#       PPM (https://pm.barta.cm) as default. PPMAPIKEY sourced from the
#       agent-secrets-materialized PPMAPIKEY.env file.
#
# Note: this module DOESN'T enable anything by itself — it just declares
# values. The host's home.nix still needs `inspr.git-identity.enable = true`
# / `inspr.git.atelier.{personal,bytepoets}.enable = true` etc. to actually
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
    "mba-mbp-m5-work" = {
      personal = {
        keyName = "m5-personal-userkey";
        pubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM4sg88Rp+eGESk20Wo+1KNbKkluZFsGiZ+u6vnd9Whb m5-personal-userkey 2026-05-12";
      };
      bytepoets = {
        keyName = "m5-bytepoets-userkey";
        pubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN26yvYncUoYvFUrAZNZrieSra4hE44jiTEcjEuIfaTr m5-bytepoets-userkey 2026-05-12";
      };
    };
    "imac0" = {
      personal = {
        keyName = "imac0-personal-userkey";
        pubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOO/vDa+dpUVei1XcfM/dNJbvVPK3rP4X19d8+UYzXFf imac0-personal-userkey 2026-05-12";
      };
      bytepoets = {
        keyName = "imac0-bytepoets-userkey";
        pubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK3n5/2PT3/QYI6GY5noySbbj7ssWMeK9bkhr4NWBdaV imac0-bytepoets-userkey 2026-05-12";
      };
    };
    "mba-imac-work" = {
      # imacw — rotated 2026-05-13 after Day-11 Ghostty scrollback incident
      # (previous 2026-05-12 keypairs partially leaked to terminal scrollback
      # via the pre-content-filter .envrc bug; conservative rotation chosen).
      personal = {
        keyName = "imacw-personal-userkey";
        pubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIApVrzQL/SPss8x6JK/8YNFvSZpYgj1TYGzc3b1cJnYJ imacw-personal-userkey (rotated 2026-05-13)";
      };
      bytepoets = {
        keyName = "imacw-bytepoets-userkey";
        pubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDEw7pDTz4ykaQUbeQlIgTVMaKAx1IwWBKwPDuDv9CVa imacw-bytepoets-userkey (rotated 2026-05-13)";
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

  inspr.git-identity = {
    default = lib.mkDefault "personal";

    identities = {
      personal = {
        name = "Markus Barta";
        email = "markus@barta.com";
      };
      bytepoets = {
        # Name updated 2026-05-12 (INSPR-170): align with the GH username
        # bytepoets-mba so `git log` attribution matches push attribution.
        name = "bytepoets-mba";
        email = "markus.barta@bytepoets.com";
      };
    };

    contexts.bytepoets = {
      identity = "bytepoets";
      gitdirs = [
        "~/Code/BP/"
        "~/Code/bytepoets/"
      ];
      # Pattern semantics (empirically verified): * and ** in
      # hasconfig:remote.*.url do NOT cross URL-component boundaries
      # (the / after scheme://host blocks the match). So each remote
      # context needs both an HTTPS-anchored AND an SSH-anchored pattern.
      remoteUrlPatterns = [
        # github.com/BYTEPOETS/* (company org, exact case)
        "https://github.com/BYTEPOETS/**"
        "**:BYTEPOETS/**"
        # github.com/bytepoets/* (lowercase safety net)
        "https://github.com/bytepoets/**"
        "**:bytepoets/**"
        # github.com/bytepoets-mba/* (work user)
        "https://github.com/bytepoets-mba/**"
        "**:bytepoets-mba/**"
      ];
    };
  };

  inspr.paimos-cli = {
    defaultInstance = lib.mkDefault "ppm";

    instances.ppm = {
      url = "https://pm.barta.cm";
      apiKeyEnvFile = "${config.home.homeDirectory}/.inspr/secrets/agents/PPMAPIKEY.env";
      apiKeyVar = "PPMAPIKEY";
    };

    # INSPR-174: PMO (BYTEPOETS Project Management Online) — declarative
    # alongside PPM so a `paimos auth login --instance pmo` is never
    # needed on any fleet host. URL lives in agenix-encrypted PMOURL.env
    # rather than as a Nix literal, since it's a private BYTEPOETS host;
    # consumed via inspr.paimos-cli.instances.<name>.urlEnvFile (added
    # in inspr-modules 06431b2).
    instances.pmo = {
      urlEnvFile = "${config.home.homeDirectory}/.inspr/secrets/agents/PMOURL.env";
      urlVar = "PMOURL";
      apiKeyEnvFile = "${config.home.homeDirectory}/.inspr/secrets/agents/PMOAPIKEY.env";
      apiKeyVar = "PMOAPIKEY";
    };
  };

  # ── INSPR-170: fleet-wide federated git auth via atelier Strategy B ───
  # Two ateliers per host, each carrying ONE user-level SSH key registered
  # on the matching GitHub account. Owner-prefix URL rewrites pull every
  # repo under markus-barta/* through the personal alias, and every repo
  # under BYTEPOETS/* through the bytepoets alias. Per-atelier author
  # identity stays owned by inspr.git-identity (path-/URL-includeIf already
  # in place) — atelier.git.{userName,userEmail} intentionally left unset
  # to avoid duplicate includeIf entries.
  #
  # Enable flags here are `mkDefault false` so a host that doesn't want
  # both ateliers (or any) can opt out individually. Hosts in `hostKeys`
  # set `.enable = true` from their home.nix.
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
    bytepoets = {
      enable = lib.mkDefault false;
      forge = {
        kind = "github";
        url = "https://github.com";
        owner = "BYTEPOETS";
      };
      credentials.userKey = mkUserKey thisHostKeys.bytepoets;
    };
  };
}
