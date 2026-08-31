# hsb8 container stack — the compose spec, authored in Nix (OPS-116).
#
# Replaces hosts/hsb8/docker/docker-compose.yml. Rendered into the closure and
# reconciled at switch by modules/shared/compose-stack, so a resolver-policy
# change can no longer strand a running container (OPS-113).
#
# 🔴 `dns` / `dns_search` MUST NOT appear here — the module injects them from
# config.networking.nameservers into every network_mode: host service.
#
# 🔴 project is "docker", not "hsb8". Zero relative paths, so no projectDirectory
# is needed. The NIX-237 cutover is done — the live homeassistant/mosquitto come
# from this stack with the /srv/hsb8 mounts.
#
# Verify any change with:
#   nix shell nixpkgs#yq-go -c ./tests/compose_stack_gate.py hsb8
# Incident-history comments carried over from the retired yml (OPS-127).
#
# Dropped (now supplied by the composeStack module):
#   pharos-beacon.dns = ['127.0.0.1', '1.1.1.1']
#   pharos-beacon.dns_search = ['local']
#   homeassistant.dns = ['127.0.0.1', '1.1.1.1']
#   homeassistant.dns_search = ['local']
#   x-host-dns (anchor)
#   x-host-dns-search (anchor)

# ── carried from the retired docker-compose.yml ──
# hsb8 docker services.
# fleetcom-agent migrated from /opt/fleetcom-agent/ on 2026-04-19 (NIX-82).
# homeassistant/mosquitto/watchtower migrated from /home/gb/docker/ (NIX-230,
# NIX-234) — same container names + project so bosun wiring keeps working.
#
# The NIX-237 cutover is DONE: the live homeassistant/mosquitto containers are
# created from THIS file, with the /srv/hsb8 mounts NIX-236 moved them to.
# Verified on the host 2026-07-31 (compose project_dir + config_files labels).
# The former cutover guard is removed rather than kept as history — it outlived
# the condition it described by long enough to mislead: reading it during the
# OPS-113 sweep caused homeassistant to be skipped on this host, leaving it the
# only host-network container in the fleet still on an inherited resolver.
#
{
  services = {
    # Pharos beacon (PHAROS-6) — reports this host's status + nix freshness to
    # pharosd (csb1) every 60s; succeeds the FleetCom bosun agent above.
    pharos-beacon = {
      image = "ghcr.io/inspr-at/pharos/pharosd:0.1.95@sha256:0d8029f6142f03c8e7ee51459834658a5444b2da95eba9fbcd5d0de25dd32eb7";
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
        "/run/agenix/pharos-beacon-hsb8-env"
      ];
      environment = [
        "PHAROS_URL=http://100.64.0.4:8088"
        "PHAROS_INTERVAL=60"
        "PHAROS_HOSTNAME=hsb8"
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
        # OPS-53: read the restic status file for backup posture reporting
        "PHAROS_BACKUP_MODE=status-file"
        "PHAROS_BACKUP_STATUS_FILE=/pharos-backup-status/restic-cron-hetzner.json"
      ];
      volumes = [
        "/home/mba/Code/nixcfg:/nixcfg:ro"
        "/run/pharos-deployment:/host/pharos-deployment:ro" # OPS-186: directory, not the file — see flake.nix activation script
        "/etc/NIXOS:/etc/NIXOS:ro"
        "/run/pharos-preferences:/etc/pharos:ro"
        "/run/current-system/kernel-modules/lib/modules:/host/run/current-system/kernel-modules/lib/modules:ro"
        "/var/lib/hsb8-docker/pharos-backup-status:/pharos-backup-status:ro"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    # hsb8-home — HostDash service landing page for this host. Static HTML/CSS/JS
    # served by nginx on :80, built from markus-barta/hostdash via Nix and mounted
    # read-only from /etc.
    hsb8-home = {
      image = "nginx:alpine";
      container_name = "hsb8-home";
      restart = "unless-stopped";
      ports = [
        "80:80"
      ];
      environment = [
        "TZ=Europe/Vienna"
      ];
      volumes = [
        "/etc/hostdash/hsb8/share/hostdash-hsb8:/usr/share/nginx/html:ro"
        "/var/lib/hostdash-status:/srv/hostdash-status:ro"
        "/etc/hostdash-nginx.conf:/etc/nginx/conf.d/default.conf:ro"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=true"
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    homeassistant = {
      container_name = "homeassistant";
      image = "ghcr.io/home-assistant/home-assistant:stable";
      restart = "unless-stopped";
      network_mode = "host";
      privileged = true;
      cap_add = [
        "NET_ADMIN"
        "NET_RAW"
      ];
      environment = [
        "TZ=Europe/Vienna"
      ];
      volumes = [
        "/srv/hsb8/mounts/homeassistant:/config"
        "/run/dbus:/run/dbus:rw"
        "/sys/class/bluetooth:/sys/class/bluetooth:ro"
      ];
      depends_on = [
        "mosquitto"
      ];
      labels = [
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    mosquitto = {
      container_name = "mosquitto";
      image = "eclipse-mosquitto:latest";
      restart = "unless-stopped";
      ports = [
        "1883:1883"
      ];
      volumes = [
        "/srv/hsb8/mounts/mosquitto/config:/mosquitto/config"
        "/srv/hsb8/mounts/mosquitto/data:/mosquitto/data"
        "/srv/hsb8/mounts/mosquitto/log:/mosquitto/log"
      ];
      labels = [
        "com.centurylinklabs.watchtower.scope=weekly"
      ];
    };
    # OPS-53: off-box restic backups (HA config + mosquitto + /etc) to the
    # shared Hetzner storagebox, per-host subpath /hsb8. Reporting is the
    # Pharos status-file dead-man's-switch — NO mail on family servers
    # (OPS-137 architecture decision). Mirrors hsb0 (PR #213/#214 generation).
    restic-cron-hetzner = {
      build = "./restic-cron";
      container_name = "restic-cron-hetzner";
      restart = "unless-stopped";
      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "/srv/hsb8/mounts/homeassistant:/backup/srv/hsb8/mounts/homeassistant:ro"
        "/srv/hsb8/mounts/mosquitto:/backup/srv/hsb8/mounts/mosquitto:ro"
        "/etc:/backup/etc:ro"
        "/run/agenix/restic-hetzner-ssh-key:/root/.ssh/id_rsa:ro"
        "./restic-cron/ssh_known_hosts:/root/.ssh/known_hosts:ro"
        "./restic-cron/hetzner/run_backup.sh:/usr/local/bin/run_backup.sh:ro"
        "./restic-cron/hetzner/run_check.sh:/usr/local/bin/run_check.sh:ro"
        "./restic-cron/hetzner/run_cleanup.sh:/usr/local/bin/run_cleanup.sh:ro"
        "./restic-cron/hetzner/start_cron.sh:/usr/local/bin/start_cron.sh:ro"
        "/var/lib/hsb8-docker/pharos-backup-status:/pharos-backup-status"
      ];
      environment = {
        RESTIC_REPOSITORY = "sftp:u387549-sub1@u387549.your-storagebox.de:23/hsb8";
        CRON_BACKUP_EXPRESSION = "30 2 * * *";
        PHAROS_BACKUP_STATUS_FILE = "/pharos-backup-status/restic-cron-hetzner.json";
      };
      env_file = [
        "/run/agenix/restic-hetzner-env"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false"
      ];
    };
  };
}
