# HAUSV-918 / OPS-675: eval-only retirement contract. The optional config is
# the full csb1 NixOS config in CI; the default checks the real host declarations
# without private inputs, a build, or permission to contact a running host.
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
  backup = builtins.readFile ../hosts/csb1/docker/restic-cron/hetzner/run_backup.sh;
  dynamic = builtins.readFile ../hosts/csb1/docker/traefik/dynamic.yml;
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
  # Service inventory before HAUSV-918. Keep the set explicit without freezing
  # unrelated release pins; those retain their own independent update gates.
  existingServices = [
    "aeon"
    "aeon-db"
    "barta-public"
    "bytepoets-memorial"
    "docker-proxy-traefik"
    "docmost"
    "docmost-db"
    "docmost-redis"
    "excalidraw"
    "hausv-postgres"
    "hostdash"
    "hostdash-auth"
    "inspr-auth"
    "inspr-www"
    "janus"
    "janus-engine-staged"
    "janus-managed-canary"
    "janus-managed-transactiond"
    "janus-placeholder"
    "jhw22-wp"
    "jobs-at"
    "minio"
    "paimos-www"
    "paperless"
    "paperless-db"
    "paperless-gotenberg"
    "paperless-redis"
    "paperless-tika"
    "pharos-beacon"
    "pharosd"
    "restic-cron-hetzner"
    "smtp"
    "traefik"
    "zitadel"
    "zitadel-postgres"
  ];
  alerts =
    if config != null then
      config.systemd.services.hausv-alerts
    else
      (import ../hosts/csb1/hausv-alerts.nix {
        pkgs.python3 = "/test-python";
        config = { };
      }).systemd.services.hausv-alerts;
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
      pause.image == spec.services.jhw22-wp.image
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
      && !(pause ? ports);
    fallbackRouters =
      labels."traefik.http.routers.hausv-pause.rule" == rule
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
    existingContainerSetUnchanged =
      builtins.attrNames (builtins.removeAttrs spec.services [ "hausv-pause" ]) == existingServices;
    snapshotRetired =
      !(host.systemd.services ? hausv-backup-snapshot)
      && !(host.systemd.timers ? hausv-backup-snapshot)
      && !(contains "hausv-backup-snapshot.service" (builtins.toJSON host.systemd.timers));
    dataKept = builtins.all (rule: builtins.elem rule host.systemd.tmpfiles.rules) [
      "d /var/lib/csb1-docker/hausv-org 0750 65532 65532 -"
      "d /var/lib/csb1-docker/hausv-org-backup-snapshot 0700 root root -"
    ];
    resticCoverage =
      builtins.elem "/var/lib/csb1-docker:/backup/var/lib/csb1-docker:ro" spec.services.restic-cron-hetzner.volumes
      && contains "/backup/var/lib/csb1-docker /backup/home" backup
      && !(contains "--exclude '/backup/var/lib/csb1-docker/hausv-org'" backup);
    monitorUpdated = contains " --placeholder" alerts.serviceConfig.ExecStart;
    sharedRedirectKept =
      contains "Host(`jhw22.hausv.org`)" dynamic
      && contains "barta" dynamic
      && contains "priority: 1" dynamic;
  };
in
assert builtins.all (check: check) (builtins.attrValues checks);
checks
