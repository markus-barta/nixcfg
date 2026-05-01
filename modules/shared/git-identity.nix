# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                  INSPR — Two-identity git config                             ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Markus has two git identities:
#   - personal:  Markus Barta <markus@barta.com>      (default)
#   - bytepoets: mba           <markus.barta@bytepoets.com>
#
# This module sets one as the global default and fires the OTHER via includeIf
# when either signal fires:
#   - gitdir:        the .git dir is under a context's directory root
#   - hasconfig:remote.*.url: any remote URL matches a context's URL pattern
#
# Why git-native (not direnv): includeIf fires for EVERY git operation regardless
# of shell/IDE/agent context. direnv only fires in shells that load it.
#
# Coverage rationale:
#   - personal patterns:  github.com/markus-barta/*
#   - bytepoets patterns: github.com/BYTEPOETS/*       (company org)
#                         github.com/bytepoets/*       (lowercase safety net)
#                         github.com/bytepoets-mba/*   (work user)
#
# Directory roots are forward-looking — Markus may reorganize ~/Code/ into
# Private/ + BP/ subtrees later. Until then, remote-URL match handles it.
#
# Usage:
#   imports = [ ../../modules/shared/git-identity.nix ];
#   inspr.git-identity.enable = true;
#
# To switch the default identity (rare):
#   inspr.git-identity.default = "bytepoets";
#
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.inspr.git-identity;

  # Markus-specific identities. Edit here if they ever change.
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

  defaultId = identities.${cfg.default};
  overrideKey = if cfg.default == "personal" then "bytepoets" else "personal";
  overrideId = identities.${overrideKey};

  # Override identity rendered as a .gitconfig fragment for includeIf to source
  overrideConfigFile = pkgs.writeText "git-identity-${overrideKey}" ''
    [user]
      name = ${overrideId.name}
      email = ${overrideId.email}
  '';

  # Patterns by context. Either signal (gitdir OR remote-url) fires the override.
  #
  # Pattern semantics gotcha (empirically verified):
  #   `*` and `**` in `hasconfig:remote.*.url:` do NOT cross URL-component
  #   boundaries (the `/` after scheme://host blocks the match). So for HTTPS
  #   URLs we need a pattern anchored on the host. SSH-form URLs use `:` as
  #   the host/path separator and `**` works across that.
  #
  # Coverage per context = HTTPS pattern + SSH pattern.
  patternsByContext = {
    bytepoets = {
      gitdirs = [
        "~/Code/BP/"
        "~/Code/bytepoets/"
      ];
      remotes = [
        # github.com/BYTEPOETS/* (company org, exact case)
        "https://github.com/BYTEPOETS/**"
        "**:BYTEPOETS/**"
        # github.com/bytepoets/* (lowercase safety net for the org)
        "https://github.com/bytepoets/**"
        "**:bytepoets/**"
        # github.com/bytepoets-mba/* (work user)
        "https://github.com/bytepoets-mba/**"
        "**:bytepoets-mba/**"
      ];
    };
    personal = {
      gitdirs = [
        "~/Code/Private/"
        "~/Code/personal/"
      ];
      remotes = [
        # github.com/markus-barta/* (personal user)
        "https://github.com/markus-barta/**"
        "**:markus-barta/**"
      ];
    };
  };

  overridePatterns = patternsByContext.${overrideKey};

  mkInclude = condition: {
    inherit condition;
    path = toString overrideConfigFile;
  };
in
{
  options.inspr.git-identity = {
    enable = lib.mkEnableOption "Markus's two-identity git config (personal default, BYTEPOETS via gitdir/remote-url match)";

    default = lib.mkOption {
      type = lib.types.enum [
        "personal"
        "bytepoets"
      ];
      default = "personal";
      description = ''
        Which identity to use as the global default.
        The OTHER identity fires via includeIf for repos in its context.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    programs.git = {
      enable = true;

      settings.user = {
        name = defaultId.name;
        email = defaultId.email;
      };

      includes =
        (map (g: mkInclude "gitdir:${g}") overridePatterns.gitdirs)
        ++ (map (r: mkInclude "hasconfig:remote.*.url:${r}") overridePatterns.remotes);
    };
  };
}
