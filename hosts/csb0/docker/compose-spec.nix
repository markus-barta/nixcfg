# csb0 container stack — the compose spec, authored in Nix (OPS-116).
#
# Replaces hosts/csb0/docker/docker-compose.yml. Rendered into the closure and
# reconciled at switch by modules/shared/compose-stack, so a resolver-policy
# change can no longer strand a running container (OPS-113).
#
# 🔴 `dns` / `dns_search` MUST NOT appear here — the module injects them from
# config.networking.nameservers into every network_mode: host service.
#
# Highest blast radius on the fleet: headscale, Traefik, the OPS-104 alert poller,
# the Telegram bot that opens the access gate, and the MQTT broker the smart-home
# path depends on. ./traefik/acme*.json is MUTABLE Let's Encrypt state and must
# stay a writable bind mount — never let it into the store.
#
# Verify any change with:
#   nix shell nixpkgs#yq-go -c ./tests/compose_stack_gate.py csb0
# Comments from the source file are NOT carried across by this tool; re-attach
# them by hand. They hold real incident history.
# Compose project name: csb0 — named volumes depend on it.
#
# Dropped (now supplied by the composeStack module):
#   pharos-beacon.dns = ['46.38.225.230', '46.38.252.230']
#   x-host-dns (anchor)

{
  name = "csb0";
  services = {
    mosquitto = {
      image = "eclipse-mosquitto:latest";
      ports = [
        "127.0.0.1:1883:1883"
      ];
      volumes = [
        "/run/agenix/mosquitto-passwd:/mosquitto/config/mosquitto_passwd:ro"
        "/run/agenix/mosquitto-conf:/mosquitto/config/mosquitto.conf:ro"
        "mosquitto-data:/mosquitto/data"
        "mosquitto-log:/mosquitto/log"
        "mosquitto-run:/run"
      ];
      user = "1883:1883";
      group_add = [
        "1883"
      ];
      environment = [
        "TZ=Europe/Vienna"
      ];
      networks = [
        "traefik"
      ];
      restart = "unless-stopped";
      labels = [
        "traefik.tcp.routers.mosquitto.rule=HostSNI(`mosquitto.barta.cm`)"
        "traefik.tcp.routers.mosquitto.entrypoints=mqtt"
        "traefik.tcp.routers.mosquitto.tls=true"
        "traefik.tcp.routers.mosquitto.service=mosquitto-svc"
        "traefik.tcp.services.mosquitto-svc.loadbalancer.server.port=1883"
        "traefik.tcp.routers.mosquitto.tls.certResolver=default"
      ];
    };
    nodered = {
      image = "nodered/node-red:latest";
      environment = [
        "TZ=Europe/Vienna"
        "NODE_RED_ENABLE_PROJECTS=false"
        "NODE_RED_ENABLE_EDITOR=true"
      ];
      env_file = [
        "/run/agenix/nodered-env"
      ];
      volumes = [
        "nodered-data:/data"
        "nodered-scripts:/scripts"
        "nodered-webserver:/webserver"
        "shared-tmp:/shared-tmp"
      ];
      entrypoint = [
        "/bin/bash"
        "/scripts/startup.sh"
      ];
      labels = [
        "traefik.http.routers.nodered.rule=Host(`home.barta.cm`)"
        "traefik.http.routers.nodered.tls.certresolver=default"
        "traefik.http.routers.nodered.tls=true"
        "traefik.http.services.nodered.loadbalancer.server.port=1880"
        "traefik.docker.network=csb0_traefik"
        "traefik.http.routers.nodered.middlewares=cloudflarewarp@file"
        "traefik.http.routers.nodered-http.rule=Host(`home.barta.cm`)"
        "traefik.http.routers.nodered-http.entrypoints=web"
        "traefik.http.routers.nodered-http.middlewares=redirect-to-https@docker"
        "traefik.http.middlewares.redirect-to-https.redirectscheme.scheme=https"
        "traefik.http.middlewares.redirect-to-https.redirectscheme.permanent=true"
      ];
      networks = [
        "traefik"
      ];
      restart = "unless-stopped";
    };
    docker-proxy-traefik = {
      image = "tecnativa/docker-socket-proxy";
      environment = [
        "CONTAINERS=1"
      ];
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock:ro"
      ];
      networks = [
        "docker-sock-traefik"
      ];
      restart = "always";
      labels = [
        "traefik.enable=false"
      ];
    };
    traefik = {
      image = "traefik";
      command = "--providers.docker";
      restart = "always";
      ports = [
        "80:80"
        "443:443/tcp"
        "443:443/udp"
        "8883:8883"
      ];
      networks = [
        "traefik"
        "docker-sock-traefik"
      ];
      volumes = [
        "./traefik/static.yml:/etc/traefik/traefik.yml:ro"
        "./traefik/dynamic.yml:/etc/traefik/dynamic/dynamic.yml:ro"
        "./traefik/acme.json:/etc/traefik/acme/acme.json:rw"
      ];
      labels = [
        "traefik.http.routers.traefik.rule=Host(`cs0.barta.cm`) && (PathPrefix(`/api`) || PathPrefix(`/dashboard`))"
        "traefik.http.routers.traefik.entrypoints=web-secure"
        "traefik.http.routers.traefik.service=api@internal"
        "traefik.http.routers.traefik.tls.certresolver=default"
        "traefik.http.routers.traefik.tls=true"
        "traefik.http.routers.traefik.priority=100"
        "com.centurylinklabs.watchtower.enable=false"
      ];
      environment = [
        "TZ=Europe/Vienna"
      ];
      env_file = [
        "/run/agenix/traefik-variables"
      ];
    };
    hostdash-auth = {
      image = "quay.io/oauth2-proxy/oauth2-proxy:v7.15.3";
      restart = "unless-stopped";
      env_file = [
        "/run/agenix/csb-hostdash-oauth2-proxy-env"
      ];
      command = [
        "--http-address=0.0.0.0:4180"
        "--provider=oidc"
        "--oidc-issuer-url=https://auth.inspr.at"
        "--redirect-url=https://cs0.barta.cm/oauth2/callback"
        "--email-domain=*"
        "--cookie-domain=.barta.cm"
        "--whitelist-domain=.barta.cm"
        "--cookie-secure=true"
        "--cookie-samesite=lax"
        "--cookie-expire=8h"
        "--cookie-refresh=1h"
        "--reverse-proxy=true"
        "--trusted-proxy-ip=172.16.0.0/12"
        "--set-xauthrequest=true"
        "--pass-access-token=false"
        "--pass-authorization-header=false"
        "--skip-provider-button=true"
        "--upstream=static://202"
        "--silence-ping-logging=true"
      ];
      networks = [
        "traefik"
      ];
      labels = [
        "traefik.enable=true"
        "traefik.http.routers.hostdash-auth-csb0.rule=Host(`cs0.barta.cm`) && PathPrefix(`/oauth2`)"
        "traefik.http.routers.hostdash-auth-csb0.entrypoints=web-secure"
        "traefik.http.routers.hostdash-auth-csb0.tls=true"
        "traefik.http.routers.hostdash-auth-csb0.tls.certresolver=default"
        "traefik.http.routers.hostdash-auth-csb0.priority=250"
        "traefik.http.services.hostdash-auth-csb0.loadbalancer.server.port=4180"
        "traefik.docker.network=csb0_traefik"
        "com.centurylinklabs.watchtower.enable=false"
      ];
    };
    hostdash = {
      image = "nginx:alpine";
      restart = "unless-stopped";
      environment = [
        "TZ=Europe/Vienna"
      ];
      volumes = [
        "/etc/hostdash/csb0/share/hostdash-csb0:/usr/share/nginx/html:ro"
      ];
      networks = [
        "traefik"
      ];
      labels = [
        "traefik.enable=true"
        "traefik.http.routers.hostdash-csb0.rule=Host(`cs0.barta.cm`)"
        "traefik.http.routers.hostdash-csb0.entrypoints=web-secure"
        "traefik.http.routers.hostdash-csb0.tls=true"
        "traefik.http.routers.hostdash-csb0.tls.certresolver=default"
        "traefik.http.routers.hostdash-csb0.priority=10"
        "traefik.http.routers.hostdash-csb0.middlewares=hostdash-auth-csb0@docker"
        "traefik.http.middlewares.hostdash-auth-csb0.forwardauth.address=http://hostdash-auth:4180/"
        "traefik.http.middlewares.hostdash-auth-csb0.forwardauth.trustForwardHeader=true"
        "traefik.http.middlewares.hostdash-auth-csb0.forwardauth.authResponseHeaders=X-Auth-Request-User,X-Auth-Request-Email"
        "traefik.http.services.hostdash-csb0.loadbalancer.server.port=80"
        "traefik.docker.network=csb0_traefik"
        "traefik.http.routers.hostdash-csb0-http.rule=Host(`cs0.barta.cm`)"
        "traefik.http.routers.hostdash-csb0-http.entrypoints=web"
        "traefik.http.routers.hostdash-csb0-http.middlewares=hostdash-csb0-https@docker"
        "traefik.http.middlewares.hostdash-csb0-https.redirectscheme.scheme=https"
        "traefik.http.middlewares.hostdash-csb0-https.redirectscheme.permanent=true"
        "traefik.http.routers.hostdash-csb0-ip.rule=Host(`89.58.63.96`) || Host(`100.64.0.8`)"
        "traefik.http.routers.hostdash-csb0-ip.entrypoints=web"
        "traefik.http.routers.hostdash-csb0-ip.priority=200"
        "traefik.http.routers.hostdash-csb0-ip.middlewares=hostdash-csb0-ip-canonical@docker"
        "traefik.http.routers.hostdash-csb0-ip.service=hostdash-csb0"
        "traefik.http.middlewares.hostdash-csb0-ip-canonical.redirectregex.regex=^http://[^/]+/(.*)"
        "traefik.http.middlewares.hostdash-csb0-ip-canonical.redirectregex.replacement=https://cs0.barta.cm/$\${1}"
        "traefik.http.middlewares.hostdash-csb0-ip-canonical.redirectregex.permanent=true"
        "com.centurylinklabs.watchtower.enable=true"
      ];
    };
    smtp = {
      image = "namshi/smtp";
      restart = "always";
      networks = [
        "traefik"
        "smtp"
      ];
      environment = [
        "TZ=Europe/Vienna"
        "SMARTHOST_ADDRESS=mail.hover.com"
        "SMARTHOST_PORT=587"
        "SMARTHOST_USER=markus@barta.com"
        "SMARTHOST_ALIASES=*"
        "RELAY_NETWORKS=:172.0.0.0/8"
      ];
      labels = [
        "traefik.enable=false"
      ];
    };
    restic-cron-hetzner = {
      build = "./restic-cron";
      restart = "unless-stopped";
      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "/var/lib/docker/volumes:/backup/var/lib/docker/volumes:ro"
        "/home:/backup/home:ro"
        "/root:/backup/root:ro"
        "/etc:/backup/etc:ro"
        "/run/agenix/restic-hetzner-ssh-key:/root/.ssh/id_rsa:ro"
        "./restic-cron/ssh_known_hosts:/root/.ssh/known_hosts:ro"
        "./restic-cron/hetzner/run_backup.sh:/usr/local/bin/run_backup.sh:ro"
        "./restic-cron/hetzner/run_check.sh:/usr/local/bin/run_check.sh:ro"
        "./restic-cron/hetzner/run_cleanup.sh:/usr/local/bin/run_cleanup.sh:ro"
        "./restic-cron/hetzner/start_cron.sh:/usr/local/bin/start_cron.sh:ro"
        "/var/lib/csb0-docker/pharos-backup-status:/pharos-backup-status"
      ];
      environment = {
        RESTIC_REPOSITORY = "sftp:u387549-sub1@u387549.your-storagebox.de:/";
        MAIL_SUBJECT = "💾 Restic Backup netcup csb0 (hetzner)";
        CRON_BACKUP_EXPRESSION = "30 1 * * *";
        PHAROS_BACKUP_STATUS_FILE = "/pharos-backup-status/restic-cron-hetzner.json";
      };
      env_file = [
        "/run/agenix/restic-hetzner-env"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false"
        "traefik.enable=false"
      ];
      networks = [
        "smtp"
      ];
    };
    uptime-kuma = {
      image = "louislam/uptime-kuma:latest";
      volumes = [
        "uptime-kuma-data:/app/data"
      ];
      environment = [
        "TZ=Europe/Vienna"
        "UPTIME_KUMA_PORT=3001"
      ];
      env_file = [
        "/run/agenix/uptime-kuma-env"
      ];
      labels = [
        "traefik.http.routers.uptime-kuma.rule=Host(`uptime.barta.cm`)"
        "traefik.http.routers.uptime-kuma.entrypoints=web-secure"
        "traefik.http.routers.uptime-kuma.tls=true"
        "traefik.http.routers.uptime-kuma.tls.certresolver=default"
        "traefik.http.routers.uptime-kuma.middlewares=cloudflarewarp@file"
        "traefik.http.services.uptime-kuma.loadbalancer.server.port=3001"
        "traefik.http.routers.uptime-kuma-http.rule=Host(`uptime.barta.cm`)"
        "traefik.http.routers.uptime-kuma-http.entrypoints=web"
        "traefik.http.routers.uptime-kuma-http.middlewares=redirect-to-https@docker"
      ];
      networks = [
        "traefik"
      ];
      restart = "unless-stopped";
    };
    headscale = {
      image = "headscale/headscale:0.25";
      container_name = "headscale";
      restart = "unless-stopped";
      read_only = true;
      tmpfs = [
        "/var/run/headscale"
      ];
      volumes = [
        "./headscale/config:/etc/headscale:ro"
        "headscale-data:/var/lib/headscale"
      ];
      command = "serve";
      environment = [
        "TZ=Europe/Vienna"
      ];
      networks = [
        "traefik"
      ];
      labels = [
        "traefik.enable=true"
        "traefik.http.routers.headscale.rule=Host(`hs.barta.cm`)"
        "traefik.http.routers.headscale.entrypoints=web-secure"
        "traefik.http.routers.headscale.tls=true"
        "traefik.http.routers.headscale.tls.certresolver=default"
        "traefik.http.services.headscale.loadbalancer.server.port=8080"
        "traefik.docker.network=csb0_traefik"
        "traefik.http.routers.headscale-http.rule=Host(`hs.barta.cm`)"
        "traefik.http.routers.headscale-http.entrypoints=web"
        "traefik.http.routers.headscale-http.middlewares=redirect-to-https@docker"
      ];
      healthcheck = {
        test = [
          "CMD"
          "headscale"
          "configtest"
        ];
        interval = "30s";
        timeout = "10s";
        retries = 3;
      };
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
        "/run/agenix/pharos-beacon-csb0-env"
      ];
      environment = [
        "PHAROS_URL=http://100.64.0.4:8088"
        "PHAROS_INTERVAL=60"
        "PHAROS_HOSTNAME=csb0"
        "PHAROS_BACKUP_MODE=status-file"
        "PHAROS_BACKUP_STATUS_FILE=/pharos-backup-status/restic-cron-hetzner.json"
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
        "/var/lib/csb0-docker/pharos-backup-status:/pharos-backup-status:ro"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false"
        "traefik.enable=false"
      ];
    };
    tesla-fleet-key = {
      image = "nginx:alpine";
      restart = "unless-stopped";
      volumes = [
        "./tesla-fleet:/usr/share/nginx/html:ro"
      ];
      environment = [
        "TZ=Europe/Vienna"
      ];
      networks = [
        "traefik"
      ];
      labels = [
        "traefik.enable=true"
        "traefik.http.routers.tesla-fleet.rule=Host(`ev.barta.cm`)"
        "traefik.http.routers.tesla-fleet.entrypoints=web-secure"
        "traefik.http.routers.tesla-fleet.tls=true"
        "traefik.http.routers.tesla-fleet.tls.certresolver=default"
        "traefik.http.services.tesla-fleet.loadbalancer.server.port=80"
        "traefik.docker.network=csb0_traefik"
        "traefik.http.routers.tesla-fleet-http.rule=Host(`ev.barta.cm`)"
        "traefik.http.routers.tesla-fleet-http.entrypoints=web"
        "traefik.http.routers.tesla-fleet-http.middlewares=redirect-to-https@docker"
      ];
    };
  };
  volumes = {
    mosquitto-data = null;
    mosquitto-log = null;
    mosquitto-run = null;
    nodered-data = null;
    nodered-scripts = null;
    nodered-webserver = null;
    shared-tmp = null;
    uptime-kuma-data = null;
    headscale-data = null;
    bitwarden = null;
    bitwarden-db = null;
  };
  networks = {
    traefik = null;
    smtp = null;
    bitwarden = null;
    docker-sock-traefik = {
      internal = true;
    };
  };
}
