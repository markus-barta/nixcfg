# Declarative GitHub Actions runner for hausv-org deployments.
# Replaces the tarball+patchelf+user-unit installation at /home/mba/actions-runner.
{
  pkgs,
  lib,
  config,
  ...
}:

{
  # Gate enable on the same secret existence check as the token itself, so eval
  # does not break if the .age file is missing.
  services.github-runners.csb1-hausv =
    lib.mkIf (builtins.pathExists ../../secrets/csb1-hausv-ghcr-pull.age)
      {
        enable = true;
        url = "https://github.com/inspr-at/hausv-org";
        name = "csb1-hausv";
        extraLabels = [ "csb1-hausv" ];
        # Take over the same runner name from the tarball install (if it exists).
        replace = true;
        # Reuse the existing GHCR pull token (repo-scoped, read:packages).
        tokenFile = config.age.secrets.csb1-hausv-ghcr-pull.path;
        user = "mba";
        group = "users";
        extraPackages = with pkgs; [
          git
          gnused
          gnugrep
          coreutils
          bash
          curl
          docker
          docker-compose
        ];
        serviceOverrides = {
          # This runner swaps production compose under /home/mba/Code/hausv-jhw22.
          # Default github-runner sandbox (ProtectHome) would block that. Keep
          # docker.sock, the compose dir, /run/lock/compose-hausv.lock, and the
          # GHCR token readable.
          ProtectHome = false;
          SupplementaryGroups = [
            "docker"
            "users"
          ];
        };
      };
}
