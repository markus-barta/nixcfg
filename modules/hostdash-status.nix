# HostDash runtime status artifact — shared module (NIX-280).
#
# WHY THIS EXISTS
# ===============
# HostDash's only status signal used to be a browser `fetch(url, {mode:"no-cors"})`.
# That response is OPAQUE by design — status code, headers and body all unreadable —
# and `.then()` fires merely because the request did not network-error. So:
#
#   * a service returning HTTP 500          -> shown "Online"
#   * a self-signed cert (Scrypted)         -> shown "Down", while running fine
#   * running, but not on the browser's path-> shown "Down"
#   * no HTTP endpoint at all               -> never probed; 9 of 19 services on hsb1
#
# Roughly half the board displayed a state nobody had measured. That is the same
# failure class as the babycam that showed a perfect picture and made no sound
# (NIX-151): a monitor reporting health it cannot verify is worse than no monitor,
# because it is trusted.
#
# Whether a service is RUNNING cannot be known client-side. Ever. So the HOST says so,
# and this module is the host saying it.
#
# SAME-ORIGIN OR NOTHING
# ======================
# The artifact must be served from the SAME ORIGIN as index.html, or the browser gets
# an opaque response again and we have achieved nothing. The dashboard is already
# served by an nginx container per host; this mounts the artifact beside it.
#
# NOT into the app directory, though: that is an immutable /nix/store bind mount, and
# Docker cannot create a mountpoint inside a read-only mount —
#     mkdirat .../usr/share/nginx/html/status: read-only file system
# which leaves the container stuck in `Created` and the dashboard offline (learned the
# hard way on hsb1, 2026-07-14). Hence: mount outside the app root, and let nginx
# `alias` it back under the same origin. See ./files/hostdash-nginx.conf.
#
# FRESHNESS IS PART OF THE CONTRACT
# =================================
# `generated` is written every cycle. HostDash treats an artifact older than a few
# minutes as UNKNOWN, never as healthy. A dead generator whose last file still says
# "running" would leave the board green forever — the same bug, one layer down.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.hostdash.status;
  statusDir = "/var/lib/hostdash-status";
  containerStatusFilter = ./files/hostdash-container-status.jq;
  containerNames = if cfg.containers == null then [ ] else cfg.containers;
  runtimeKeys = containerNames ++ cfg.units ++ builtins.attrNames cfg.mqttExtras;
  extraNames = builtins.attrNames cfg.mqttExtras;
  duplicates =
    names:
    lib.unique (builtins.filter (name: lib.count (candidate: candidate == name) names > 1) names);
  crossKindCollisions = lib.unique (
    builtins.filter (name: builtins.elem name cfg.units || builtins.elem name extraNames) containerNames
    ++ builtins.filter (name: builtins.elem name extraNames) cfg.units
  );
  validRuntimeName = name: builtins.match "^[A-Za-z0-9_.-]+$" name != null;

  httpProbe = pkgs.writeShellApplication {
    name = "hostdash-http-probe";
    runtimeInputs = with pkgs; [
      curl
      jq
    ];
    text = builtins.readFile ./files/hostdash-http-probe.sh;
  };

  containerCollector = pkgs.writeShellApplication {
    name = "hostdash-container-status";
    runtimeInputs = with pkgs; [
      docker
      jq
    ];
    text = ''
      # Immutable repository helper.
      # shellcheck source=/dev/null
      source ${./files/hostdash-container-status.sh}
      hostdash_collect_containers "$@"
    '';
  };

  generator = pkgs.writeShellApplication {
    name = "hostdash-status";
    runtimeInputs = with pkgs; [
      systemd
      coreutils
      jq
      mosquitto
      gnugrep
      httpProbe
      containerCollector
    ];
    text = ''
      OUT="${statusDir}/status.json"
      TMP="$(mktemp "${statusDir}/.status.XXXXXX")"
      trap 'rm -f "$TMP"' EXIT

      # --- containers ---------------------------------------------------------
      # `docker ps` is ground truth the browser can never see. On hsb1 this alone
      # recovers 7 of the 9 services that have no HTTP endpoint and so were never
      # checked at all — merely drawn.
      #
      # `running` and `health` stay SEPARATE fields: a container can be Up while its
      # healthcheck is failing, and collapsing those into one boolean is how a
      # dashboard starts lying.
      containers="$(hostdash-container-status \
        ${lib.escapeShellArg (builtins.toJSON cfg.containers)} \
        ${containerStatusFilter})"

      # --- systemd units ------------------------------------------------------
      units_json="{}"
      for u in ${lib.concatStringsSep " " cfg.units}; do
        active="$(systemctl is-active "$u" 2>/dev/null || true)"
        enabled="$(systemctl is-enabled "$u" 2>/dev/null || true)"
        units_json="$(jq -c \
          --arg u "$u" --arg a "''${active:-unknown}" --arg e "''${enabled:-unknown}" \
          '. + {($u): {running: ($a == "active" or $a == "activating"), active: $a, enabled: $e}}' \
          <<<"$units_json")"
      done

      # --- extras: retained MQTT topics ---------------------------------------
      # Richer, service-specific health than any socket poke — e.g. hsb1's babycam
      # publishes decoder counters proving frames and audio are genuinely MOVING.
      # Passed through VERBATIM: interpretation belongs to whoever renders it, not
      # here. (Notably `desired_volume: 0` is a normal, deliberate state — see
      # NIX-151 — and must not be mangled into a fault on the way past.)
      extras="{}"
      ${lib.optionalString (cfg.mqttEnvFile != null) ''
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: topic: ''
            val="$(
              set -a
              # shellcheck source=/dev/null  # agenix-materialized, absent at lint time
              . ${cfg.mqttEnvFile}
              set +a
              timeout 5 mosquitto_sub -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASS" \
                -t '${topic}' -C 1 -W 3 2>/dev/null || true
            )"
            if [ -n "$val" ] && jq -e . >/dev/null 2>&1 <<<"$val"; then
              extras="$(jq -c --arg k '${name}' --argjson v "$val" '. + {($k): $v}' <<<"$extras")"
            else
              extras="$(jq -c --arg k '${name}' '. + {($k): null}' <<<"$extras")"
            fi
          '') cfg.mqttExtras
        )}
      ''}

      # --- host-side HTTP checks (NIX-343) -----------------------------------
      # Browser no-cors probes cannot read status codes. Probe the service over
      # loopback so this measures application health rather than the viewer's
      # network path; the helper is bounded and maps no response to code 0.
      http_json="{}"
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (key: url: ''
          probe="$(hostdash-http-probe ${lib.escapeShellArg url})"
          http_json="$(
            jq -c --arg key ${lib.escapeShellArg key} --argjson probe "$probe" \
              '. + {($key): $probe}' <<<"$http_json"
          )"
        '') cfg.httpProbes
      )}

      # --- assemble -----------------------------------------------------------
      jq -n \
        --argjson containers "$containers" \
        --argjson units "$units_json" \
        --argjson extras "$extras" \
        --argjson http "$http_json" \
        --arg host "${cfg.host}" \
        --argjson generated "$(date +%s)" \
        '({
           schema: "inspr.hostdash.status.v1",
           version: 1,
           host: $host,
           generated: $generated,
           containers: $containers,
           units: $units,
           extras: $extras
         } + (if ($http | length) > 0 then { http: $http } else { } end))' > "$TMP"

      # Atomic swap — nginx must never serve a half-written file.
      chmod 0644 "$TMP"
      mv -f "$TMP" "$OUT"
      trap - EXIT
    '';
  };
in
{
  options.services.hostdash.status = {
    enable = lib.mkEnableOption "the HostDash runtime status artifact (NIX-280)";

    host = lib.mkOption {
      type = lib.types.str;
      description = "Host name stamped into the artifact.";
      example = "hsb1";
    };

    containers = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = ''
        Docker container names to publish. Set an explicit list for new boards so
        unrelated or deliberately absent services never become permanent status
        noise. Null preserves the original enumerate-all behavior for existing
        deployments until their card inventories are migrated deliberately.
      '';
      example = [
        "homeassistant"
        "mosquitto"
      ];
    };

    units = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        systemd units to report. Container status comes from Docker (optionally
        restricted by containers), so this is only for things systemd owns.

        Do NOT list units that are *meant* to be absent: a unit reported as permanently
        "Stopped" is noise, not signal. (FleetCom was listed here briefly before we
        established it had been decommissioned fleet-wide; the right fix was deleting
        its dashboard cards, not reporting its corpse.)
      '';
      example = [ "sshd.service" ];
    };

    mqttEnvFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Env file with MQTT_HOST/MQTT_USER/MQTT_PASS, sourced (never printed).";
    };

    mqttExtras = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra health blobs to fold in, as name -> retained MQTT topic.";
      example = {
        babycam = "home/hsb1/babycam/health";
      };
    };

    httpProbes = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Services to check over HTTP from the host, as container or unit name to
        loopback URL. URLs must use 127.0.0.1: the probe measures the service,
        not the viewer's network path. Self-signed loopback TLS is accepted.
      '';
      example = {
        scrypted = "https://127.0.0.1:10443/";
        homeassistant = "http://127.0.0.1:8123/";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.containers == null || duplicates cfg.containers == [ ];
        message = "services.hostdash.status.containers must not contain duplicates";
      }
      {
        assertion = duplicates cfg.units == [ ];
        message = "services.hostdash.status.units must not contain duplicates";
      }
      {
        assertion = builtins.all validRuntimeName runtimeKeys;
        message = "services.hostdash.status runtime keys must match ^[A-Za-z0-9_.-]+$";
      }
      {
        assertion = crossKindCollisions == [ ];
        message = "services.hostdash.status container, unit, and extra keys must be distinct";
      }
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (key: url: [
        {
          assertion = builtins.match "^[A-Za-z0-9_.-]+$" key != null;
          message = "services.hostdash.status.httpProbes keys must be container or unit names";
        }
        {
          assertion = builtins.match "^https?://127\\.0\\.0\\.1(:[0-9]+)?(/.*)?$" url != null;
          message = "services.hostdash.status.httpProbes.${key} must use an http://127.0.0.1 or https://127.0.0.1 URL";
        }
        {
          assertion = cfg.containers == null || builtins.elem key runtimeKeys;
          message = "services.hostdash.status.httpProbes.${key} must reference a declared container, unit, or extra";
        }
      ]) cfg.httpProbes
    );

    systemd.services.hostdash-status = {
      description = "Generate the HostDash runtime status artifact (NIX-280)";
      after = [ "docker.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe generator;
        User = "root"; # needs the docker socket, and reads the agenix MQTT env
        StateDirectory = "hostdash-status";
        StateDirectoryMode = "0755"; # nginx reads this from inside its container
        TimeoutStartSec = "60s";
      };
    };

    systemd.timers.hostdash-status = {
      description = "Refresh the HostDash status artifact every minute";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "60s";
        AccuracySec = "10s";
        Unit = "hostdash-status.service";
      };
    };

    # Serving config for the per-host nginx container. Lives in nixcfg rather than in
    # the HostDash package because it is deployment topology, not app content.
    environment.etc."hostdash-nginx.conf".source = ./files/hostdash-nginx.conf;
  };
}
