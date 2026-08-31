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
# Verify any change with (tests/compose_stack_gate.py no longer applies to csb0 — OPS-127):
#   nix eval --no-update-lock-file .#nixosConfigurations.csb0.config.system.build.toplevel.drvPath
#   scripts/format-check.sh · tests/T43-headscale-derp-fallback.sh
# Incident-history comments carried over from the retired yml (OPS-127).
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
      # Loopback only (OPS-115). The ops-alerts poller runs on this host as a
      # systemd unit, outside the docker network, and needs to read the retained
      # smart-home heartbeat that hsb1 publishes through this broker. Bound to
      # 127.0.0.1 so this adds no external surface: the public MQTT endpoint stays
      # Traefik on :8883 with TLS + HostSNI, unchanged.
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
        # Traefik config
        "traefik.http.routers.nodered.rule=Host(`home.barta.cm`)"
        "traefik.http.routers.nodered.tls.certresolver=default"
        "traefik.http.routers.nodered.tls=true"
        "traefik.http.services.nodered.loadbalancer.server.port=1880"
        "traefik.docker.network=csb0_traefik"
        "traefik.http.routers.nodered.middlewares=cloudflarewarp@file"
        # HTTP to HTTPS redirection
        "traefik.http.routers.nodered-http.rule=Host(`home.barta.cm`)"
        "traefik.http.routers.nodered-http.entrypoints=web"
        "traefik.http.routers.nodered-http.middlewares=redirect-to-https@docker"
        "traefik.http.middlewares.redirect-to-https.redirectscheme.scheme=https"
        "traefik.http.middlewares.redirect-to-https.redirectscheme.permanent=true"
      ];
      #       # Telegram webhook config
      #       - traefik.http.routers.nodered-telegram.rule=Host(`home.barta.cm`) && PathPrefix(`/telegram`)
      #       - traefik.http.routers.nodered-telegram.tls=true
      #       - traefik.http.routers.nodered-telegram.service=nodered-telegram
      #       - traefik.http.services.nodered-telegram.loadbalancer.server.port=1880
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
    # https://docs.traefik.io/v2.5/providers/docker/
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
      # - traefik.http.routers.traefik.middlewares=authelia
      # fixes error: middleware "authelia@docker" does not exist
      # - traefik.http.middlewares.authelia.forwardAuth.address=http://authelia:9091/api/verify?rd=https://login.barta.cm/
      environment = [
        "TZ=Europe/Vienna"
      ];
      env_file = [
        # Was ./traefik/variables.env — a GITIGNORED working-tree file that
        # existed only on this one checkout (QA-2 fragility: a fresh clone would
        # kill the whole `up` at parse time). traefik-variables.age has been
        # decryptable by csb0 all along (shared with csb1, which already uses
        # this path). Swapped 2026-08-01 (OPS-121).
        "/run/agenix/traefik-variables"
      ];
    };
    # HostDash — static service dashboard for this host. Built by Nix from
    # markus-barta/hostdash and mounted read-only from /etc/hostdash.
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
        # Joe is a static paper-drill card with no account data or controls.
        # Keep the dashboard authenticated; publish only this exact path.
        "traefik.http.routers.joe-csb0.rule=Host(`cs0.barta.cm`) && (Path(`/joe`) || PathPrefix(`/joe/`))"
        "traefik.http.routers.joe-csb0.entrypoints=web-secure"
        "traefik.http.routers.joe-csb0.tls=true"
        "traefik.http.routers.joe-csb0.tls.certresolver=default"
        "traefik.http.routers.joe-csb0.priority=300"
        "traefik.http.routers.joe-csb0.service=hostdash-csb0"
        "traefik.http.routers.joe-csb0.middlewares=joe-csb0-path@docker"
        "traefik.http.middlewares.joe-csb0-path.replacepathregex.regex=^/joe$$"
        "traefik.http.middlewares.joe-csb0-path.replacepathregex.replacement=/joe/"
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
    # smtp relay RETIRED 2026-08-03 (OPS-139): netcup blocks outbound mail
    # ports host-wide, its only consumer was the restic report mail, and backup
    # reporting moved to the Pharos status-file dead-man's-switch (see
    # restic-cron-hetzner PHAROS_BACKUP_STATUS_FILE + pharos-beacon). Do not
    # re-add mail infrastructure on cloud hosts (OPS-137 architecture decision).
    restic-cron-hetzner = {
      build = "./restic-cron";
      restart = "unless-stopped";
      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "/var/lib/docker/volumes:/backup/var/lib/docker/volumes:ro"
        "/home:/backup/home:ro"
        "/root:/backup/root:ro"
        "/etc:/backup/etc:ro"
        # Use SSH key from agenix
        "/run/agenix/restic-hetzner-ssh-key:/root/.ssh/id_rsa:ro"
        # Recovered known_hosts
        "./restic-cron/ssh_known_hosts:/root/.ssh/known_hosts:ro"
        # BIND MOUNTS: Local scripts override container defaults
        "./restic-cron/hetzner/run_backup.sh:/usr/local/bin/run_backup.sh:ro"
        "./restic-cron/hetzner/run_check.sh:/usr/local/bin/run_check.sh:ro"
        "./restic-cron/hetzner/run_cleanup.sh:/usr/local/bin/run_cleanup.sh:ro"
        "./restic-cron/hetzner/start_cron.sh:/usr/local/bin/start_cron.sh:ro"
        "/var/lib/csb0-docker/pharos-backup-status:/pharos-backup-status"
      ];
      environment = {
        RESTIC_REPOSITORY = "sftp:u387549-sub1@u387549.your-storagebox.de:/";
        # MAIL_SUBJECT removed (OPS-139): reporting is the Pharos status file
        # below; the mail path is retired on cloud hosts.
        CRON_BACKUP_EXPRESSION = "30 1 * * *";
        PHAROS_BACKUP_STATUS_FILE = "/pharos-backup-status/restic-cron-hetzner.json";
      };
      env_file = [
        # Load RESTIC_PASSWORD from agenix
        "/run/agenix/restic-hetzner-env"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false"
        "traefik.enable=false"
      ];
    };
    # Uptime Kuma - Docker service (consistent with other services)
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
        # HTTP to HTTPS redirection
        "traefik.http.routers.uptime-kuma-http.rule=Host(`uptime.barta.cm`)"
        "traefik.http.routers.uptime-kuma-http.entrypoints=web"
        "traefik.http.routers.uptime-kuma-http.middlewares=redirect-to-https@docker"
      ];
      networks = [
        "traefik"
      ];
      restart = "unless-stopped";
    };
    # Headscale - self-hosted Tailscale control server
    # https://headscale.net/stable/
    # ⚠️ DNS record MUST be DNS-only (gray cloud) in Cloudflare - proxy breaks WebSocket POSTs
    headscale = {
      # OPS-182/183 — exact patch, one minor per reviewed stage (headscale enforces the order).
      # >= 0.27 keeps the previous DERP map when the scheduled refresh fails (#2741), so the
      # OPS-180 derp.paths fallback is gone; tests/T43 fails loudly if it ever comes back.
      image = "headscale/headscale:0.29.3";
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
        # Traefik HTTP routing
        "traefik.enable=true"
        "traefik.http.routers.headscale.rule=Host(`hs.barta.cm`)"
        "traefik.http.routers.headscale.entrypoints=web-secure"
        "traefik.http.routers.headscale.tls=true"
        "traefik.http.routers.headscale.tls.certresolver=default"
        "traefik.http.services.headscale.loadbalancer.server.port=8080"
        "traefik.docker.network=csb0_traefik"
        # ⚠️ NO cloudflarewarp middleware! Headscale requires direct connection.
        # HTTP to HTTPS redirect
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
    # Pharos beacon (PHAROS-6) — reports this host's status + nix freshness to
    # pharosd (csb1) every 60s; succeeds the FleetCom bosun agent above.
    pharos-beacon = {
      image = "ghcr.io/inspr-at/pharos/pharosd:0.1.92@sha256:00b62db4e9fe8a6401772d738e6532479e266b57bff1ad734e2ef2338764c1f5";
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
        "/run/agenix/pharos-beacon-csb0-env"
      ];
      environment = [
        "PHAROS_URL=http://100.64.0.4:8088"
        "PHAROS_INTERVAL=60"
        "PHAROS_HOSTNAME=csb0"
        "PHAROS_PREFERENCES_FILE=/etc/pharos/host-preferences.json"
        "PHAROS_BACKUP_MODE=status-file"
        "PHAROS_BACKUP_STATUS_FILE=/pharos-backup-status/restic-cron-hetzner.json"
        "PHAROS_CURRENT_KERNEL_MODULES_DIR=/host/run/current-system/kernel-modules/lib/modules"
        "PHAROS_NIX_DEPLOYMENT_EVIDENCE_FILE=/host/pharos-deployment/evidence.json"
        "PHAROS_NIXCFG_REMOTE_URL=https://github.com/markus-barta/nixcfg.git"
        "PHAROS_NIXCFG_REMOTE_REF=refs/heads/main"
        "PHAROS_NIXPKGS_REMOTE_URL=https://github.com/NixOS/nixpkgs.git"
        "NIXCFG_DIR=/nixcfg"
        "GIT_CONFIG_COUNT=1"
        "GIT_CONFIG_KEY_0=safe.directory"
        "GIT_CONFIG_VALUE_0=/nixcfg"
      ];
      volumes = [
        "/home/mba/Code/nixcfg:/nixcfg:ro"
        "/run/pharos-deployment:/host/pharos-deployment:ro" # OPS-186: directory, not the file — see flake.nix activation script
        "/etc/NIXOS:/etc/NIXOS:ro"
        "/run/pharos-preferences:/etc/pharos:ro"
        "/run/current-system/kernel-modules/lib/modules:/host/run/current-system/kernel-modules/lib/modules:ro"
        "/var/lib/csb0-docker/pharos-backup-status:/pharos-backup-status:ro"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false"
        "traefik.enable=false"
      ];
    };
    # Tesla Fleet API public-key host (NIX-201 / runbook tesla-fleet-ha-migration).
    # Serves ONLY the public key at Tesla's well-known path so Tesla can verify
    # domain ownership for the Fleet API app (ev.barta.cm). DNS-only record
    # (ev → csb0, grey cloud) + own LE cert + NO cloudflarewarp — Tesla rejects
    # reverse-proxied / CDN origins. Mirrors the headscale direct-connection pattern.
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
        # HTTP→HTTPS redirect
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
    bitwarden = null;
    docker-sock-traefik = {
      internal = true;
    };
  };
}

# ── comments from the retired yml that could not be auto-anchored ──
# [traefik]       # mqtt
# [traefik]       # HostDash owns / on cs0.barta.cm; keep Traefik's API on /api and
# [traefik]       # /dashboard if the dashboard is enabled later.
# [restic-cron-hetzner] # 1:30am (was on: CRON_BACKUP_EXPRESSION: "30 1 * * *")
