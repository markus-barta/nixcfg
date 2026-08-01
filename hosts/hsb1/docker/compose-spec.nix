# hsb1 container stack — the compose spec, authored in Nix (OPS-116 / OPS-118).
#
# Replaces hosts/hsb1/docker/docker-compose.yml. Rendered into the closure and
# reconciled at switch by modules/shared/compose-stack, so a resolver-policy
# change can no longer strand a running container the way it did on 2026-07-29
# (OPS-113 — the access gate, dead two days).
#
# 🔴 `dns` / `dns_search` MUST NOT appear here. The module injects them from
# config.networking.nameservers into every network_mode: host service. Writing
# them by hand is the OPS-114 duplication coming back, and the module asserts
# against it.
#
# 🔴 The compose project is "docker", NOT "hsb1" — this file never carried a
# `name:` key, so compose derived the project from the containing directory.
# The named volume docker_opus-stream-app (the OPUS→MQTT bridge's node_modules
# cache) depends on it. Verified on the live host 2026-08-01.
#
# Verify any change with:
#   nix shell nixpkgs#yq-go -c ./tests/compose_stack_gate.py hsb1
# Comments from the source file are NOT carried across by this tool; re-attach
# them by hand. They hold real incident history.
#
# Dropped (now supplied by the composeStack module):
#   pixdcon.dns = ['192.168.1.99', '1.1.1.1']
#   pixdcon.dns_search = ['lan']
#   funkeykid.dns = ['192.168.1.99', '1.1.1.1']
#   funkeykid.dns_search = ['lan']
#   homeassistant.dns = ['192.168.1.99', '1.1.1.1']
#   homeassistant.dns_search = ['lan']
#   scrypted.dns = ['192.168.1.99', '1.1.1.1']
#   scrypted.dns_search = ['lan']
#   matter-server.dns = ['192.168.1.99', '1.1.1.1']
#   matter-server.dns_search = ['lan']
#   opus-stream-to-mqtt.dns = ['192.168.1.99', '1.1.1.1']
#   opus-stream-to-mqtt.dns_search = ['lan']
#   nodered.dns = ['192.168.1.99', '1.1.1.1']
#   nodered.dns_search = ['lan']
#   plex.dns = ['192.168.1.99', '1.1.1.1']
#   plex.dns_search = ['lan']
#   pharos-beacon.dns = ['192.168.1.99', '1.1.1.1']
#   pharos-beacon.dns_search = ['lan']
#   x-host-dns (anchor)
#   x-host-dns-search (anchor)

{
  services = {
    zigbee2mqtt = {
      container_name = "zigbee2mqtt";
      depends_on = [
        "mosquitto"
      ];
      image = "koenkk/zigbee2mqtt:latest";
      volumes = [
        "/home/mba/docker/mounts/zigbee2mqtt:/app/data"
      ];
      restart = "unless-stopped";
      ports = [
        "8888:8888"
      ];
      environment = [
        "TZ=Europe/Vienna"
      ];
      env_file = [
        "/run/agenix/hsb1-zigbee2mqtt-env"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=true"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    pixdcon = {
      image = "ghcr.io/markus-barta/pixdcon:latest";
      container_name = "pixdcon";
      network_mode = "host";
      restart = "unless-stopped";
      environment = [
        "TZ=Europe/Vienna"
        "MQTT_PORT=1883"
        "LOG_LEVEL=info"
        "PIXDCON_CONFIG_PATH=/data/config.json"
      ];
      env_file = [
        "/run/agenix/hsb1-pixdcon-env"
      ];
      volumes = [
        "/home/mba/docker/mounts/pixdcon/config.json:/data/config.json"
        "/home/mba/docker/mounts/pixdcon/scenes:/data/scenes"
        "/home/mba/docker/mounts/pixdcon/generated-scenes:/data/generated-scenes"
        "/home/mba/docker/mounts/funkeykid/images:/app/assets/pixoo/funkeykid:ro"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=true"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    funkeykid = {
      image = "ghcr.io/markus-barta/funkeykid:latest";
      container_name = "funkeykid";
      network_mode = "host";
      restart = "unless-stopped";
      privileged = true;
      environment = [
        "TZ=Europe/Vienna"
        "XDG_RUNTIME_DIR=/run/user/1001"
        "PULSE_SERVER=unix:/run/user/1001/pulse/native"
        "DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket"
      ];
      env_file = [
        "/run/agenix/hsb1-smarthome-env"
        "/run/agenix/hsb1-funkeykid-api-env"
      ];
      volumes = [
        "/home/mba/docker/mounts/funkeykid/settings.json:/data/settings.json"
        "/home/mba/docker/mounts/funkeykid/sounds:/data/sounds"
        "/home/mba/docker/mounts/funkeykid/images:/data/images"
        "/home/mba/docker/mounts/funkeykid/ai-generated:/data/ai-generated"
        "/dev/input:/dev/input"
        "/run/user/1001:/run/user/1001"
        "/run/dbus:/run/dbus"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=true"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    homeassistant = {
      container_name = "homeassistant";
      image = "ghcr.io/home-assistant/home-assistant:stable";
      volumes = [
        "/home/mba/docker/mounts/homeassistant:/config"
        "/etc/localtime:/etc/localtime:ro"
        "/run/dbus:/run/dbus:ro"
      ];
      restart = "unless-stopped";
      privileged = true;
      network_mode = "host";
      env_file = [
        "/run/agenix/hsb1-smarthome-env"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=true"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    scrypted = {
      image = "ghcr.io/koush/scrypted";
      container_name = "scrypted";
      restart = "unless-stopped";
      network_mode = "host";
      environment = [
        "TZ=Europe/Vienna"
        "SCRYPTED_WEBHOOK_UPDATE=http://localhost:10444/v1/update"
        "SCRYPTED_UNMANAGED_PLUGINS_SCAN=false"
      ];
      volumes = [
        "/home/mba/docker/mounts/scrypted/volume:/server/volume"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=true"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
      env_file = [
        "/run/agenix/hsb1-tapo-c210-env"
      ];
    };
    smtp = {
      image = "namshi/smtp";
      restart = "unless-stopped";
      environment = [
        "TZ=Europe/Vienna"
        "SMARTHOST_ADDRESS=mail.hover.com"
        "SMARTHOST_PORT=587"
        "SMARTHOST_USER=markus@barta.com"
        "SMARTHOST_ALIASES=*"
        "RELAY_NETWORKS=:172.0.0.0/8"
      ];
      env_file = [
        "/run/agenix/hsb1-smtp-env"
      ];
      labels = [
        "traefik.enable=false"
        "com.centurylinklabs.watchtower.enable=true"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    matter-server = {
      image = "ghcr.io/home-assistant-libs/python-matter-server:stable";
      container_name = "matter-server";
      restart = "unless-stopped";
      network_mode = "host";
      security_opt = [
        "apparmor:unconfined"
      ];
      volumes = [
        "/home/mba/docker/mounts/matter-server:/data"
        "/run/dbus:/run/dbus:ro"
      ];
      environment = [
        "TZ=Europe/Vienna"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=true"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    mosquitto = {
      image = "eclipse-mosquitto:latest";
      container_name = "mosquitto";
      restart = "unless-stopped";
      ports = [
        "1883:1883"
        "9001:9001"
      ];
      volumes = [
        "/run/agenix/hsb1-mosquitto-conf:/mosquitto/config/mosquitto.conf:ro"
        "/run/agenix/hsb1-mosquitto-passwd:/mosquitto/config/mosquitto_passwd:ro"
        "/home/mba/docker/mounts/mosquitto/var/run:/var/run"
        "/home/mba/docker/mounts/mosquitto/data:/mosquitto/data"
        "/home/mba/docker/mounts/mosquitto/log:/mosquitto/log"
      ];
      logging = {
        driver = "json-file";
        options = {
          max-size = "10m";
          max-file = "3";
        };
      };
      labels = [
        "com.centurylinklabs.watchtower.enable=true"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    apprise = {
      image = "caronc/apprise:latest";
      container_name = "apprise";
      restart = "unless-stopped";
      ports = [
        "8001:8000"
      ];
      volumes = [
        "/home/mba/docker/mounts/apprise/config:/config"
        "/home/mba/docker/mounts/apprise/etc/nginx/sites-available/default:/etc/nginx/sites-available/default"
        "/tmp:/tmp"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=true"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    restic-cron-hetzner = {
      build = "/home/mba/docker/restic-cron";
      container_name = "restic-cron-hetzner";
      restart = "unless-stopped";
      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "/home:/backup/home:ro"
        "/root:/backup/root:ro"
        "/etc:/backup/etc:ro"
        "/run/agenix/hsb1-restic-ssh-key:/root/.ssh/id_rsa:ro"
        "/home/mba/docker/restic-cron/ssh_known_hosts:/root/.ssh/known_hosts:ro"
        "/home/mba/docker/restic-cron/hetzner/run_backup.sh:/usr/local/bin/run_backup.sh:ro"
        "/home/mba/docker/restic-cron/hetzner/run_check.sh:/usr/local/bin/run_check.sh:ro"
        "/home/mba/docker/restic-cron/hetzner/run_cleanup.sh:/usr/local/bin/run_cleanup.sh:ro"
        "/home/mba/docker/restic-cron/hetzner/start_cron.sh:/usr/local/bin/start_cron.sh:ro"
      ];
      environment = {
        RESTIC_BACKUP_OPTIONS = "-r sftp:u387549-sub2@u387549.your-storagebox.de:/";
        MAIL_SUBJECT = "💾 Restic backup report (hsb1)";
        CRON_BACKUP_EXPRESSION = "30 1 * * *";
      };
      env_file = [
        "/run/agenix/hsb1-restic-env"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false"
      ];
    };
    opus-stream-to-mqtt = {
      image = "node:alpine";
      container_name = "opus-stream-to-mqtt";
      network_mode = "host";
      restart = "unless-stopped";
      env_file = [
        "/run/agenix/opus-stream-hsb1"
      ];
      environment = [
        "TZ=Europe/Vienna"
      ];
      volumes = [
        "/etc/opus-stream-to-mqtt:/source:ro"
        "opus-stream-app:/app"
        "/home/mba/docker/mounts/shared/tmp:/shared-tmp"
      ];
      working_dir = "/app";
      command = "sh -c \"cp /source/*.js /source/package*.json /app/ && npm install && npm start\"";
      labels = [
        "com.centurylinklabs.watchtower.enable=true"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    watchtower-weekly = {
      image = "beatkind/watchtower:latest";
      container_name = "watchtower-weekly";
      restart = "unless-stopped";
      command = "--schedule \"0 0 5 * * 6\" --label-enable --scope weekly";
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock:rw"
      ];
      environment = [
        "TZ=Europe/Vienna"
        "WATCHTOWER_CLEANUP=true"
        "DOCKER_API_VERSION=1.44"
        "WATCHTOWER_DEBUG=true"
        "WATCHTOWER_HTTP_API_UPDATE=true"
        "WATCHTOWER_HTTP_API_PERIODIC_POLLS=true"
        "WATCHTOWER_NOTIFICATIONS=shoutrrr"
        "WATCHTOWER_NOTIFICATIONS_HOSTNAME=hsb1"
        "WATCHTOWER_NOTIFICATION_TITLE_TAG=🏠"
        "WATCHTOWER_NOTIFICATION_TEMPLATE={{range .}}{{.Time.Format \"2006-01-02 15:04:05\"}} ({{.Level}}): {{.Message}}{{println}}{{end}}"
      ];
      env_file = [
        "/run/agenix/hsb1-watchtower-env"
      ];
    };
    nodered = {
      image = "ghcr.io/markus-barta/node-red-miniserver24:main";
      container_name = "nodered";
      network_mode = "host";
      extra_hosts = [
        "mosquitto.barta.cm:89.58.63.96"
      ];
      restart = "unless-stopped";
      environment = [
        "TZ=Europe/Vienna"
      ];
      volumes = [
        "/home/mba/docker/mounts/nodered/data:/data"
        "/home/mba/docker/mounts/shared/tmp:/shared-tmp"
        "/home/mba/docker/mounts/nodered/scripts:/scripts"
        "/home/mba/docker/mounts/nodered/pixoo-venv:/pixoo-venv"
        "/home/mba/docker/mounts/nodered/webserver:/webserver"
        "/home/mba/docker/mounts/nodered/pixoo-media:/pixoo-media"
      ];
      env_file = [
        "/run/agenix/hsb1-smarthome-env"
      ];
      entrypoint = [
        "/bin/bash"
        "/scripts/startup.sh"
      ];
      command = [
        "npm"
        "start"
        "--"
        "--userDir"
        "/data"
      ];
      logging = {
        driver = "json-file";
        options = {
          max-size = "10m";
          max-file = "3";
        };
      };
      labels = [
        "com.centurylinklabs.watchtower.enable=true"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    plex = {
      image = "lscr.io/linuxserver/plex:latest";
      container_name = "plex";
      network_mode = "host";
      environment = [
        "PUID=1000"
        "PGID=100"
        "TZ=Europe/Vienna"
        "VERSION=docker"
      ];
      volumes = [
        "/var/lib/docker/volumes/plex-config:/config"
        "/srv/media:/media:ro"
      ];
      restart = "unless-stopped";
      labels = [
        "com.centurylinklabs.watchtower.enable=true"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    fritz-tripwire = {
      build = "/home/mba/Code/nixcfg/hosts/hsb1/docker/fritz-tripwire";
      container_name = "fritz-tripwire";
      restart = "unless-stopped";
      environment = [
        "APPRISE_BASE=http://apprise:8000"
      ];
      ports = [
        "9000:9000"
      ];
      volumes = [
        "/home/mba/docker/mounts/fritz-tripwire/incidents:/incidents"
        "/run/agenix/hsb1-fritz-tripwire-env:/secrets/fritz.env:ro"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false"
      ];
    };
    pharos-beacon = {
      image = "ghcr.io/inspr-at/pharos/pharosd:0.1.67@sha256:f1e9f37b1b989109f66c5fe00f8371ca49e00d0ccf5f0dede4b4b49abfad0c26";
      container_name = "pharos-beacon";
      restart = "unless-stopped";
      init = true;
      read_only = true;
      cap_drop = [
        "ALL"
      ];
      security_opt = [
        "no-new-privileges:true"
      ];
      pids_limit = 64;
      mem_limit = "256m";
      cpus = "0.5";
      tmpfs = [
        "/tmp:rw,noexec,nosuid,nodev,size=32m,mode=1777"
      ];
      network_mode = "host";
      user = "1000:1000";
      entrypoint = [
        "/usr/local/bin/pharos-beacon"
      ];
      healthcheck = {
        disable = true;
      };
      env_file = [
        "/run/agenix/pharos-beacon-hsb1-env"
      ];
      environment = [
        "PHAROS_URL=http://100.64.0.4:8088"
        "PHAROS_INTERVAL=60"
        "PHAROS_HOSTNAME=hsb1"
        "PHAROS_CURRENT_KERNEL_MODULES_DIR=/host/run/current-system/kernel-modules/lib/modules"
        "NIXCFG_DIR=/nixcfg"
        "GIT_CONFIG_COUNT=1"
        "GIT_CONFIG_KEY_0=safe.directory"
        "GIT_CONFIG_VALUE_0=/nixcfg"
      ];
      volumes = [
        "/home/mba/Code/nixcfg:/nixcfg:ro"
        "/etc/NIXOS:/etc/NIXOS:ro"
        "/run/current-system/kernel-modules/lib/modules:/host/run/current-system/kernel-modules/lib/modules:ro"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    hsb1-home = {
      image = "nginx:alpine";
      container_name = "hsb1-home";
      restart = "unless-stopped";
      ports = [
        "80:80"
      ];
      environment = [
        "TZ=Europe/Vienna"
      ];
      volumes = [
        "/etc/hostdash/hsb1/share/hostdash-hsb1:/usr/share/nginx/html:ro"
        "/var/lib/hostdash-status:/srv/hostdash-status:ro"
        "/etc/hostdash-nginx.conf:/etc/nginx/conf.d/default.conf:ro"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=true"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    opusweb = {
      image = "node:22-alpine";
      container_name = "opusweb";
      restart = "unless-stopped";
      working_dir = "/app";
      command = "node server.js";
      ports = [
        "3102:3102"
      ];
      environment = [
        "TZ=Europe/Vienna"
        "OPUSWEB_GW=http://192.168.1.102:8080"
      ];
      env_file = [
        "/run/agenix/hsb1-opusweb-env"
      ];
      volumes = [
        "/home/mba/docker/mounts/opusweb:/app:ro"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false"
      ];
    };
  };
  volumes = {
    opus-stream-app = null;
  };
  networks = {
    bridge = null;
    local = {
      driver = "macvlan";
      driver_opts = {
        parent = "enp3s0f0";
      };
      ipam = {
        config = [
          {
            subnet = "192.168.1.0/24";
            gateway = "192.168.1.5";
          }
        ];
      };
    };
  };
}
