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
          # nixpkgs github-runners hides tokenFile from job processes by default.
          # This host reuses that file for GHCR pull, so the agenix path must stay
          # reachable. Only hide the runner's copied token.
          InaccessiblePaths = lib.mkForce [ "/var/lib/github-runner/csb1-hausv/.current-token" ];

          # This runner executes the same root-only pre-deploy SQLite snapshot helper
          # as scripts/deploy.sh (creates /var/backups/hausv-predeploy, reads
          # /var/lib/csb1-docker/hausv-org). The helper requires passwordless sudo to
          # /run/current-system/sw/bin/python3. nixpkgs github-runner defaults block
          # sudo in three ways:
          #   - NoNewPrivileges=yes: prevents capability elevation (makes sudo a no-op)
          #   - PrivateUsers=yes: hides real host UIDs (sudo sees nobody:nogroup)
          #   - CapabilityBoundingSet="": drops CAP_SETUID/CAP_SETGID (even setuid
          #     binaries cannot change UIDs/GIDs)
          # Disable NoNewPrivileges and PrivateUsers, and restore the two capabilities
          # sudo requires. This gives the runner the same sudo privileges mba already
          # has over SSH, for this specific Python command only.
          NoNewPrivileges = lib.mkForce false;
          PrivateUsers = lib.mkForce false;
          CapabilityBoundingSet = [
            "CAP_SETUID"
            "CAP_SETGID"
          ];
        };
      };
}
