# Docker image GC — OPS-327 (port of agm1's AGM-48 rules, design round 5).
#
# csb1 had no image GC: 300 images / 123.5 GB, 111.6 GB of it reclaimable
# (2026-10-28), mostly superseded AEON and HausV release images. The rules
# live in docker-image-gc.py. The image references of the Nix-declared compose
# spec (csb1 + Janus-managed stack) are baked in, so a declared service whose
# container does not exist yet keeps its image; at run time it also keeps every
# image a NixOS system on disk declares and every image keep.d names. The
# previous AEON release is the release kit's to state, in keep.d (contract v2,
# OPS-327): until aeon-live.refs and aeon-previous.refs hold, nothing is
# deleted. 🔴 Never replace this with `docker image prune -a` /
# `system prune -a` (csb1 never-prune rule: Janus engine images and volumes).
#
# Dry run on the host: sudo docker-image-gc (any run outside systemd is a dry run)
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

  # keep.d: the release kit's role files (aeon-live.refs, aeon-previous.refs) and the
  # images it prestages (aeon-staged-<release>.refs), one name[:tag]@sha256:<digest> per
  # line. It must exist: the GC refuses to judge without it.
  systemd.tmpfiles.rules = [
    "d /var/lib/docker-image-gc 0755 root root -"
    "d /var/lib/docker-image-gc/keep.d 0755 root root -"
  ];

  systemd.services.docker-image-gc = {
    description = "Remove unused Docker release images and old build cache (OPS-327)";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe dockerImageGc;
      # Root without capabilities: it owns the docker socket (root:docker 0660)
      # and the compose deploy locks (compose-hausv-next.lock is root 0600);
      # nothing else needs privilege.
      CapabilityBoundingSet = "";
      StateDirectory = "docker-image-gc";
      ReadWritePaths = [ "/run/lock" ];
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
      # SIGTERM sets a flag; the call in flight (a GET ends at its 30 s watchdog, a
      # DELETE when dockerd answers) finishes before the run stops.
      TimeoutStopSec = "180";
    };
  };

  # After the 01:05–01:20 backup snapshots, before the Saturday 05:07 compose
  # update (it waits for the same lock anyway). No Persistent catch-up: a missed
  # day waits for the next 04:30 instead of running right after a boot or switch.
  systemd.timers.docker-image-gc = {
    description = "Daily Docker image GC (OPS-327)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 04:30:00";
      RandomizedDelaySec = "10m";
      Unit = "docker-image-gc.service";
    };
  };
}
