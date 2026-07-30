# Fleet alert poller — OPS-104, on the shared OPS-107 engine.
#
# WHY THIS EXISTS
# ===============
# On 2026-07-25 hsb8 rebooted, Home Assistant started before the resolver
# answered, and its tesla_fleet setup died on a DNS timeout. HA never retries a
# failed config-entry setup, so the parents' Tesla integration was DEAD FOR FOUR
# DAYS. Nobody noticed. It surfaced by accident, while looking at an API bill.
#
# The reason nobody noticed is structural: an alert that lives inside Home
# Assistant cannot tell you Home Assistant is broken. It also cannot tell you the
# box is off or the container is crash-looping. Something outside has to look in.
#
# It is also the only way to reach Markus from two of the three houses. hsb8 has
# no mobile_app registration and hsb9 no notification channel at all, so their own
# alerts can only write to a UI nobody opens.
#
# WHAT CHANGED IN OPS-107
# =======================
# The durability mechanics now come from modules/shared/fleet-alerts/engine.py,
# adopted from the more mature hausv-alerts poller on csb1 (NIX-332). That fixed
# two real bugs in this poller's first implementation:
#
#   * a failed Telegram send marked the problem announced and never retried, so
#     an alert was silently LOST if the channel was down -- in the very tool built
#     to catch silent failures
#   * state was written with a plain json.dump, so a crash mid-write corrupted it
#     and every existing problem re-announced on the next run
#
# Exit 2 means "could not deliver". SuccessExitStatus keeps 0 and 1 as success, so
# an undeliverable alert deliberately shows up in `systemctl --failed` too.
#
# WHY NOT UPTIME KUMA (it runs on this very host)
# ==============================================
# It can express reachability, and with JSON-query monitors even entity states.
# But that is monitors hand-made in a database: invisible to review, gone after a
# reinstall, with HA tokens pasted into a web form. Both pollers already deliver
# Telegram themselves, so Kuma would add a config surface for no gain.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  fleetLib = import ../../modules/shared/fleet-alerts/lib.nix { inherit pkgs lib; };

  # Tailnet IPs, not names: MagicDNS is permanently off fleet-wide, and hsb8/hsb9
  # sit on foreign LANs where .lan means nothing. Re-check `tailscale status` if a
  # host is ever replaced.
  #
  # witness = the entity proving the Tesla config entry is loaded. Checked for
  # `unavailable` ONLY. `unknown` is what a healthy but SLEEPING car reports,
  # because tesla_fleet sets updated_once only after a successful vehicle_data
  # fetch -- alerting on it would fire permanently on a parked car.
  targets = [
    {
      name = "hsb1";
      url = "http://100.64.0.7:8123";
      tokenVar = "HA_TOKEN_HSB1";
      witness = "binary_sensor.model_x_markus_status";
      budgetEntity = "counter.tesla_x_month";
      budgetLimit = 1920; # 80% of the Model X's 2400/month cap
    }
    {
      name = "hsb8";
      url = "http://100.64.0.3:8123";
      tokenVar = "HA_TOKEN_HSB8";
      witness = "binary_sensor.my_status";
      budgetEntity = "counter.tesla_y_month";
      budgetLimit = 480; # 80% of the Model Y's 600/month cap
    }
    {
      # No Tesla integration here yet (OPS-80 — needs the in-laws present). Still
      # worth polling: this is the only thing that would notice hsb9's Home
      # Assistant being down at all.
      name = "hsb9";
      url = "http://100.64.0.12:8123";
      tokenVar = "HA_TOKEN_HSB9";
    }
  ];

  # csb1's hausv-alerts runs every 5 min; three missed runs before we call it
  # stopped, so a slow cycle or a brief reboot does not page anyone.
  peers = [
    {
      name = "csb1";
      address = "100.64.0.4";
      port = 9107;
      maxAgeSeconds = 15 * 60;
    }
  ];

  poller = fleetLib.mkPoller {
    name = "ops-alerts";
    checks = ./ops-alerts-checks.py;
    substitutions = {
      TARGETS_JSON = builtins.toJSON targets;
      PEERS_JSON = builtins.toJSON peers;
    };
  };
in
{
  nixcfg.fleetAlerts.heartbeat = {
    enable = true;
    statePath = "/var/lib/ops-alerts/state.json";
    tailnetAddress = "100.64.0.8";
  };

  systemd.services.ops-alerts = {
    description = "Fleet alert poller — watch all HA instances, report to Telegram (OPS-104)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.python3}/bin/python3 ${poller}/checks.py";
      # HA tokens + Telegram credentials. systemd reads this directly, so the
      # values never pass through a shell or a command line.
      EnvironmentFile = config.age.secrets.csb0-ops-alerts-env.path;
      StateDirectory = "ops-alerts";
      StateDirectoryMode = "0700";
      # 0 = clean, 1 = problems found (both are a successful RUN); 2 = could not
      # deliver, which must fail the unit so it is visible in systemctl --failed.
      SuccessExitStatus = [
        0
        1
      ];
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      NoNewPrivileges = true;
      TimeoutStartSec = "180";
    };
  };

  systemd.timers.ops-alerts = {
    description = "Fleet alert poller schedule (OPS-104)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # 15 min: fast enough that a dead integration is caught within the hour,
      # slow enough to stay quiet.
      OnCalendar = "*:0/15";
      # Not immediately at boot — the network and tailnet must come up first, or
      # the first run reports the entire fleet down.
      OnBootSec = "5min";
      RandomizedDelaySec = "60";
      Persistent = true;
    };
  };
}
