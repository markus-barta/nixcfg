# hsb9 container stack — the compose spec, authored in Nix (OPS-116).
#
# Replaces hosts/hsb9/docker/docker-compose.yml. Rendered into the closure and
# reconciled at switch by modules/shared/compose-stack, so a resolver-policy
# change can no longer strand a running container (OPS-113).
#
# 🔴 `dns` / `dns_search` MUST NOT appear here — the module injects them from
# config.networking.nameservers into every network_mode: host service.
#
# 🔴 project is "docker", not "hsb9". 4 relative paths (./mounts/...), hence
# projectDirectory. Remote site (parents-in-law) with no notification channel of
# its own — verify Home Assistant answers before walking away.
#
# Verify any change with:
#   nix shell nixpkgs#yq-go -c ./tests/compose_stack_gate.py hsb9
# Incident-history comments carried over from the retired yml (OPS-127).
#
# Dropped (now supplied by the composeStack module):
#   homeassistant.dns = ['1.1.1.1', '1.0.0.1']
#   homeassistant.dns_search = ['lan']
#   pharos-beacon.dns = ['1.1.1.1', '1.0.0.1']
#   pharos-beacon.dns_search = ['lan']
#   x-host-dns (anchor)
#   x-host-dns-search (anchor)

# ── carried from the retired docker-compose.yml ──
# hsb9 docker services — parents-in-law home automation (NIX-139)
#
# Lightweight stack vs hsb1: just MQTT broker + Home Assistant for now.
# Zigbee2MQTT is scaffolded below but DISABLED until the SONOFF Zigbee 3.0
# dongle is migrated from the Pi 3 (NIX-140). HomeKit is NOT a separate
# container — it's Home Assistant's built-in HomeKit Bridge integration,
# configured in the HA UI once HA is up.
#
# DEPLOY VERB (OPS-124): `just switch`. The stack is rendered into the closure
# and reconciled by compose-hsb9.service — never `docker compose up` by hand;
# the file compose actually runs is /etc/compose/hsb9/docker-compose.yml.
{
  services = {
    mosquitto = {
      image = "eclipse-mosquitto:latest";
      container_name = "mosquitto";
      restart = "unless-stopped";
      ports = [
        "1883:1883"
      ];
      volumes = [
        "./mounts/mosquitto/config/mosquitto.conf:/mosquitto/config/mosquitto.conf"
        "./mounts/mosquitto/config/mosquitto_passwd:/mosquitto/config/mosquitto_passwd"
        "./mounts/mosquitto/data:/mosquitto/data"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=true"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    homeassistant = {
      container_name = "homeassistant";
      image = "ghcr.io/home-assistant/home-assistant:stable";
      depends_on = [
        "mosquitto"
      ];
      volumes = [
        "./mounts/homeassistant:/config"
        "/etc/localtime:/etc/localtime:ro"
        "/run/dbus:/run/dbus:ro"
      ];
      restart = "unless-stopped";
      privileged = true;
      network_mode = "host";
      environment = [
        "TZ=Europe/Vienna"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=true"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    # Pharos beacon (PHAROS-6) — reports this host's status + nix freshness to
    # pharosd (csb1) every 60s.
    pharos-beacon = {
      image = "ghcr.io/inspr-at/pharos/pharosd:0.1.87@sha256:0124a6a745808a5e465934a7b1052feec9e48a01eaf5e357b7ee898cb63dfb32";
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
        "/run/agenix/pharos-beacon-hsb9-env"
      ];
      environment = [
        "PHAROS_URL=http://100.64.0.4:8088"
        "PHAROS_INTERVAL=60"
        "PHAROS_HOSTNAME=hsb9"
        "PHAROS_CURRENT_KERNEL_MODULES_DIR=/host/run/current-system/kernel-modules/lib/modules"
        "PHAROS_NIX_DEPLOYMENT_EVIDENCE_FILE=/host/pharos-deployment/evidence.json"
        "PHAROS_NIXCFG_REMOTE_URL=https://github.com/markus-barta/nixcfg.git"
        "PHAROS_NIXCFG_REMOTE_REF=refs/heads/main"
        "PHAROS_NIXPKGS_REMOTE_URL=https://github.com/NixOS/nixpkgs.git"
        "NIXCFG_DIR=/nixcfg"
        "GIT_CONFIG_COUNT=1"
        "GIT_CONFIG_KEY_0=safe.directory"
        "GIT_CONFIG_VALUE_0=/nixcfg"
        # OPS-53: read the restic status file for backup posture reporting
        "PHAROS_BACKUP_MODE=status-file"
        "PHAROS_BACKUP_STATUS_FILE=/pharos-backup-status/restic-cron-hetzner.json"
      ];
      volumes = [
        "/home/mba/Code/nixcfg:/nixcfg:ro"
        "/run/pharos-deployment:/host/pharos-deployment:ro" # OPS-186: directory, not the file — see flake.nix activation script
        "/etc/NIXOS:/etc/NIXOS:ro"
        "/run/current-system/kernel-modules/lib/modules:/host/run/current-system/kernel-modules/lib/modules:ro"
        "/var/lib/hsb9-docker/pharos-backup-status:/pharos-backup-status:ro"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    # OPS-53: off-box restic backups (HA config + mosquitto + /etc) to the
    # shared Hetzner storagebox, per-host subpath /hsb9. Reporting is the
    # Pharos status-file dead-man's-switch — NO mail on family servers
    # (OPS-137 architecture decision). Mirrors hsb0 (PR #213/#214 generation).
    restic-cron-hetzner = {
      build = "./restic-cron";
      container_name = "restic-cron-hetzner";
      restart = "unless-stopped";
      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "./mounts/homeassistant:/backup/mounts/homeassistant:ro"
        "./mounts/mosquitto:/backup/mounts/mosquitto:ro"
        "/etc:/backup/etc:ro"
        "/run/agenix/restic-hetzner-ssh-key:/root/.ssh/id_rsa:ro"
        "./restic-cron/ssh_known_hosts:/root/.ssh/known_hosts:ro"
        "./restic-cron/hetzner/run_backup.sh:/usr/local/bin/run_backup.sh:ro"
        "./restic-cron/hetzner/run_check.sh:/usr/local/bin/run_check.sh:ro"
        "./restic-cron/hetzner/run_cleanup.sh:/usr/local/bin/run_cleanup.sh:ro"
        "./restic-cron/hetzner/start_cron.sh:/usr/local/bin/start_cron.sh:ro"
        "/var/lib/hsb9-docker/pharos-backup-status:/pharos-backup-status"
      ];
      environment = {
        RESTIC_REPOSITORY = "sftp:u387549-sub1@u387549.your-storagebox.de:23/hsb9";
        CRON_BACKUP_EXPRESSION = "0 3 * * *";
        PHAROS_BACKUP_STATUS_FILE = "/pharos-backup-status/restic-cron-hetzner.json";
      };
      env_file = [
        "/run/agenix/restic-hetzner-env"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false"
      ];
    };
    # hsb9-home — HostDash service landing page for this host. Static HTML/CSS/JS
    # served by nginx on :80, built from markus-barta/hostdash via Nix and mounted
    # read-only from /etc.
    hsb9-home = {
      image = "nginx:alpine";
      container_name = "hsb9-home";
      restart = "unless-stopped";
      ports = [
        "80:80"
      ];
      environment = [
        "TZ=Europe/Vienna"
      ];
      volumes = [
        "/etc/hostdash/hsb9/share/hostdash-hsb9:/usr/share/nginx/html:ro"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=true"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
  };
}
