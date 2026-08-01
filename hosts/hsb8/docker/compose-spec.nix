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
        "/run/agenix/pharos-beacon-hsb8-env"
      ];
      environment = [
        "PHAROS_URL=http://100.64.0.4:8088"
        "PHAROS_INTERVAL=60"
        "PHAROS_HOSTNAME=hsb8"
        "PHAROS_PREFERENCES_FILE=/etc/pharos/host-preferences.json"
        "PHAROS_CURRENT_KERNEL_MODULES_DIR=/host/run/current-system/kernel-modules/lib/modules"
        "NIXCFG_DIR=/nixcfg"
        "GIT_CONFIG_COUNT=1"
        "GIT_CONFIG_KEY_0=safe.directory"
        "GIT_CONFIG_VALUE_0=/nixcfg"
      ];
      volumes = [
        "/home/mba/Code/nixcfg:/nixcfg:ro"
        "/etc/NIXOS:/etc/NIXOS:ro"
        "/etc/pharos/host-preferences.json:/etc/pharos/host-preferences.json:ro"
        "/run/current-system/kernel-modules/lib/modules:/host/run/current-system/kernel-modules/lib/modules:ro"
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
  };
}
