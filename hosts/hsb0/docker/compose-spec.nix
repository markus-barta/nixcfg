# hsb0 container stack — the compose spec, authored in Nix (OPS-116).
#
# Replaces hosts/hsb0/docker/docker-compose.yml. Rendered into the closure and
# reconciled at switch by modules/shared/compose-stack, so a resolver-policy
# change can no longer strand a running container (OPS-113).
#
# 🔴 `dns` / `dns_search` MUST NOT appear here — the module injects them from
# config.networking.nameservers into every network_mode: host service.
#
# 🔴 project is "docker", not "hsb0" — this file carries no `name:` key, so compose
# derived the project from the containing directory. Verified on the live host
# 2026-08-01. hsb0 also runs the LAN's AdGuard: its nameserver is 127.0.0.1, which
# is the HOST's loopback and is correct ONLY because these are host-network
# services.
#
# Verify any change with:
#   nix shell nixpkgs#yq-go -c ./tests/compose_stack_gate.py hsb0
# Comments from the source file are NOT carried across by this tool; re-attach
# them by hand. They hold real incident history.
#
# Dropped (now supplied by the composeStack module):
#   openclaw-gateway.dns = ['127.0.0.1', '1.1.1.1']
#   openclaw-gateway.dns_search = ['lan']
#   pharos-beacon.dns = ['127.0.0.1', '1.1.1.1']
#   pharos-beacon.dns_search = ['lan']
#   x-host-dns (anchor)
#   x-host-dns-search (anchor)

{
  services = {
    restic-cron-hetzner = {
      build = "./restic-cron";
      container_name = "restic-cron-hetzner";
      restart = "unless-stopped";
      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "/var/lib/AdGuardHome:/backup/var/lib/AdGuardHome:ro"
        "/var/lib/ncps:/backup/var/lib/ncps:ro"
        "/etc:/backup/etc:ro"
        "/run/agenix/restic-hetzner-ssh-key:/root/.ssh/id_rsa:ro"
        "./restic-cron/ssh_known_hosts:/root/.ssh/known_hosts:ro"
        "./restic-cron/hetzner/run_backup.sh:/usr/local/bin/run_backup.sh:ro"
        "./restic-cron/hetzner/run_check.sh:/usr/local/bin/run_check.sh:ro"
        "./restic-cron/hetzner/run_cleanup.sh:/usr/local/bin/run_cleanup.sh:ro"
        "./restic-cron/hetzner/start_cron.sh:/usr/local/bin/start_cron.sh:ro"
      ];
      environment = {
        RESTIC_REPOSITORY = "sftp:u387549-sub1@u387549.your-storagebox.de:23/hsb0";
        MAIL_SUBJECT = "💾 Restic backup report (hsb0)";
        CRON_BACKUP_EXPRESSION = "0 2 * * *";
      };
      env_file = [
        "/run/agenix/restic-hetzner-env"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false"
        "traefik.enable=false"
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
      labels = [
        "traefik.enable=false"
        "com.centurylinklabs.watchtower.enable=false"
      ];
    };
    openclaw-gateway = {
      build = "./openclaw-gateway";
      container_name = "openclaw-gateway";
      restart = "unless-stopped";
      network_mode = "host";
      volumes = [
        "/var/lib/openclaw-gateway/data:/home/node/.openclaw:rw"
        "./openclaw-gateway/openclaw.json:/home/node/.openclaw-config/openclaw.json:ro"
        "/run/agenix/hsb0-elevenlabs-api-key:/run/secrets/elevenlabs-api-key:ro"
        "/run/agenix/hsb0-groq-api-key:/run/secrets/groq-api-key:ro"
        "/run/agenix/hsb0-uptime-kuma-api-key:/run/secrets/uptime-kuma-api-key:ro"
        "/run/agenix/hsb0-openclaw-gateway-token:/run/secrets/gateway-token:ro"
        "/run/agenix/hsb0-openclaw-openrouter-key:/run/secrets/openrouter-key:ro"
        "/run/agenix/hsb0-openclaw-brave-key:/run/secrets/brave-key:ro"
        "/run/agenix/hsb0-openclaw-hass-token:/run/secrets/hass-token:ro"
        "/run/agenix/hsb0-openclaw-opus-gateway:/home/node/.openclaw/credentials/opus-gateway.env:ro"
        "/run/agenix/hsb0-ppm-api-key:/run/secrets/ppm-api-key:ro"
        "/run/agenix/hsb0-openclaw-telegram-token:/run/secrets/telegram-token-merlin:ro"
        "/run/agenix/hsb0-openclaw-github-pat:/run/secrets/github-pat-merlin:ro"
        "/run/agenix/hsb0-gogcli-keyring-password:/run/secrets/gogcli-keyring-password:ro"
        "/run/agenix/hsb0-merlin-ssh-key:/run/secrets/merlin-ssh-key:ro"
        "./openclaw-gateway/ssh_config:/home/node/.ssh/config:ro"
        "/run/agenix/hsb0-nimue-telegram-token:/run/secrets/telegram-token-nimue:ro"
        "/run/agenix/hsb0-nimue-github-pat:/run/secrets/github-pat-nimue:ro"
        "/run/agenix/hsb0-nimue-gogcli-keyring-password:/run/secrets/gogcli-keyring-password-nimue:ro"
        "/run/agenix/hsb0-nimue-gogcli-credentials:/run/secrets/nimue-gogcli-credentials:ro"
        "/run/agenix/hsb0-nimue-icloud-password:/run/secrets/icloud-password-nimue:ro"
        "/var/lib/openclaw-gateway/merlin-vdirsyncer:/home/node/.config/merlin/vdirsyncer:rw"
        "/var/lib/openclaw-gateway/merlin-khal:/home/node/.config/merlin/khal:rw"
        "/var/lib/openclaw-gateway/merlin-gogcli:/home/node/.config/merlin/gogcli:rw"
        "/var/lib/openclaw-gateway/nimue-vdirsyncer:/home/node/.config/nimue/vdirsyncer:rw"
        "/var/lib/openclaw-gateway/nimue-khal:/home/node/.config/nimue/khal:rw"
        "/var/lib/openclaw-gateway/nimue-gogcli:/home/node/.config/nimue/gogcli:rw"
      ];
      user = "node";
      labels = [
        "com.centurylinklabs.watchtower.enable=false"
      ];
    };
    ncps = {
      image = "kalbasit/ncps:v0.6.1";
      container_name = "ncps";
      restart = "unless-stopped";
      ports = [
        "8501:8501"
      ];
      volumes = [
        "/var/lib/ncps:/storage"
        "/var/lib/ncps-db:/dbstorage"
        "/run/agenix/ncps-key:/run/secrets/ncps-key:ro"
      ];
      entrypoint = [
        "/bin/ncps"
      ];
      command = [
        "serve"
        "--cache-hostname=hsb0.lan"
        "--cache-database-url=sqlite:/dbstorage/db.sqlite?_pragma=foreign_keys(1)"
        "--cache-storage-local=/storage"
        "--cache-temp-path=/tmp"
        "--server-addr=0.0.0.0:8501"
        "--cache-allow-put-verb"
        "--cache-max-size=42G"
        "--cache-lru-schedule=0 */6 * * *"
        "--cache-secret-key-path=/run/secrets/ncps-key"
        "--cache-upstream-url=https://cache.nixos.org"
        "--cache-upstream-public-key=cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      ];
      environment = [
        "NCPS_LOG_LEVEL=info"
        "ANALYTICS_REPORTING_ENABLED=false"
        "GODEBUG=http2client=0"
      ];
    };
    speedtest-tracker = {
      image = "lscr.io/linuxserver/speedtest-tracker:latest";
      container_name = "speedtest-tracker";
      restart = "unless-stopped";
      ports = [
        "8765:80"
      ];
      volumes = [
        "/var/lib/speedtest-tracker:/config"
        "/run/agenix/hsb0-speedtest-tracker-app-key:/run/secrets/speedtest-tracker-app-key:ro"
      ];
      environment = [
        "PUID=1000"
        "PGID=1000"
        "TZ=Europe/Vienna"
        "FILE__APP_KEY=/run/secrets/speedtest-tracker-app-key"
        "APP_URL=http://hsb0.lan:8765"
        "DB_CONNECTION=sqlite"
        "SPEEDTEST_SCHEDULE=*/15 * * * *"
        "SPEEDTEST_SERVERS=45732"
      ];
      labels = [
        "traefik.enable=false"
        "com.centurylinklabs.watchtower.enable=true"
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
        "/run/agenix/pharos-beacon-hsb0-env"
      ];
      environment = [
        "PHAROS_URL=http://100.64.0.4:8088"
        "PHAROS_INTERVAL=60"
        "PHAROS_HOSTNAME=hsb0"
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
      ];
    };
    hsb0-home = {
      image = "nginx:alpine";
      container_name = "hsb0-home";
      restart = "unless-stopped";
      ports = [
        "80:80"
      ];
      environment = [
        "TZ=Europe/Vienna"
      ];
      volumes = [
        "/etc/hostdash/hsb0/share/hostdash-hsb0:/usr/share/nginx/html:ro"
        "/var/lib/hostdash-status:/srv/hostdash-status:ro"
        "/etc/hostdash-nginx.conf:/etc/nginx/conf.d/default.conf:ro"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=true"
        "traefik.enable=false"
      ];
    };
    watchtower = {
      image = "beatkind/watchtower:latest";
      container_name = "watchtower";
      restart = "unless-stopped";
      command = "--schedule \"0 0 5 * * 6\" --label-enable";
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock:rw"
      ];
      environment = [
        "TZ=Europe/Vienna"
        "WATCHTOWER_CLEANUP=true"
        "DOCKER_API_VERSION=1.44"
      ];
    };
  };
}
