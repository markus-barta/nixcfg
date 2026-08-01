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
        this to the repo checkout to preserve today's resolution without
        rewriting paths. hsb1 needs no value: it has zero relative paths.

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
    ];

    nixcfg.composeStack.stackName = lib.mkDefault cfg.project;

    environment.etc."compose/${cfg.stackName}/docker-compose.yml".source = composeFile;

    systemd.services."compose-${cfg.stackName}" = lib.mkIf cfg.reconcile {
      description = "Reconcile the ${cfg.stackName} container stack with the system closure (OPS-116)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "docker.service"
        "network-online.target"
      ];
      requires = [ "docker.service" ];
      wants = [ "network-online.target" ];

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
      script =
        let
          compose = "${pkgs.docker-compose}/bin/docker-compose -p ${lib.escapeShellArg cfg.project} -f ${composeFile} ${projectDirFlag}";
        in
        ''
          ${compose} up -d${lib.optionalString cfg.removeOrphans " --remove-orphans"}
        ''
        + lib.concatMapStrings (svc: ''
          ${compose} up -d --force-recreate --no-deps ${lib.escapeShellArg svc}
        '') cfg.postRecreate;
    };
  };
}
