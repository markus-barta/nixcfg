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

  generator = pkgs.writeShellApplication {
    name = "hostdash-status";
    runtimeInputs = with pkgs; [
      docker
      systemd
      coreutils
      jq
      mosquitto
      gnugrep
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
      containers="$(docker ps --all --format '{{json .}}' 2>/dev/null \
        | jq -s 'map({
            key: .Names,
            value: {
              running: (.State == "running"),
              state: .State,
              status: .Status,
              health: (
                if   (.Status | test("\\(healthy\\)"))          then "healthy"
                elif (.Status | test("\\(unhealthy\\)"))        then "unhealthy"
                elif (.Status | test("\\(health: starting\\)")) then "starting"
                else null end
              )
            }
          }) | from_entries' 2>/dev/null || echo '{}')"

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

      # --- assemble -----------------------------------------------------------
      jq -n \
        --argjson containers "$containers" \
        --argjson units "$units_json" \
        --argjson extras "$extras" \
        --arg host "${cfg.host}" \
        --argjson generated "$(date +%s)" \
        '{
           schema: "inspr.hostdash.status.v1",
           version: 1,
           host: $host,
           generated: $generated,
           containers: $containers,
           units: $units,
           extras: $extras
         }' > "$TMP"

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

    units = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        systemd units to report. Containers are enumerated automatically, so this is
        only for things systemd owns.

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
  };

  config = lib.mkIf cfg.enable {
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
