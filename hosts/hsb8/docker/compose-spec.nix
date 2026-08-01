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
# Comments from the source file are NOT carried across by this tool; re-attach
# them by hand. They hold real incident history.
#
# Dropped (now supplied by the composeStack module):
#   pharos-beacon.dns = ['127.0.0.1', '1.1.1.1']
#   pharos-beacon.dns_search = ['local']
#   homeassistant.dns = ['127.0.0.1', '1.1.1.1']
#   homeassistant.dns_search = ['local']
#   x-host-dns (anchor)
#   x-host-dns-search (anchor)

{
  services = {
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
    watchtower = {
      container_name = "watchtower";
      image = "beatkind/watchtower:latest";
      restart = "unless-stopped";
      command = "--schedule \"0 0 5 * * 6\" --cleanup --scope weekly";
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock:rw"
      ];
      environment = [
        "TZ=Europe/Vienna"
        "WATCHTOWER_CLEANUP=true"
        "DOCKER_API_VERSION=1.44"
        "WATCHTOWER_SCOPE=weekly"
        "WATCHTOWER_NOTIFICATIONS=shoutrrr"
        "WATCHTOWER_NOTIFICATIONS_HOSTNAME=hsb8"
        "WATCHTOWER_NOTIFICATION_TITLE_TAG=🏡"
        "WATCHTOWER_HTTP_API_UPDATE=true"
        "WATCHTOWER_HTTP_API_PERIODIC_POLLS=true"
      ];
      env_file = [
        "/run/agenix/hsb8-watchtower-env"
      ];
    };
  };
}
