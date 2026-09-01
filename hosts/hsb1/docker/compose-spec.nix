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
# Incident-history comments carried over from the retired yml (OPS-127).
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

# ── carried from the retired docker-compose.yml ──
# name: miniserver24
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
      #restart: "no"
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
        "/run/agenix/hsb1-pixdcon-env" # MOSQUITTO_HOST / MOSQUITTO_USER / MOSQUITTO_PASS / SONNEN_BATTERY_HOST / SONNEN_BATTERY_API_TOKEN
      ];
      volumes = [
        "/home/mba/docker/mounts/pixdcon/config.json:/data/config.json" # rw — web UI saves settings
        "/home/mba/docker/mounts/pixdcon/scenes:/data/scenes" # rw — editable scene files
        "/home/mba/docker/mounts/pixdcon/generated-scenes:/data/generated-scenes" # rw — cloned/detached scenes
        "/home/mba/docker/mounts/funkeykid/images:/app/assets/pixoo/funkeykid:ro" # funkeykid v2 images (overrides baked-in v1)
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=true"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    # Reconciled from deployed host state on 2026-05-25 (was running on hsb1
    # but missing from repo). See docs/FUNKEYKID.md.
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
        "/run/agenix/hsb1-smarthome-env" # MQTT credentials
        "/run/agenix/hsb1-funkeykid-api-env" # ELEVENLABS_API_KEY + OPENROUTER_API_KEY
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
    # https://github.com/koush/scrypted
    scrypted = {
      image = "ghcr.io/koush/scrypted";
      container_name = "scrypted";
      restart = "unless-stopped";
      network_mode = "host";
      environment = [
        "TZ=Europe/Vienna"
        #- SCRYPTED_WEBHOOK_UPDATE_AUTHORIZATION=${SCRYPTED_WEBHOOK_UPDATE_AUTHORIZATION}
        "SCRYPTED_WEBHOOK_UPDATE=http://localhost:10444/v1/update"
        # Enable UPnP for device discovery
        "SCRYPTED_UNMANAGED_PLUGINS_SCAN=false"
      ];
      # Enable to try Avahi inside the container
      #- SCRYPTED_DOCKER_AVAHI=true
      volumes = [
        "/home/mba/docker/mounts/scrypted/volume:/server/volume"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=true"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
      env_file = [
        "/run/agenix/hsb1-tapo-c210-env" # agenix owner=kiosk 0400 (NIX-356) — env_file is read CLIENT-side by the root compose units; the kiosk units source the same file in-process
      ];
    };
    # https://github.com/namshi/docker-smtp
    smtp = {
      image = "namshi/smtp";
      restart = "unless-stopped";
      # runs in default network
      #     networks:
      #       - smtp
      environment = [
        "TZ=Europe/Vienna"
        "SMARTHOST_ADDRESS=smtp.resend.com" # OPS-175: Resend, per-host key, sender domain barta.cm
        "SMARTHOST_PORT=587"
        "SMARTHOST_USER=resend"
        "SMARTHOST_ALIASES=*"
        "RELAY_NETWORKS=:172.0.0.0/8"
      ];
      env_file = [
        "/run/agenix/hsb1-mailrelay-env" # SMARTHOST_PASSWORD=<Resend key>
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
      # Using host network like your Home Assistant container for proper mDNS
      network_mode = "host";
      security_opt = [
        # Required for Bluetooth via dbus
        "apparmor:unconfined"
      ];
      volumes = [
        # Adjusted to match your mount pattern
        "/home/mba/docker/mounts/matter-server:/data"
        # D-Bus access for Bluetooth (matches your Home Assistant config)
        "/run/dbus:/run/dbus:ro"
      ];
      environment = [
        "TZ=Europe/Vienna"
      ];
      # Set Bluetooth adapter
      # command: --storage-path /data --paa-root-cert-dir /data/credentials --bluetooth-adapter 0
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
        # conf + passwd delivered encrypted via agenix (decrypted to /run/agenix at nixos switch).
        # Server-side broker config incl. the vendor-locked OPUS bridge credential — never plaintext in git.
        "/run/agenix/hsb1-mosquitto-conf:/mosquitto/config/mosquitto.conf:ro"
        "/run/agenix/hsb1-mosquitto-passwd:/mosquitto/config/mosquitto_passwd:ro"
        "/home/mba/docker/mounts/mosquitto/var/run:/var/run" # needed to fix "unable to write PID" error. https://github.com/eclipse/mosquitto/issues/2074#issuecomment-787135608
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
    # OPS-141: modernized 2026-08-03 — csb0-generation scripts from the REPO
    # (was /home/mba/docker/restic-cron, 2024-vintage, --host miniserver24),
    # Pharos status-file dead-man's-switch, snapshots now labeled hsb1.
    # Same sub2 repository = history continuity; the legacy miniserver24
    # snapshot group gets an explicit forget after the retention window.
    restic-cron-hetzner = {
      build = "./restic-cron";
      container_name = "restic-cron-hetzner";
      restart = "unless-stopped";
      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "/home:/backup/home:ro"
        "/root:/backup/root:ro"
        "/etc:/backup/etc:ro"
        # Use SSH key from agenix
        "/run/agenix/hsb1-restic-ssh-key:/root/.ssh/id_rsa:ro"
        "./restic-cron/ssh_known_hosts:/root/.ssh/known_hosts:ro"
        # BIND MOUNTS: Local scripts override container defaults
        "./restic-cron/hetzner/run_backup.sh:/usr/local/bin/run_backup.sh:ro"
        "./restic-cron/hetzner/run_check.sh:/usr/local/bin/run_check.sh:ro"
        "./restic-cron/hetzner/run_cleanup.sh:/usr/local/bin/run_cleanup.sh:ro"
        "./restic-cron/hetzner/start_cron.sh:/usr/local/bin/start_cron.sh:ro"
        "/var/lib/hsb1-docker/pharos-backup-status:/pharos-backup-status"
      ];
      environment = {
        RESTIC_REPOSITORY = "sftp:u387549-sub2@u387549.your-storagebox.de:/";
        # MAIL_SUBJECT removed (OPS-137): reporting is the status file; the
        # agenix env's MAIL_TO still triggers the (working) mail as a bonus.
        # OPS-175: Resend accepts From only on the verified barta.cm domain.
        MAIL_FROM = "fleet@barta.cm";
        CRON_BACKUP_EXPRESSION = "30 1 * * *";
        PHAROS_BACKUP_STATUS_FILE = "/pharos-backup-status/restic-cron-hetzner.json";
      };
      env_file = [
        # Load RESTIC_PASSWORD (+ MAIL_TO) from agenix
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
    nodered = {
      #custom built image in github, originally from #image: nodered/node-red:latest
      image = "ghcr.io/markus-barta/node-red-miniserver24:main";
      container_name = "nodered";
      network_mode = "host";
      # The access gate's Telegram path runs csb0 Node-RED -> csb0 mosquitto ->
      # this container's `csb0+` MQTT subscriber. Resolving that name was the
      # single point of failure that broke the gate for two days, so take DNS out
      # of the loop entirely: /etc/hosts wins over any resolver.
      #
      # Pinned by IP, NOT switched to an IP in the broker node — csb0 routes this
      # through Traefik on `HostSNI(mosquitto.barta.cm)` with a Let's Encrypt cert,
      # so the hostname must survive for both SNI routing and cert validation.
      # Keeping the name and fixing the address gives us both.
      #
      # 89.58.63.96 is csb0's static Netcup v4 address (hosts/csb0/README.md).
      # Deliberately the public address, not the tailnet one: this path must not
      # depend on tailscaled being up. If csb0 is ever re-addressed, update here.
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
      # NIX-158 P4: blanket /home/mba/secrets:/secrets mount removed — it exposed
      # the ENTIRE plaintext secrets dir to nodered but had NO live consumer (the
      # only /secrets reader was the retired win10pc shutdown script). Secrets now
      # arrive via env_file (agenix hsb1-smarthome-env) only.
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
    # fritz-tripwire — webhook receiver that snapshots all Fritz mesh devices
    # when one fails. Triggered by Uptime Kuma on hsb0 (POST to /hooks/fritz-down).
    # Output lands in /home/mba/docker/mounts/fritz-tripwire/incidents/fritz-<ip>-<ts>/.
    # See hosts/hsb1/docs/RUNBOOK.md → "fritz-tripwire" for setup + Kuma wiring.
    fritz-tripwire = {
      build = "/home/mba/Code/nixcfg/hosts/hsb1/docker/fritz-tripwire";
      container_name = "fritz-tripwire";
      restart = "unless-stopped";
      environment = [
        # Central Apprise hub (same compose network) for LaMetric alerts (NIX-172).
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
    # Pharos beacon (PHAROS-6) — reports this host's status + nix freshness to
    # pharosd (csb1) every 60s; succeeds the FleetCom bosun agent above.
    pharos-beacon = {
      image = "ghcr.io/inspr-at/pharos/pharosd:26.09.01.13.29.31@sha256:595ac6261935f2334195e811fec395edd67ec7433ab9cef63eaa472becb6c98f";
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
      env_file = [
        "/run/agenix/pharos-beacon-hsb1-env"
      ];
      environment = [
        "PHAROS_URL=http://100.64.0.4:8088"
        "PHAROS_INTERVAL=60"
        "PHAROS_HOSTNAME=hsb1"
        "PHAROS_PREFERENCES_FILE=/etc/pharos/host-preferences.json"
        "PHAROS_CURRENT_KERNEL_MODULES_DIR=/host/run/current-system/kernel-modules/lib/modules"
        "PHAROS_NIX_DEPLOYMENT_EVIDENCE_FILE=/host/pharos-deployment/evidence.json"
        "PHAROS_NIXCFG_REMOTE_URL=https://github.com/markus-barta/nixcfg.git"
        "PHAROS_NIXCFG_REMOTE_REF=refs/heads/main"
        "PHAROS_NIXPKGS_REMOTE_URL=https://github.com/NixOS/nixpkgs.git"
        "NIXCFG_DIR=/nixcfg"
        "GIT_CONFIG_COUNT=1"
        "GIT_CONFIG_KEY_0=safe.directory"
        "GIT_CONFIG_VALUE_0=/nixcfg"
        # OPS-141: read the restic status file for backup posture reporting
        "PHAROS_BACKUP_MODE=status-file"
        "PHAROS_BACKUP_STATUS_FILE=/pharos-backup-status/restic-cron-hetzner.json"
      ];
      volumes = [
        "/home/mba/Code/nixcfg:/nixcfg:ro"
        "/run/pharos-deployment:/host/pharos-deployment:ro" # OPS-186: directory, not the file — see flake.nix activation script
        "/etc/NIXOS:/etc/NIXOS:ro"
        "/run/pharos-preferences:/etc/pharos:ro"
        "/run/current-system/kernel-modules/lib/modules:/host/run/current-system/kernel-modules/lib/modules:ro"
        "/var/lib/hsb1-docker/pharos-backup-status:/pharos-backup-status:ro"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    # hsb1-home (NIX-211) — HostDash service landing page for this host: every
    # container at a glimpse, one click away, live status dots. Static single file,
    # served by nginx on :80. Built from markus-barta/hostdash via Nix, then
    # mounted read-only from /etc.
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
        # NIX-280: runtime status artifact, served SAME-ORIGIN at ./status/status.json.
        #
        # Same-origin is the whole point. HostDash's only status signal today is a
        # browser `fetch(..., {mode:"no-cors"})`, whose response is OPAQUE — the status
        # code cannot be read, so an HTTP 500 registers as "up" and a self-signed cert
        # registers as "down". A cross-origin status endpoint would inherit exactly that
        # blindness. Served from the same origin as index.html, the JSON is fully
        # readable, and `running` becomes knowable for the first time — including for the
        # 9-of-19 services with no HTTP endpoint, which no browser could ever probe.
        #
        # NOTE the mount path: NOT /usr/share/nginx/html/status. That directory is an
        # immutable /nix/store bind mount, and Docker cannot create a mountpoint inside a
        # read-only mount — it fails with "mkdirat .../status: read-only file system" and
        # leaves the container stuck in `Created` (learned the hard way, 2026-07-14).
        # So it is mounted outside the app root, and nginx aliases it back under the same
        # origin — see files/hostdash-nginx.conf.
        #
        # Written atomically every 60s by hostdash-status.service (../hostdash-status.nix).
        "/var/lib/hostdash-status:/srv/hostdash-status:ro"
        "/etc/hostdash-nginx.conf:/etc/nginx/conf.d/default.conf:ro"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=true"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    # opusweb (OPUSW-8) — OPUS greenNet dashboard/config editor over the gateway REST
    # API (192.168.1.102:8080). Zero-dep Node run from bind-mounted code; gateway
    # password from a host env-file (not in git). github.com/markus-barta/opusweb.
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

# ── comments from the retired yml that could not be auto-anchored ──
# [funkeykid] # Required for /dev/input access (was on: privileged: true)
# [restic-cron-hetzner] # 1:30am (was on: CRON_BACKUP_EXPRESSION: "30 1 * * *")
