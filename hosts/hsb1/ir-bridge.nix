# IR → {Sony Bravia, Home Assistant} bridge — FLIRC receiver on hsb1
#
# The FLIRC USB IR receiver reads the physical remote; ir-bridge.py drives two
# independent paths (see hosts/hsb1/files/ir-bridge.py for the full design):
#   1. FAST PATH  — direct Sony IRCC over HTTP to the Bravia (192.168.1.137) for
#      real TV keys; HA-independent, instant.
#   2. SMART PATH — publishes every keypress to MQTT and advertises the remote to
#      Home Assistant via MQTT Discovery (device triggers). HA owns the "smart"
#      keys: Hue Sync Box input (blue/yellow) + pixdcon scene toggle (tv_radio).
#
# Hardware enabled via `hardware.flirc.enable` in configuration.nix; device via
# the stable /dev/input/by-id path (hsb1 also has the built-in Apple IR receiver,
# so a bare event<N> would be ambiguous). Button map captured live → PPM NIX-194.
{
  config,
  pkgs,
  ...
}:
let
  # hsb1 already ships this python set in systemPackages; a dedicated env keeps
  # the service self-contained and independent of that list.
  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.evdev
    ps.paho-mqtt
    ps.requests
  ]);
in
{
  # SONY_TV_PSK + MQTT_USER/MQTT_PASS — decrypted to /run/agenix/hsb1-ir-bridge-env
  age.secrets.hsb1-ir-bridge-env = {
    file = ../../secrets/hsb1-ir-bridge-env.age;
    owner = "mba";
    mode = "0400";
  };

  # The FLIRC keyboard event device is reached via its stable /dev/input/by-id
  # path (udev creates it automatically) — see FLIRC_DEVICE below. hsb1 also has
  # the built-in Apple IR receiver, so a bare event<N> path would be ambiguous.
  systemd.services.ir-bridge = {
    description = "IR to Sony TV Bridge (FLIRC -> Bravia IRCC over HTTP)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    wants = [ "network.target" ];
    environment = {
      PYTHONUNBUFFERED = "1";
      SONY_TV_IP = "192.168.1.137";
      FLIRC_DEVICE = "/dev/input/by-id/usb-flirc.tv_flirc-if01-event-kbd"; # stable by-id path
      # Smart path → Home Assistant. Broker is localhost (never a hostname — HA
      # MQTT rule); MQTT_USER / MQTT_PASS come from the agenix EnvironmentFile.
      MQTT_BROKER = "127.0.0.1";
      MQTT_PORT = "1883";
      MQTT_BASE_TOPIC = "home/hsb1/ir-bridge";
      HA_DISCOVERY_PREFIX = "homeassistant";
      DEVICE_ID = "flirc_hsb1";
      LOG_LEVEL = "INFO";
    };
    serviceConfig = {
      Type = "simple";
      User = "mba";
      SupplementaryGroups = [ "input" ]; # read /dev/input/*
      EnvironmentFile = config.age.secrets.hsb1-ir-bridge-env.path;
      # Bridge script lives with its host (git mv from hsb2 → hsb1, NIX-194).
      ExecStart = "${pythonEnv}/bin/python3 ${./files/ir-bridge.py}";
      Restart = "always";
      RestartSec = 5;
      # Reactivity: pin above normal priority so a keypress is handled instantly
      # regardless of hsb1's other load (HA / Zigbee2MQTT / docker). The service is
      # event-driven (~0% CPU idle); this just guarantees it preempts background work.
      Nice = -10;
      IOSchedulingClass = "best-effort";
      IOSchedulingPriority = 0;
      # Light hardening — needs /dev/input, so NO PrivateDevices.
      NoNewPrivileges = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
    };
  };
}
