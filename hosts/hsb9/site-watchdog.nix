# OPS-165: hsb9 site watchdog — GX + FRITZ repeaters via Uptime Kuma push.
#
# Why: the Victron GX was offline for 5 DAYS before anyone noticed (OPS-164) —
# nothing monitors this site's LAN appliances, and Kuma (csb0, uptime.barta.cm)
# cannot reach this LAN directly. Push model: this host probes locally and
# heartbeats the cloud Kuma; a MISSING heartbeat also covers "hsb9 itself is
# down", which a pull model could not.
#
# Targets are site-local appliance IPs. FritzBox DHCP reservations are
# required for all four (the GX is additionally pinned by IP inside the HA
# victron_gx integration — an IP change there is the next silent outage):
#   .222  FRITZ!Repeater 1610 Outdoor
#   .223  FRITZ!Repeater 1200 AX v2   (survived the 2026-08 outage)
#   .228  FRITZ!Repeater 1200 AX v2
#   .233  Victron GX — ping + MQTT :1883, the HA integration's actual dependency
# Which physical room each 1200 AX serves (EG/Keller/TG) is unconfirmed; see
# OPS-164 for the incident that motivated all of this.
{ config, pkgs, ... }:
let
  watchdog = pkgs.writeShellApplication {
    name = "hsb9-site-watchdog";
    runtimeInputs = [
      pkgs.curl
      pkgs.iputils
      pkgs.coreutils
      pkgs.bash
    ];
    text = ''
      fails=()

      probe() {
        ping -c 2 -W 2 "$2" > /dev/null 2>&1 || fails+=("$1")
      }

      probe rp-1610-outdoor 192.168.1.222
      probe rp-ax-223       192.168.1.223
      probe rp-ax-228       192.168.1.228
      probe gx              192.168.1.233

      # MQTT is what HA actually depends on — TCP connect, value never read.
      if ! timeout 3 bash -c 'echo > /dev/tcp/192.168.1.233/1883' 2> /dev/null; then
        fails+=(gx-mqtt)
      fi

      if [ "''${#fails[@]}" -eq 0 ]; then
        curl -fsS --max-time 10 "''${KUMA_PUSH_URL}?status=up&msg=ok" > /dev/null
      else
        msg=$(IFS=,; echo "''${fails[*]}")
        curl -fsS --max-time 10 "''${KUMA_PUSH_URL}?status=down&msg=''${msg}" > /dev/null
      fi
    '';
  };
in
{
  # Push URL (contains the monitor token — low blast radius, can only push
  # status, but agenix per doctrine). Content: KUMA_PUSH_URL=https://…/api/push/<token>
  age.secrets.hsb9-kuma-push-env = {
    file = ../../secrets/hsb9-kuma-push-env.age;
    path = "/run/agenix/hsb9-kuma-push-env";
    owner = "root";
    group = "root";
    mode = "0400";
  };

  systemd.services.hsb9-site-watchdog = {
    description = "Probe site appliances (GX + repeaters), heartbeat Uptime Kuma";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = config.age.secrets.hsb9-kuma-push-env.path;
      ExecStart = "${watchdog}/bin/hsb9-site-watchdog";
    };
  };

  # Every 5 min; Kuma monitor expects a 300 s heartbeat (+ grace). No
  # Persistent=true — a missed window during downtime SHOULD read as down.
  systemd.timers.hsb9-site-watchdog = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/5";
      RandomizedDelaySec = 30;
    };
  };
}
