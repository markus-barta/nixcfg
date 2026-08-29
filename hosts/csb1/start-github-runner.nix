# Declarative GitHub Actions runner for augmentoring-team/start-agm-com.
# NIX-378: Same shape as hausv-github-runner.nix, different token and repo.
{
  pkgs,
  lib,
  config,
  ...
}:

{
  # Gate enable on the same secret existence check as the token itself, so eval
  # does not break if the .age file is missing.
  services.github-runners.csb1-start =
    lib.mkIf (builtins.pathExists ../../secrets/csb1-start-github-runner.age)
      {
        enable = true;
        url = "https://github.com/augmentoring-team/start-agm-com";
        name = "csb1-start";
        extraLabels = [ "csb1-start" ];
        # Take over the same runner name from any previous install (if it exists).
        replace = true;
        # Dedicated runner token for augmentoring-team/start-agm-com.
        # Janus capability name: github.runner.augmentoring-team/start-agm-com
        # Edit hint: agenix -e secrets/csb1-start-github-runner.age
        tokenFile = config.age.secrets.csb1-start-github-runner.path;
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
          nodejs_24
        ];
        serviceOverrides = {
          # This runner executes START deployments under /home/mba/docker/start-agm-com
          # and talks to docker.sock. Default github-runner sandbox (ProtectHome)
          # would block that. Keep docker.sock, the deploy dir, and the runner
          # token readable.
          ProtectHome = false;
          SupplementaryGroups = [
            "docker"
            "users"
          ];
          # Do not override nixpkgs' InaccessiblePaths default: it hides both
          # the agenix tokenFile and the runner's copied token from job processes.

          # START deployment does NOT require root snapshots (unlike hausv's
          # SQLite/blob snapshot), so we keep the default restrictive capability
          # set. No sudo, no NoNewPrivileges override, no CapabilityBoundingSet
          # expansion needed.
        };
      };
}
