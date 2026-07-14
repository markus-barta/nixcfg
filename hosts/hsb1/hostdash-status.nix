# HostDash runtime status artifact — NIX-280.
#
# WHY
# ===
# HostDash cannot currently tell whether a service is RUNNING. Its only signal is a
# browser-side `fetch(url, { mode: "no-cors" })`, which returns an OPAQUE response:
# the status code, headers and body are unreadable by design, and `.then()` fires
# merely because the request did not network-error. So:
#
#   * a service returning HTTP 500          -> shown UP
#   * Scrypted's self-signed cert fails TLS -> shown DOWN (it is running)
#   * running but not on the browser's path -> shown DOWN
#   * 9 of 19 services on hsb1 have no HTTP endpoint AT ALL -> never probed
#
# So roughly half the dashboard displays a state it never measured. That is the same
# failure class as NIX-151 — the babycam that showed a perfect picture while producing
# no sound. A monitor that reports health it cannot verify is worse than no monitor,
# because it is trusted.
#
# `running` and `reachable` can NEVER be known client-side. They require the host to
# say so. This module is the host saying so.
#
# WHY SAME-ORIGIN
# ===============
# The dashboard is already served by an nginx container (`hsb1-home`). Publishing the
# status as a file NEXT TO index.html means the fetch is same-origin, so the response
# is FULLY READABLE — no CORS, no opaque responses. A cross-origin status endpoint
# would land us right back where we started.
#
# The app's own directory is an immutable /nix/store path, so this cannot be written
# into it. Instead the generator writes to ${statusDir}, which docker-compose mounts
# read-only at /usr/share/nginx/html/status -> served at  ./status/status.json
#
# FRESHNESS IS PART OF THE CONTRACT
# =================================
# `generated` is emitted on every write. HostDash MUST treat a stale timestamp as
# UNKNOWN, never as healthy — a status file that keeps reading "green" after the
# generator dies would recreate precisely the bug this exists to kill.
{
  pkgs,
  lib,
  ...
}:
let
  statusDir = "/var/lib/hostdash-status";

  # systemd units worth reporting. Containers are enumerated automatically (see the
  # generator) — this list is only for things systemd owns.
  units = [
    "babycam-watchdog.timer" # NIX-151 — the babycam's guardian
    "mqtt-volume-control.service"
    "apc-to-mqtt.timer"
    "docker.service"
    "sshd.service"
    "zfs-scrub-media.timer"
    "zfs-scrub-tm.timer"

    # Declared on the HostDash board as "FleetCom — Heartbeats to fleet.barta.cm",
    # but there is no such unit on hsb1 and the nixfleet-agent import in
    # configuration.nix is commented out. It is NOT running, and nobody noticed —
    # because a `passive: true` card never claims a state, it is merely drawn.
    #
    # Reported deliberately, so the board has to answer for its own claim: the card
    # will read "Stopped" until the agent is actually deployed here or the card is
    # removed. A dashboard that lists services which do not exist is the same lie in
    # a different costume. (Found 2026-07-14 while wiring up host truth.)
    "nixfleet-agent.service"
  ];

  generator = pkgs.writeShellApplication {
    name = "hostdash-status";
    runtimeInputs = with pkgs; [
      docker
      systemd
      coreutils
      jq
      mosquitto # retained babycam health
      gnugrep
    ];
    text = ''
      OUT="${statusDir}/status.json"
      TMP="$(mktemp "${statusDir}/.status.XXXXXX")"
      trap 'rm -f "$TMP"' EXIT

      # --- containers ---------------------------------------------------------
      # `docker ps` is the ground truth the browser can never see. This alone
      # recovers 7 of the 9 services that have no HTTP endpoint and were therefore
      # never probed at all (mosquitto, matter-server, watchtower, restic,
      # pharos-beacon, smtp, opus-stream-to-mqtt).
      #
      # Health is reported separately from running: a container can be Up while its
      # healthcheck is failing, and collapsing those two into one boolean is how a
      # dashboard starts lying.
      containers="$(docker ps --all --format '{{json .}}' 2>/dev/null \
        | jq -s 'map({
            key: .Names,
            value: {
              running: (.State == "running"),
              state: .State,
              status: .Status,
              health: (
                if   (.Status | test("\\(healthy\\)"))   then "healthy"
                elif (.Status | test("\\(unhealthy\\)")) then "unhealthy"
                elif (.Status | test("\\(health: starting\\)")) then "starting"
                else null end
              )
            }
          }) | from_entries' 2>/dev/null || echo '{}')"

      # --- systemd units ------------------------------------------------------
      units_json="{}"
      for u in ${lib.concatStringsSep " " units}; do
        active="$(systemctl is-active "$u" 2>/dev/null || true)"
        enabled="$(systemctl is-enabled "$u" 2>/dev/null || true)"
        units_json="$(jq -c \
          --arg u "$u" --arg a "''${active:-unknown}" --arg e "''${enabled:-unknown}" \
          '. + {($u): {running: ($a == "active" or $a == "activating"), active: $a, enabled: $e}}' \
          <<<"$units_json")"
      done

      # --- babycam health (NIX-151) -------------------------------------------
      # Retained, so this returns immediately. The richest health signal on the host:
      # decoder counters proving frames and audio are genuinely MOVING, not a socket
      # poke. Deliberately passed through verbatim — including `desired_volume: 0`,
      # which is a NORMAL nightly state (muted on purpose, door open) and must NOT be
      # rendered as a fault. See HOSTD-10.
      babycam="null"
      bc="$(
        set -a
        # shellcheck source=/dev/null  # agenix-materialized, absent at lint time
        . /run/agenix/hsb1-mqtt-client-env
        set +a
        timeout 5 mosquitto_sub -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASS" \
          -t 'home/hsb1/babycam/health' -C 1 -W 3 2>/dev/null || true
      )"
      if [ -n "$bc" ] && jq -e . >/dev/null 2>&1 <<<"$bc"; then
        babycam="$bc"
      fi

      # --- assemble -----------------------------------------------------------
      jq -n \
        --argjson containers "$containers" \
        --argjson units "$units_json" \
        --argjson babycam "$babycam" \
        --arg host "hsb1" \
        --argjson generated "$(date +%s)" \
        '{
           schema: "inspr.hostdash.status.v1",
           version: 1,
           host: $host,
           generated: $generated,
           containers: $containers,
           units: $units,
           extras: { babycam: $babycam }
         }' > "$TMP"

      # Atomic swap: nginx must never serve a half-written file.
      chmod 0644 "$TMP"
      mv -f "$TMP" "$OUT"
      trap - EXIT
    '';
  };
in
{
  systemd.services.hostdash-status = {
    description = "Generate the HostDash runtime status artifact (NIX-280)";
    after = [ "docker.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe generator;
      # root: needs the docker socket, and reads the agenix MQTT env.
      User = "root";
      StateDirectory = "hostdash-status";
      StateDirectoryMode = "0755"; # nginx (in its container) reads this
      TimeoutStartSec = "60s";
    };
  };

  # Serving config for the hsb1-home nginx container. Lives here (not baked into the
  # HostDash package) because it is deployment topology, not app content: it is what
  # aliases the status artifact back under the app's own origin.
  environment.etc."hostdash-nginx.conf".source = ./files/hostdash-nginx.conf;

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
}
# The artifact is consumed by hosts/hsb1/docker/docker-compose.yml (hsb1-home), which
# mounts ${statusDir} read-only at /usr/share/nginx/html/status.
