# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║         INSPR-context defaults: Markus's personal nixcfg                    ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Pattern β consumer-side defaults. The public inspr-modules library
# (github.com/markus-barta/inspr-modules) provides only mechanics — this
# module provides the values that make those mechanics specific to
# Markus's personal context.
#
# Imported by every macOS host home.nix in this nixcfg. Future "context
# flakes" (BYTEPOETS, family, paid-product) will define their own
# equivalent defaults file with their own identities / instances /
# patterns — each consumes the same inspr-modules and provides its own
# values.
#
# What this provides:
#   - inspr.git-identity.{identities, default, contexts}
#       Personal (Markus Barta <markus@barta.com>) as default.
#       BYTEPOETS context fires for github.com/{BYTEPOETS,bytepoets,bytepoets-mba}/*
#       remotes (HTTPS + SSH form, both anchored).
#
#   - inspr.paimos-cli.{instances, defaultInstance}
#       PPM (https://pm.barta.cm) as default. PPMAPIKEY sourced from the
#       agent-secrets-materialized PPMAPIKEY.env file.
#
# Note: this module DOESN'T enable anything by itself — it just declares
# values. The host's home.nix still needs `inspr.git-identity.enable = true`
# etc. to actually apply.
#
{ config, lib, inputs, ... }:

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
    inputs.inspr-modules.homeManagerModules.git-identity
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
        name = "mba";
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
      apiKeyEnvFile = "${config.home.homeDirectory}/Secrets/age/decrypted/agents/PPMAPIKEY.env";
      apiKeyVar = "PPMAPIKEY";
    };
  };
}
