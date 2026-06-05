# IR → Sony TV bridge — FLIRC receiver returned to hsb1
#
# The FLIRC USB IR receiver originally lived on hsb1 (the hsb2 Pi-Zero was an
# experiment to move it off). It is coming back: this reuses the *proven*
# ir-bridge.py VERBATIM (nix-store reference to the hsb2-era file) — it reads the
# FLIRC's evdev keypresses and POSTs Sony IRCC commands over HTTP to the Bravia
# (192.168.1.137). Hardware is enabled via `hardware.flirc.enable` in
# configuration.nix.
#
# TEST PLAN (zero new hardware):
#   1. `just switch` hsb1 — the service installs and retries every 5s, waiting
#      for the FLIRC device (it is still on hsb2, so it just loops harmlessly).
#   2. Physically move the FLIRC: unplug from hsb2 → plug into hsb1.
#   3. Within ~5s the service opens /dev/flirc; press remote buttons → TV reacts.
#   ROLLBACK: plug the FLIRC back into hsb2 (its service still runs). Zero risk.
#
# TODO (after the test passes + hsb2 is retired): `git mv` the script into
# hosts/hsb1/files/ir-bridge.py and update the ExecStart path below.
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
  # SONY_TV_PSK (+ optional MQTT creds) — decrypted to /run/agenix/hsb1-ir-bridge-env
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
      MQTT_BROKER = ""; # debug disabled (was rc=5 spam vs authed mosquitto); set broker+creds to re-enable
      MQTT_TOPIC = "home/hsb1/ir-bridge";
      LOG_LEVEL = "INFO";
    };
    serviceConfig = {
      Type = "simple";
      User = "mba";
      SupplementaryGroups = [ "input" ]; # read /dev/input/*
      EnvironmentFile = config.age.secrets.hsb1-ir-bridge-env.path;
      # Proven script, reused as-is from the hsb2 era (nix-store reference).
      ExecStart = "${pythonEnv}/bin/python3 ${../hsb2/files/ir-bridge.py}";
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
