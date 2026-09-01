# Declarative Docker Compose stacks — OPS-116.
#
# WHY THIS EXISTS
# ===============
# Every piece of state on these hosts is derived from the system closure and
# converged at activation — except containers. Those are imperative artifacts a
# human created at some point, holding a frozen copy of whatever the host looked
# like then. Docker copies /etc/resolv.conf into a container ONCE, at container
# start, and never refreshes it.
#
# That gap is why OPS-109 (a correct host resolver change) silently killed the
# Janischhofweg access gate for two days: hsb1's Node-RED kept the dead MagicDNS
# resolver, could no longer re-resolve mosquitto.barta.cm, and every Telegram
# command was published into a broker with no subscriber. Nothing reconciled it
# because nothing owns containers (OPS-113).
#
# WHAT THIS DOES
# ==============
# Puts the compose spec in the closure and lets `nixos-rebuild switch` reconcile
# it. Change networking.nameservers -> the rendered spec changes -> its store
# path changes -> restartTriggers fires the reconcile unit -> compose recreates
# exactly the services whose definition changed. The OPS-113 mechanism stops
# being possible rather than being monitored faster.
#
# It also removes the duplication OPS-114 was opened for: `dns` REFERENCES
# config.networking.nameservers instead of copying it, so hsb8/hsb9's
# location-conditional resolvers resolve correctly on their own — they are the
# same expression, not a copy of its output.
#
# NOT virtualisation.oci-containers: that also reconciles, but abandons compose
# semantics (networks, depends_on, profiles, named volumes) that Traefik
# discovery and the live data on csb1 lean on, and would force volume migration
# on paperless/docmost/postgres for no additional benefit.
#
# PRECEDENT
# =========
# csb1 already does this for one service: environment.etc holds
# janus/managed/docker-compose.yml and systemd.services.janus-managed-canary
# runs compose against it. This generalises a pattern already in production
# here; it is not a new architecture.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.nixcfg.composeStack;

  # A service gets host DNS only when it shares the host's network stack.
  #
  # Bridge-network services must keep Docker's embedded resolver (127.0.0.11),
  # which forwards to the host file at QUERY time and is therefore never
  # stranded — setting `dns` on them would replace that resolver and break
  # container-name resolution. network_mode "none" has no network stack at all
  # (csb1's janus-managed-canary), so there is nothing to configure.
  #
  # On hsb0 this distinction is load-bearing in a second way: its nameserver is
  # 127.0.0.1, which means the HOST's loopback (AdGuard Home) only because these
  # are host-network services. On a bridge service it would mean the container's
  # own loopback, i.e. nothing.
  isHostNetwork = service: (service.network_mode or null) == "host";

  withHostDns =
    service:
    if !isHostNetwork service then
      service
    else
      service
      // lib.optionalAttrs (config.networking.nameservers != [ ]) {
        dns = config.networking.nameservers;
      }
      // lib.optionalAttrs (config.networking.search != [ ]) {
        dns_search = config.networking.search;
      };

  renderedSpec = cfg.spec // {
    services = lib.mapAttrs (_: withHostDns) (cfg.spec.services or { });
  };

  # Compose reads JSON — YAML is a superset — so the spec never round-trips
  # through a YAML writer that could reorder or requote anything.
  composeFile = pkgs.writeText "docker-compose-${cfg.project}.yml" (builtins.toJSON renderedSpec);

  projectDirFlag = lib.optionalString (
    cfg.projectDirectory != null
  ) "--project-directory ${lib.escapeShellArg cfg.projectDirectory}";

  # NIX-384: registry logins for private images. Both units run as root with no
  # docker client config, so a private image fails to pull even when an
  # operator's SSH session holds a login. The login lands in a per-unit
  # RuntimeDirectory (tmpfs, 0700) selected through DOCKER_CONFIG and is removed
  # again once the unit's work is done: no reusable auth blob is ever written
  # under /root and root's credential helpers are never consulted. The docker
  # CLI is the host's own daemon package, not a second closure.
  registryAuth =
    suffix:
    let
      dir = "compose-${cfg.stackName}${suffix}-docker-auth";
      docker = "${config.virtualisation.docker.package}/bin/docker";
    in
    lib.mkIf (cfg.registryLogins != [ ]) {
      environment.DOCKER_CONFIG = "/run/${dir}";
      serviceConfig.RuntimeDirectory = dir;
      serviceConfig.RuntimeDirectoryMode = "0700";
      preStart = ''
        umask 077
      ''
      + lib.concatMapStrings (login: ''
        test -r ${lib.escapeShellArg login.passwordFile}
        ${docker} login ${lib.escapeShellArg login.registry} \
          --username ${lib.escapeShellArg login.username} --password-stdin \
          < ${lib.escapeShellArg login.passwordFile}
      '') cfg.registryLogins;
      postStart = "${pkgs.coreutils}/bin/rm -f /run/${dir}/config.json";
    };
in
{
  options.nixcfg.composeStack = {
    enable = lib.mkEnableOption "declarative docker compose stack reconciled at switch (OPS-116)";

    project = lib.mkOption {
      type = lib.types.str;
      description = ''
        Compose project name — the `-p` value. MUST match what the stack was
        originally deployed under, because named volumes are prefixed with it.

        🔴 On hsb0/hsb1/hsb8/hsb9 this is literally "docker", NOT the hostname.
        Those compose files carry no `name:` key, so compose derived the project
        from the containing directory (hosts/<host>/docker). Verified on the
        live hosts 2026-08-01 via the com.docker.compose.project label. hsb1 has
        a real named volume riding on it — `docker_opus-stream-app`, the
        node_modules cache for the OPUS→MQTT bridge — so setting this to "hsb1"
        would look for `hsb1_opus-stream-app`, not find it, and silently create
        an empty one.

        csb0 and csb1 declare `name:` explicitly and are "csb0" / "csb1".

        Use `stackName` for anything human-facing; this option exists only to be
        byte-identical to history.
      '';
    };

    stackName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Human-facing name for the /etc path and the systemd unit. Defaults to
        `project`, but exists so the home hosts do not end up with
        /etc/compose/docker/ and a unit called compose-docker just because
        compose once derived their project name from a directory.
      '';
    };

    spec = lib.mkOption {
      type = lib.types.attrs;
      description = ''
        The compose spec as a Nix attrset — services, networks, volumes, name.
        `dns` and `dns_search` are injected automatically into every
        `network_mode: host` service and must NOT be written here.
      '';
    };

    projectDirectory = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Working directory for resolving relative paths in the spec.

        With `-f /etc/...`, compose resolves `./traefik/static.yml` against the
        compose file's directory, which is in /etc and does not contain it. Set
        this to the repo checkout to preserve today's resolution during the
        migration. Every current host sets this option because each retained
        specification still has at least one relative build context or bind
        path.

        Absolutising the paths is the cleaner end state; this exists so a host
        can migrate before that work is done.
      '';
    };

    postRecreate = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Services to force-recreate after the main reconcile.

        For containers whose content comes from a path that changes per
        generation but whose compose definition does not — the HostDash landing
        pages mount /etc/hostdash/<host>, so a new generation changes what is
        behind that mount while compose sees an unchanged service and correctly
        does nothing. Without this they serve the previous generation's page
        indefinitely.

        This reproduces the ExecStartPost that the per-host <host>-stack units
        carried before composeStack superseded them (NIX-158).
      '';
    };

    extraAfter = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Extra units to order the reconcile after (with Wants, not Requires —
        the whole stack must not fail because one dependency did).

        Exists for hsb0's var-lib-ncps.mount: the repo carried ordering on a
        `docker-ncps.service` that never existed (oci-containers naming, never
        used here), so the guarantee was a phantom — the QA-2 sweep found the
        ncps container could start on an empty /var/lib/ncps. Stack-level
        ordering is the closest compose can express to per-service ordering.
      '';
    };

    extraRestartTriggers = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      description = ''
        Additional restart triggers beyond the rendered spec.

        Needed for exactly the same reason as postRecreate: the HostDash
        artifact changing must re-run the reconcile, and it is not part of the
        compose spec.
      '';
    };

    registryLogins = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            registry = lib.mkOption {
              type = lib.types.str;
              example = "ghcr.io";
              description = "Registry host to log in to before compose runs.";
            };
            username = lib.mkOption {
              type = lib.types.str;
              description = "Login user; for GHCR with a classic PAT this is the GitHub login.";
            };
            passwordFile = lib.mkOption {
              type = lib.types.str;
              description = ''
                Path to the token file (an agenix path, root-readable, one line).
                Read with --password-stdin; never placed on a command line.
              '';
            };
          };
        }
      );
      default = [ ];
      description = ''
        Registry logins performed by the reconcile and the weekly update unit
        before compose runs (NIX-384). Needed for private images: the units run
        as root with no docker client config, so a login held by an operator's
        SSH user never applies to them. The login lives in a per-unit
        RuntimeDirectory through DOCKER_CONFIG and is removed after the unit's
        work; nothing is written under /root.
      '';
    };

    removeOrphans = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether the reconcile passes --remove-orphans.

        Correct in principle — the closure should be the whole truth — but it
        reaps any container in the project that this spec does not declare, and
        on csb1 the Janus-managed services and hausv-org are driven by their own
        units inside project `csb1`. Default off; turn it on per host only after
        checking `docker compose -p <project> ps` against the spec.
      '';
    };

    autoUpdate = {
      enable = lib.mkEnableOption "weekly compose pull + up, replacing watchtower (OPS-125)";
      schedule = lib.mkOption {
        type = lib.types.str;
        default = "Sat *-*-* 05:00:00";
        description = ''
          OnCalendar for the update timer. Default keeps watchtower's old
          Saturday-early-morning cadence so update behaviour stays familiar.
        '';
      };
      excludeFromPull = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Services the weekly updater must never `pull` (NIX-352).

          For images that exist only on this host — built and tagged locally
          by a manual release path, never published to a registry — the
          stack-wide pull dies on the registry's denial BEFORE `up -d`, so one
          unpullable image starves every other service of its scheduled update
          (csb1's hausv-org, observed live 2026-08-08). Excluded services keep
          their compose definition and are still converged by `up -d`; only
          the registry pull is skipped.
        '';
      };
    };

    reconcile = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether switch runs `compose up -d`. Set false to render the file into
        the closure WITHOUT touching running containers — the state every host
        should sit in while being prepared and gate-verified, before anyone
        intends a real cutover.
      '';
    };

    renderedFile = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      default = composeFile;
      description = "The rendered compose file. Read by the equivalence gate.";
    };

    renderedSpec = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      default = renderedSpec;
      description = ''
        The final spec after DNS injection. The equivalence gate evaluates this
        directly with `nix eval --json`, so verification needs no build and can
        run from macOS.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.spec.name or cfg.project) == cfg.project;
        message = "composeStack: spec.name (${cfg.spec.name or "<unset>"}) must equal project (${cfg.project}) — a mismatch orphans named volumes.";
      }
      {
        assertion = lib.all (s: !(s ? dns) && !(s ? dns_search)) (
          lib.attrValues (cfg.spec.services or { })
        );
        message = "composeStack: a service declares dns/dns_search by hand. Remove it — the module injects those from networking.nameservers, and a literal here is the OPS-114 duplication returning.";
      }
      {
        assertion = lib.all (
          svc: lib.hasAttr svc (cfg.spec.services or { })
        ) cfg.autoUpdate.excludeFromPull;
        message = "composeStack: autoUpdate.excludeFromPull names services absent from the spec: ${
          lib.concatStringsSep ", " (
            lib.filter (svc: !(lib.hasAttr svc (cfg.spec.services or { }))) cfg.autoUpdate.excludeFromPull
          )
        } — a typo here would silently keep pulling the service it meant to protect.";
      }
    ];

    nixcfg.composeStack.stackName = lib.mkDefault cfg.project;

    environment.etc."compose/${cfg.stackName}/docker-compose.yml".source = composeFile;

    systemd.services."compose-${cfg.stackName}" = lib.mkIf cfg.reconcile (
      lib.mkMerge [
        {
          description = "Reconcile the ${cfg.stackName} container stack with the system closure (OPS-116)";
          wantedBy = [ "multi-user.target" ];
          after = [
            "docker.service"
            "network-online.target"
          ]
          ++ cfg.extraAfter;
          requires = [ "docker.service" ];
          wants = [ "network-online.target" ] ++ cfg.extraAfter;

          # The whole point: a changed spec changes this store path, so switch
          # restarts the unit and compose recreates exactly the affected services.
          restartTriggers = [ composeFile ] ++ cfg.extraRestartTriggers;

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            # Pulling a moved tag can take a while on a slow uplink; a stuck
            # reconcile must fail the unit rather than hang activation forever.
            TimeoutStartSec = "600";

            # Without this a failed reconcile is STICKY: the unit stays failed, and
            # because switch only restarts it when restartTriggers changes, the next
            # unrelated switch does NOT retry. A host could then sit with an
            # unreconciled stack indefinitely while every rebuild reports success.
            # Three spaced attempts absorb the transients that actually happen here
            # (a registry blip, a slow uplink) and then give up loudly, so a genuinely
            # bad spec still lands in `systemctl --failed` instead of looping.
            Restart = "on-failure";
            RestartSec = "30s";
          };
          # After 3 failures in 300s systemd refuses to start the unit until
          # `systemctl reset-failed compose-<stackName>` — including on a later
          # switch. That is deliberate (a bad spec should stop, not loop) but it is
          # the one recovery step that is not obvious from the error, so:
          #   systemctl reset-failed compose-<stackName> && systemctl start compose-<stackName>
          startLimitIntervalSec = 300;
          startLimitBurst = 3;

          # docker-compose v2 standalone, matching the binary csb1's existing
          # janus-managed-canary unit already uses. `docker compose` as a CLI plugin
          # depends on the plugin path resolving inside the unit's environment;
          # this does not.
          #
          # flock: compose takes NO project-level lock (verified in the OPS-116 QA),
          # so the reconcile and the autoUpdate timer — and anything else that adopts
          # this lock — serialize here instead of racing on transitional container
          # names, which is exactly how the hsb1 cutover failed its first attempt.
          script =
            let
              compose = "${pkgs.docker-compose}/bin/docker-compose -p ${lib.escapeShellArg cfg.project} -f ${composeFile} ${projectDirFlag}";
              locked = "${pkgs.util-linux}/bin/flock -w 570 /run/lock/compose-${cfg.stackName}.lock";
            in
            ''
              ${locked} ${compose} up -d${lib.optionalString cfg.removeOrphans " --remove-orphans"}
            ''
            + lib.concatMapStrings (svc: ''
              ${locked} ${compose} up -d --force-recreate --no-deps ${lib.escapeShellArg svc}
            '') cfg.postRecreate;
        }
        (registryAuth "")
      ]
    );

    # OPS-125 — the one updater. Weekly `pull` + `up -d` through the SAME
    # rendered file, project and lock as the reconcile: exactly watchtower's
    # job, done through compose instead of behind its back. No stale
    # com.docker.compose.image labels, no pseudo-drift, no Saturday race —
    # and a failed update lands in `systemctl --failed` instead of nowhere.
    systemd.services."compose-${cfg.stackName}-update" =
      lib.mkIf (cfg.reconcile && cfg.autoUpdate.enable)
        (
          lib.mkMerge [
            {
              description = "Pull newer images and converge the ${cfg.stackName} stack (OPS-125)";
              after = [
                "docker.service"
                "network-online.target"
                "compose-${cfg.stackName}.service"
              ];
              requires = [ "docker.service" ];
              wants = [ "network-online.target" ];
              serviceConfig = {
                Type = "oneshot";
                # Pulls across a whole stack on a slow uplink can take a while.
                TimeoutStartSec = "1800";
              };
              script =
                let
                  compose = "${pkgs.docker-compose}/bin/docker-compose -p ${lib.escapeShellArg cfg.project} -f ${composeFile} ${projectDirFlag}";
                  locked = "${pkgs.util-linux}/bin/flock -w 1770 /run/lock/compose-${cfg.stackName}.lock";
                  # NIX-352: with exclusions, pull an explicit service list instead of
                  # the whole stack — a stack-wide pull aborts on the first denied
                  # image and starves everything else of its update. Only image-
                  # bearing services are listed (compose skips build-only services
                  # in a stack-wide pull too, so the set is identical); excluded
                  # services are still converged by `up -d` below.
                  pullTargets = lib.filter (svc: !(lib.elem svc cfg.autoUpdate.excludeFromPull)) (
                    lib.attrNames (lib.filterAttrs (_: service: service ? image) (cfg.spec.services or { }))
                  );
                  pullCommand =
                    if cfg.autoUpdate.excludeFromPull == [ ] then
                      "${locked} ${compose} pull --quiet"
                    else if pullTargets == [ ] then
                      ": # every image-bearing service is excluded from pull"
                    else
                      "${locked} ${compose} pull --quiet ${lib.escapeShellArgs pullTargets}";
                in
                ''
                  ${pullCommand}
                  ${locked} ${compose} up -d
                '';
            }
            (registryAuth "-update")
          ]
        );

    systemd.timers."compose-${cfg.stackName}-update" =
      lib.mkIf (cfg.reconcile && cfg.autoUpdate.enable)
        {
          description = "Weekly image update for the ${cfg.stackName} stack (OPS-125)";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.autoUpdate.schedule;
            RandomizedDelaySec = "15m";
            Persistent = true;
          };
        };
  };
}
