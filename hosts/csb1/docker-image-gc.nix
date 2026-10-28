# Docker image GC — OPS-327 (port of agm1's AGM-48 rules).
#
# csb1 had no image GC: 300 images / 123.5 GB, 111.6 GB of it reclaimable
# (2026-10-28), mostly superseded AEON and HausV release images. The rules
# live in docker-image-gc.py. The image references of the Nix-declared compose
# spec (csb1 + Janus-managed stack) are baked in, so a declared service whose
# container does not exist yet keeps its image. 🔴 Never replace this with
# `docker image prune -a` / `system prune -a` (csb1 never-prune rule: Janus
# engine images and volumes).
#
# Dry run on the host: sudo DOCKER_IMAGE_GC_DRY_RUN=1 docker-image-gc
{
  config,
  pkgs,
  lib,
  ...
}:
let
  declaredRefs = lib.unique (
    lib.filter (ref: ref != null) (
      lib.mapAttrsToList (
        _: service: service.image or null
      ) config.nixcfg.composeStack.renderedSpec.services
    )
  );
  script = pkgs.replaceVars ./docker-image-gc.py {
    DECLARED_REFS = builtins.toJSON declaredRefs;
  };
  dockerImageGc = pkgs.writeShellScriptBin "docker-image-gc" ''
    exec ${pkgs.python3}/bin/python3 ${script} "$@"
  '';
in
{
  environment.systemPackages = [ dockerImageGc ];

  systemd.services.docker-image-gc = {
    description = "Remove unused Docker release images and old build cache (OPS-327)";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe dockerImageGc;
      # The docker socket is the only thing it needs: root:docker 0660.
      DynamicUser = true;
      SupplementaryGroups = [ "docker" ];
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      NoNewPrivileges = true;
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      SystemCallArchitectures = "native";
      TimeoutStartSec = "1h";
    };
  };

  # After the 01:05–01:20 backup snapshots, before the Saturday 05:07 compose update.
  systemd.timers.docker-image-gc = {
    description = "Daily Docker image GC (OPS-327)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 04:30:00";
      RandomizedDelaySec = "10m";
      Persistent = true;
      Unit = "docker-image-gc.service";
    };
  };
}
