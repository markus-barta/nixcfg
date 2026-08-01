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
# Comments from the source file are NOT carried across by this tool; re-attach
# them by hand. They hold real incident history.
#
# Dropped (now supplied by the composeStack module):
#   homeassistant.dns = ['1.1.1.1', '1.0.0.1']
#   homeassistant.dns_search = ['lan']
#   pharos-beacon.dns = ['1.1.1.1', '1.0.0.1']
#   pharos-beacon.dns_search = ['lan']
#   x-host-dns (anchor)
#   x-host-dns-search (anchor)

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
        "/run/agenix/pharos-beacon-hsb9-env"
      ];
      environment = [
        "PHAROS_URL=http://100.64.0.4:8088"
        "PHAROS_INTERVAL=60"
        "PHAROS_HOSTNAME=hsb9"
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
      ];
    };
  };
}
