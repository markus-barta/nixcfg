# Fleet alert poller — OPS-104 / OPS-103 layer 2.
#
# WHY THIS EXISTS
# ===============
# On 2026-07-25 hsb8 rebooted, Home Assistant started before the resolver
# answered, and its tesla_fleet setup died on a DNS timeout. HA never retries a
# failed config-entry setup, so the parents' Tesla integration was DEAD FOR FOUR
# DAYS. Nobody noticed. It surfaced by accident, while looking at an API bill.
#
# The reason nobody noticed is structural, and no amount of in-HA automation
# fixes it: an alert that lives inside Home Assistant cannot tell you that Home
# Assistant is broken. It cannot tell you the box is off, the disk is full, or
# the container is crash-looping. Something outside has to look in.
#
# It is also the only way to reach Markus from two of the three houses at all.
# hsb8 has no mobile_app registration, hsb9 has no notification channel of any
# kind, so their own alerts can only write to a UI nobody opens. csb0 holds the
# Telegram bot, sits outside both houses, and reaches all three over the tailnet
# — so the alerting belongs here, not there.
#
# WHY NOT UPTIME KUMA (already running on this host)
# ==================================================
# It can express "is the endpoint up" and, with JSON-query monitors, even "is
# this entity unavailable". But that is ~9 hand-clicked monitors across three
# hosts, living only in its database — invisible to review, absent after a
# reinstall, and needing the HA tokens pasted into its UI. This is one
# reviewable file that survives a rebuild.
#
# WHY TRANSITIONS ONLY
# ====================
# A message every 15 minutes about something you already know is a message you
# mute, and a muted alarm is how NIX-135's UPS ran broken for seven weeks. State
# is persisted; only changes are announced — a problem when it starts, a
# recovery when it clears.
{
  config,
  pkgs,
  ...
}:
let
  # Tailnet IPs, not names: MagicDNS is permanently off fleet-wide, and hsb8/hsb9
  # sit on foreign LANs where .lan means nothing. Re-check `tailscale status` if
  # a host is ever replaced.
  #
  # witness = the entity proving the Tesla config entry is loaded. Checked for
  # `unavailable` ONLY. `unknown` is what a healthy but SLEEPING car reports,
  # because tesla_fleet sets updated_once only after a successful vehicle_data
  # fetch — alerting on it would fire permanently on a parked car.
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
      # No Tesla integration here yet (OPS-80 — needs the in-laws present).
      # Still worth polling: this is the only thing that would notice hsb9's
      # Home Assistant being down at all.
      name = "hsb9";
      url = "http://100.64.0.12:8123";
      tokenVar = "HA_TOKEN_HSB9";
    }
  ];

  # The target list is substituted into the script at build time, so the built
  # poller contains literals rather than reading config at runtime. Changing a
  # target is then a rebuild, which is the correct shape for declarative config —
  # and it leaves no runtime data flowing into a request URL.
  pollerPy = pkgs.writeText "ops-alerts-poll.py" (
    builtins.replaceStrings [ "@TARGETS_JSON@" ] [ (builtins.toJSON targets) ] (
      builtins.readFile ./ops-alerts-poll.py
    )
  );
in
{
  systemd.services.ops-alerts = {
    description = "Fleet alert poller — watch all HA instances, report to Telegram (OPS-104)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.python3}/bin/python3 ${pollerPy}";
      # HA tokens + Telegram bot credentials. systemd reads this directly, so the
      # values never pass through a shell or a command line.
      EnvironmentFile = config.age.secrets.csb0-ops-alerts-env.path;
      # Transition state lives here, so a restart does not re-announce old problems.
      StateDirectory = "ops-alerts";
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
      # Not immediately at boot — csb0's network and the tailnet must come up
      # first, or the first run reports the entire fleet down.
      OnBootSec = "5min";
      RandomizedDelaySec = "60";
      Persistent = true;
    };
  };
}
