# HAUSV-918 / OPS-675: the placeholder's own permanent eval-only contract.
# Unrelated service inventory and backup coverage are one-off review evidence.
# The optional config is the full csb1 NixOS config in CI; the default needs
# no private inputs, build, or permission to contact a running host.
{
  config ? null,
  spec ?
    if config == null then
      import ../hosts/csb1/docker/compose-spec.nix
    else
      config.nixcfg.composeStack.spec,
  pageContents ? builtins.readFile ../hosts/csb1/docker/hausv-pause/index.html,
}:
let
  host =
    if config != null then
      config
    else
      import ../hosts/csb1/configuration.nix {
        pkgs = { };
        lib = { };
        config = { };
        inputs = { };
      };
  pause = spec.services.hausv-pause;
  page = ../hosts/csb1/docker/hausv-pause/index.html;
  nginxFile = ../hosts/csb1/docker/hausv-pause/nginx.conf;
  nginx = builtins.readFile nginxFile;
  contains = needle: value: builtins.replaceStrings [ needle ] [ "" ] value != value;
  labels = builtins.listToAttrs (
    map (
      label:
      let
        pair = builtins.match "([^=]+)=(.*)" label;
      in
      {
        name = builtins.elemAt pair 0;
        value = builtins.elemAt pair 1;
      }
    ) pause.labels
  );
  rule = "Host(`hausv-legacy.barta.cm`) || Host(`jhw22.hausv.org`)";
  checks = {
    approvedBytes =
      builtins.stringLength pageContents == 1312
      &&
        builtins.hashString "sha256" pageContents
        == "93c666253bcbc2cf74c04551317054e1928b24e65191b250d7bc9e75331fa184";
    immutableMounts =
      pause.volumes == [
        "${page}:/usr/share/nginx/html/index.html:ro"
        "${nginxFile}:/etc/nginx/nginx.conf:ro"
      ];
    allPaths =
      contains "try_files /index.html =500;" nginx
      && contains "default_type text/html;" nginx
      && contains "charset utf-8;" nginx
      && contains ''add_header X-Robots-Tag "noindex" always;'' nginx
      && contains ''add_header Cache-Control "no-store, no-transform" always;'' nginx
      && contains "server_tokens off;" nginx
      && contains "error_page 405 =200 /index.html;" nginx
      && contains "etag off;" nginx
      && contains "if_modified_since off;" nginx
      && contains "max_ranges 0;" nginx;
    healthMarker =
      contains "location = /healthz" nginx
      && contains ''return 200 "hausv-pause ok\n";'' nginx
      &&
        pause.healthcheck.test == [
          "CMD-SHELL"
          "wget -q -O - http://127.0.0.1:8080/healthz | grep -Fxq 'hausv-pause ok'"
        ];
    hardened =
      builtins.match "nginx:stable-alpine@sha256:[0-9a-f]{64}" pause.image != null
      && pause.read_only
      && pause.user == "101:101"
      && pause.cap_drop == [ "ALL" ]
      && !(pause ? cap_add)
      && pause.security_opt == [ "no-new-privileges:true" ]
      && pause.mem_limit == "32m"
      && pause.pids_limit == 32
      && pause.entrypoint == [ "nginx" ]
      &&
        pause.command == [
          "-g"
          "daemon off;"
        ]
      && pause.networks == [ "traefik" ]
      &&
        pause.tmpfs == [
          "/tmp:rw,noexec,nosuid,nodev,size=8m,mode=1777"
          "/var/cache/nginx:rw,noexec,nosuid,nodev,size=8m,uid=101,gid=101,mode=0700"
        ]
      && !(pause ? ports);
    fallbackRouters =
      labels."traefik.enable" == "true"
      && labels."traefik.docker.network" == "traefik"
      && labels."traefik.http.routers.hausv-pause.rule" == rule
      && labels."traefik.http.routers.hausv-pause-http.rule" == rule
      && (labels."traefik.http.routers.hausv-pause.priority" or "0") == "1"
      && (labels."traefik.http.routers.hausv-pause-http.priority" or "0") == "1"
      && labels."traefik.http.routers.hausv-pause.entrypoints" == "web-secure"
      && labels."traefik.http.routers.hausv-pause-http.entrypoints" == "web"
      && labels."traefik.http.routers.hausv-pause.tls" == "true"
      && labels."traefik.http.routers.hausv-pause.tls.certresolver" == "default"
      && labels."traefik.http.routers.hausv-pause.middlewares" == "hausv-hsts@file"
      && labels."traefik.http.routers.hausv-pause-http.middlewares" == "hausv-pause-https@docker"
      && labels."traefik.http.middlewares.hausv-pause-https.redirectscheme.scheme" == "https"
      && labels."traefik.http.services.hausv-pause.loadbalancer.server.port" == "8080";
    snapshotRetired =
      !(host.systemd.services ? hausv-backup-snapshot) && !(host.systemd.timers ? hausv-backup-snapshot);
  };
in
assert builtins.all (check: check) (builtins.attrValues checks);
checks
