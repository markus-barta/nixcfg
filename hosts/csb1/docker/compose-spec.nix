# csb1 container stack — the compose spec, authored in Nix (OPS-116).
#
# Replaces hosts/csb1/docker/docker-compose.yml. Rendered into the closure and
# reconciled at switch by modules/shared/compose-stack, so a resolver-policy
# change can no longer strand a running container (OPS-113).
#
# 🔴 `dns` / `dns_search` MUST NOT appear here — the module injects them from
# config.networking.nameservers into every network_mode: host service.
#
# Largest stack. Live data in paperless/docmost/postgres/minio on csb1_* named
# volumes — the project name is load-bearing above all other hosts.
# janus-managed-canary is network_mode: none and gets no DNS injection.
# traefik holds a STATIC IP on hausv-proxy (10.253.254.2).
#
# Verify any change with:
#   nix shell nixpkgs#yq-go -c ./tests/compose_stack_gate.py csb1
# Incident-history comments carried over from the retired yml (OPS-127).

# Incident-history comments carried over from the retired yml (OPS-127).
# Compose project name: csb1 — named volumes depend on it.

# ── carried from the retired docker-compose.yml ──
# csb1 main docker stack — git-tracked (NIX-110 migration)
#
# Previously at /home/mba/docker/docker-compose.yml; now lives in nixcfg
# matching the csb0 pattern. Deploy with:
#   cd ~/Code/nixcfg/hosts/csb1/docker && docker compose up -d
#
# Project name preserved as `csb1` so all named volumes (csb1_*) and
# networks (csb1_*) survive the cutover without data migration.
#
# Secrets: ALL env_files now use /run/agenix/... paths (M4 migration of
# the loose ~/secrets/ and ./xxx.env files into agenix). Container reads
# at runtime via agenix-decrypted bind. No plaintext secrets in this file.
let
  # NIX-381 — the same file hosts/csb1/configuration.nix wires the two adapter
  # modules from, so the compose side and the module side share one switch.
  #
  # 🔴 Why this is conditional and not simply present: pharosd v0.1.83 PANICS
  # when PHAROS_PAIMOS_DELIVERY_CONFIG_FILE is set and the config, the API key
  # or any 32-byte handoff secret is missing or has the wrong owner/mode. An
  # unconditional env var would therefore crash-loop the live fleet dashboard
  # from the moment this lands until credentials exist. Absent = adapter off,
  # which is exactly the pre-NIX-381 behaviour.
  paimos = import ../paimos-delivery-stage.nix;
  paimosDeliveryEnvironment =
    if paimos.active then [ "PHAROS_PAIMOS_DELIVERY_CONFIG_FILE=${paimos.pharos.configFile}" ] else [ ];
  # Each credential is its own inode: pharosd compares (device, inode) and
  # refuses a shared API-key/handoff file. Read-only, create_host_path false, so
  # a missing source fails the container start instead of silently binding an
  # empty directory over the mount point.
  privateBind = source: target: {
    type = "bind";
    inherit source target;
    read_only = true;
    bind = {
      create_host_path = false;
    };
  };
  paimosDeliveryVolumes =
    if paimos.active then
      [
        (privateBind paimos.pharos.configFile paimos.pharos.configFile)
        (privateBind paimos.pharos.hostApiKeyFile paimos.pharos.apiKeyFile)
        (privateBind paimos.pharos.hostDeploymentHandoffSecretFile paimos.pharos.deploymentHandoffSecretFile)
        (privateBind paimos.pharos.hostVerificationHandoffSecretFile paimos.pharos.verificationHandoffSecretFile)
      ]
    else
      [ ];
in
{
  name = "csb1";
  services = {
    docmost-db = {
      image = "postgres:16-alpine";
      env_file = [
        "/run/agenix/csb1-docmost-postgres-env"
      ];
      volumes = [
        "docmost_db_data:/var/lib/postgresql/data"
      ];
      restart = "unless-stopped";
      networks = [
        "internal"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false" # OPS-125: composeStack owns this service's image
        "traefik.enable=false"
      ];
    };
    docmost-redis = {
      image = "redis:7-alpine";
      restart = "unless-stopped";
      volumes = [
        "docmost_redis_data:/data"
      ];
      networks = [
        "internal"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false" # OPS-125: composeStack owns this service's image
        "traefik.enable=false"
      ];
    };
    docmost = {
      image = "docmost/docmost:latest";
      restart = "unless-stopped";
      depends_on = [
        "docmost-db"
        "docmost-redis"
      ];
      env_file = [
        "/run/agenix/csb1-docmost-config-env"
      ];
      volumes = [
        "docmost_data:/app/data/storage"
      ];
      networks = [
        "internal"
        "traefik"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false" # OPS-125: composeStack owns this service's image
        "traefik.enable=true"
        "traefik.http.routers.docmost.rule=Host(`docmost.barta.cm`)"
        "traefik.http.routers.docmost.tls.certresolver=default"
        "traefik.http.routers.docmost.tls=true"
        "traefik.http.services.docmost.loadbalancer.server.port=3000"
        "traefik.docker.network=csb1_traefik"
        "traefik.http.routers.docmost.middlewares=cloudflarewarp@file"
      ];
    };
    # --- Paperless-ngx Services Begin ---
    paperless-db = {
      image = "postgres:16-alpine";
      restart = "unless-stopped";
      env_file = [
        "/run/agenix/csb1-paperless-postgres-env"
      ];
      volumes = [
        "paperless_db_data:/var/lib/postgresql/data"
      ];
      networks = [
        "internal"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false" # OPS-125: composeStack owns this service's image
        "traefik.enable=false"
      ];
    };
    paperless-redis = {
      image = "redis:7-alpine";
      restart = "unless-stopped";
      volumes = [
        "paperless_redis_data:/data"
      ];
      networks = [
        "internal"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false" # OPS-125: composeStack owns this service's image
        "traefik.enable=false"
      ];
    };
    paperless-tika = {
      image = "apache/tika:latest"; # image no longer available here... ghcr.io/paperless-ngx/tika:latest
      restart = "unless-stopped";
      networks = [
        "internal"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false" # OPS-125: composeStack owns this service's image
        "traefik.enable=false"
      ];
    };
    paperless-gotenberg = {
      image = "gotenberg/gotenberg:8";
      restart = "unless-stopped";
      command = [
        "gotenberg"
        "--chromium-disable-routes=true"
      ];
      networks = [
        "internal"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false" # OPS-125: composeStack owns this service's image
        "traefik.enable=false"
      ];
    };
    paperless = {
      image = "ghcr.io/paperless-ngx/paperless-ngx:latest";
      restart = "unless-stopped";
      depends_on = [
        "paperless-db"
        "paperless-redis"
        "paperless-tika"
        "paperless-gotenberg"
      ];
      env_file = [
        "/run/agenix/csb1-paperless-config-env"
      ];
      volumes = [
        "paperless_data:/usr/src/paperless/data"
        "paperless_media:/usr/src/paperless/media"
        "paperless_consume:/usr/src/paperless/consume"
      ];
      environment = [
        "TZ=Europe/Vienna"
        "PAPERLESS_TIKA_ENABLED=1"
        "PAPERLESS_TIKA_ENDPOINT=http://paperless-tika:9998"
        "PAPERLESS_GOTENBERG_ENDPOINT=http://paperless-gotenberg:3000"
      ];
      networks = [
        "internal"
        "traefik"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false" # OPS-125: composeStack owns this service's image
        "traefik.enable=true"
        "traefik.http.routers.paperless.rule=Host(`paperless.barta.cm`)"
        "traefik.http.routers.paperless.tls.certresolver=default"
        "traefik.http.routers.paperless.tls=true"
        "traefik.http.services.paperless.loadbalancer.server.port=8000"
        "traefik.docker.network=csb1_traefik"
        "traefik.http.routers.paperless.middlewares=cloudflarewarp@file"
      ];
    };
    # NIX-367 / HAUSV-495: Phase-0 PostgreSQL target. HAUSV deliberately has
    # no dependency on this service and receives no database configuration;
    # SQLite remains the live source of truth. The existing external
    # hausv-egress network only makes this service reachable for a future,
    # separately reviewed cutover without publishing port 5432 on the host.
    hausv-postgres = {
      image = "postgres:17-alpine";
      container_name = "hausv-postgres";
      restart = "unless-stopped";
      stop_grace_period = "1m";
      environment = [
        "POSTGRES_USER=postgres"
        "POSTGRES_DB=hausv"
        "POSTGRES_PASSWORD_FILE=/run/secrets/hausv-postgres-admin-password"
      ];
      volumes = [
        "hausv_postgres_data:/var/lib/postgresql/data"
        "./hausv-postgres/init-application-role.sh:/docker-entrypoint-initdb.d/10-application-role.sh:ro"
        "./hausv-postgres/init-backup-role.sh:/docker-entrypoint-initdb.d/20-backup-role.sh:ro"
        "./hausv-postgres/dump-as-backup-role.sh:/usr/local/bin/hausv-dump-as-backup-role:ro"
        {
          type = "bind";
          source = "/run/agenix/csb1-hausv-postgres-admin-password";
          target = "/run/secrets/hausv-postgres-admin-password";
          read_only = true;
          bind.create_host_path = false;
        }
        {
          type = "bind";
          source = "/run/agenix/csb1-hausv-postgres-app-password";
          target = "/run/secrets/hausv-postgres-app-password";
          read_only = true;
          bind.create_host_path = false;
        }
        {
          type = "bind";
          source = "/run/agenix/csb1-hausv-postgres-backup-password";
          target = "/run/secrets/hausv-postgres-backup-password";
          read_only = true;
          bind.create_host_path = false;
        }
      ];
      networks = [
        "hausv-egress"
      ];
      healthcheck = {
        test = [
          "CMD-SHELL"
          ''pg_isready -U postgres -d hausv && test "$(psql -U postgres -d hausv -Atqc "SELECT NOT rolsuper AND NOT rolbypassrls FROM pg_roles WHERE rolname='hausv_app'")" = t''
        ];
        interval = "30s";
        timeout = "5s";
        retries = 5;
        start_period = "20s";
      };
      labels = [
        "com.centurylinklabs.watchtower.enable=false"
        "traefik.enable=false"
      ];
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
        "com.centurylinklabs.watchtower.enable=false" # OPS-125: composeStack owns this service's image
        "traefik.enable=false"
      ];
    };
    # https://docs.traefik.io/v2.5/providers/docker/
    # ACME state lives below ./traefik/ (gitignored, mutable LE cert state).
    # The dedicated HTTP-challenge store serves public DNS zones that are not
    # managed through the Cloudflare credentials used by the default resolver.
    traefik = {
      image = "traefik";
      command = "--providers.docker";
      restart = "always";
      depends_on = [
        "docker-proxy-traefik"
      ];
      ports = [
        "80:80"
        "443:443/tcp"
        "443:443/udp"
      ];
      # - "8883:8883" #todo: enable if mosquitto installed
      networks = {
        traefik = null;
        docker-sock-traefik = null;
        hausv-proxy = {
          ipv4_address = "10.253.254.2";
        };
      };
      volumes = [
        "./traefik/static.yml:/etc/traefik/traefik.yml"
        "./traefik/dynamic.yml:/etc/traefik/dynamic/dynamic.yml"
        "./traefik/acme.json:/etc/traefik/acme/acme.json:rw"
        "./traefik/acme-http.json:/etc/traefik/acme/acme-http.json:rw"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false" # OPS-125: composeStack owns this service's image
        "traefik.http.routers.traefik.rule=Host(`cs1.barta.cm`) && (PathPrefix(`/api`) || PathPrefix(`/dashboard`))"
        "traefik.http.routers.traefik.entrypoints=web-secure"
        "traefik.http.routers.traefik.service=api@internal"
        "traefik.http.routers.traefik.tls.certresolver=default"
        "traefik.http.routers.traefik.tls=true"
        "traefik.http.routers.traefik.priority=100"
      ];
      # - traefik.http.routers.traefik.middlewares=authelia  # DISABLED 2026-03-06 - no authelia container
      environment = [
        "TZ=Europe/Vienna"
      ];
      env_file = [
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
        "--redirect-url=https://cs1.barta.cm/oauth2/callback"
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
        "traefik.http.routers.hostdash-auth-csb1.rule=Host(`cs1.barta.cm`) && PathPrefix(`/oauth2`)"
        "traefik.http.routers.hostdash-auth-csb1.entrypoints=web-secure"
        "traefik.http.routers.hostdash-auth-csb1.tls=true"
        "traefik.http.routers.hostdash-auth-csb1.tls.certresolver=default"
        "traefik.http.routers.hostdash-auth-csb1.priority=250"
        "traefik.http.services.hostdash-auth-csb1.loadbalancer.server.port=4180"
        "traefik.docker.network=csb1_traefik"
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
        "/etc/hostdash/csb1/share/hostdash-csb1:/usr/share/nginx/html:ro"
      ];
      networks = [
        "traefik"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false" # OPS-125: composeStack owns this service's image
        "traefik.enable=true"
        "traefik.http.routers.hostdash-csb1.rule=Host(`cs1.barta.cm`)"
        "traefik.http.routers.hostdash-csb1.entrypoints=web-secure"
        "traefik.http.routers.hostdash-csb1.tls=true"
        "traefik.http.routers.hostdash-csb1.tls.certresolver=default"
        "traefik.http.routers.hostdash-csb1.priority=10"
        "traefik.http.routers.hostdash-csb1.middlewares=hostdash-auth-csb1@docker"
        "traefik.http.middlewares.hostdash-auth-csb1.forwardauth.address=http://hostdash-auth:4180/"
        "traefik.http.middlewares.hostdash-auth-csb1.forwardauth.trustForwardHeader=true"
        "traefik.http.middlewares.hostdash-auth-csb1.forwardauth.authResponseHeaders=X-Auth-Request-User,X-Auth-Request-Email"
        "traefik.http.services.hostdash-csb1.loadbalancer.server.port=80"
        "traefik.docker.network=csb1_traefik"
        "traefik.http.routers.hostdash-csb1-http.rule=Host(`cs1.barta.cm`)"
        "traefik.http.routers.hostdash-csb1-http.entrypoints=web"
        "traefik.http.routers.hostdash-csb1-http.middlewares=hostdash-csb1-https@docker"
        "traefik.http.middlewares.hostdash-csb1-https.redirectscheme.scheme=https"
        "traefik.http.middlewares.hostdash-csb1-https.redirectscheme.permanent=true"
        "traefik.http.routers.hostdash-csb1-ip.rule=Host(`152.53.64.166`) || Host(`100.64.0.4`)"
        "traefik.http.routers.hostdash-csb1-ip.entrypoints=web"
        "traefik.http.routers.hostdash-csb1-ip.priority=200"
        "traefik.http.routers.hostdash-csb1-ip.middlewares=hostdash-csb1-ip-canonical@docker"
        "traefik.http.routers.hostdash-csb1-ip.service=hostdash-csb1"
        "traefik.http.middlewares.hostdash-csb1-ip-canonical.redirectregex.regex=^http://[^/]+/(.*)"
        "traefik.http.middlewares.hostdash-csb1-ip-canonical.redirectregex.replacement=https://cs1.barta.cm/$\${1}"
        "traefik.http.middlewares.hostdash-csb1-ip-canonical.redirectregex.permanent=true"
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
        "SMARTHOST_ADDRESS=smtp.resend.com" # OPS-175: Resend, per-host key, sender domain barta.cm
        "SMARTHOST_PORT=587"
        "SMARTHOST_USER=resend"
        "SMARTHOST_ALIASES=*"
        "RELAY_NETWORKS=:172.0.0.0/8"
      ];
      env_file = [
        "/run/agenix/csb1-mailrelay-env" # SMARTHOST_PASSWORD=<Resend key>
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false" # OPS-125: composeStack owns this service's image
        "traefik.enable=false"
      ];
    };
    restic-cron-hetzner = {
      build = "./restic-cron";
      restart = "unless-stopped";
      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "/var/lib/docker/volumes:/backup/var/lib/docker/volumes:ro"
        "/var/lib/csb1-docker:/backup/var/lib/csb1-docker:ro"
        "/home:/backup/home:ro"
        "/root:/backup/root:ro"
        "/etc:/backup/etc:ro"
        # SSH private key now sourced from agenix (was: ./restic-cron/id_rsa)
        "/run/agenix/csb1-restic-cron-id-rsa:/root/.ssh/id_rsa:ro"
        "./restic-cron/id_rsa.pub:/root/.ssh/id_rsa.pub:ro"
        "./restic-cron/ssh_known_hosts:/root/.ssh/known_hosts:ro"
        "./restic-cron/hetzner/run_backup.sh:/usr/local/bin/run_backup.sh:ro"
        "./restic-cron/hetzner/run_check.sh:/usr/local/bin/run_check.sh:ro"
        "./restic-cron/hetzner/run_cleanup.sh:/usr/local/bin/run_cleanup.sh:ro"
        "./restic-cron/hetzner/start_cron.sh:/usr/local/bin/start_cron.sh:ro"
        "/var/lib/csb1-docker/pharos-backup-status:/pharos-backup-status"
      ];
      environment = {
        RESTIC_BACKUP_OPTIONS = "-r sftp:u387549-sub1@u387549.your-storagebox.de:/";
        # OPS-175: Resend accepts From only on the verified barta.cm domain.
        MAIL_FROM = "fleet@barta.cm";
        MAIL_SUBJECT = "💾 Restic Backup netcup csb1 (hetzner)";
        CRON_BACKUP_EXPRESSION = "30 1 * * *";
        PHAROS_BACKUP_STATUS_FILE = "/pharos-backup-status/restic-cron-hetzner.json";
      };
      env_file = [
        "/run/agenix/csb1-restic-cron-hetzner-env"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false"
        "traefik.enable=false"
      ];
      networks = [
        "smtp"
      ];
    };
    # ============================================
    # Excalidraw - Self-hosted whiteboard
    # ============================================
    excalidraw = {
      image = "excalidraw/excalidraw:latest";
      restart = "unless-stopped";
      networks = [
        "traefik"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false" # OPS-125: composeStack owns this service's image
        "traefik.enable=true"
        "traefik.http.routers.excalidraw.rule=Host(`draw.barta.cm`)"
        "traefik.http.routers.excalidraw.tls.certresolver=default"
        "traefik.http.routers.excalidraw.tls=true"
        "traefik.http.services.excalidraw.loadbalancer.server.port=80"
        "traefik.docker.network=csb1_traefik"
        "traefik.http.routers.excalidraw.middlewares=cloudflarewarp@file"
      ];
    };
    # ============================================
    # jobs-at - KI-Exposition des österreichischen Arbeitsmarkts
    # ============================================
    jobs-at = {
      image = "ghcr.io/markus-barta/jobs-at:latest";
      restart = "unless-stopped";
      networks = [
        "traefik"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false" # OPS-125: composeStack owns this service's image
        "traefik.enable=true"
        "traefik.http.routers.jobs-at.rule=Host(`zukunftschance.ai.barta.cm`)"
        "traefik.http.routers.jobs-at.tls.certresolver=default"
        "traefik.http.routers.jobs-at.tls=true"
        "traefik.http.services.jobs-at.loadbalancer.server.port=80"
        "traefik.docker.network=csb1_traefik"
        "traefik.http.routers.jobs-at.middlewares=cloudflarewarp@file"
      ];
    };
    # ============================================
    # PPM - Personal Project Management
    # ============================================
    ppm = {
      # 5.15.0 = project-scoped agent-message security controls plus the durable A2A-shaped ledger, canonical tell/read APIs and CLI, and issue-visible non-comment messages (PAI-817, PAI-815). 5.14.0 = production Paimos release with verified release artifacts and exact-state deployment evidence (PAI-818). 5.13.1 = protected unsupported-platform fail-closed runner proof plus exact-build browser proof of deployed-unverified to verified Agent Mode transitions (PAI-809, PAI-811). 5.13.0 = authority-safe Agent Mode, standalone external-stage schema, and durable provider-neutral runner control with lease-expiry/race proofs (PAI-809–811). 5.12.0 = production-safe delivery reachability, exact tested-state evidence, and authenticated Pharos owner activation (PAI-810). 5.10.1 = synthetic human demo avatar plus natural two-letter fallbacks (PAI-697). 5.10.0 = optional OIDC account chooser with runtime-safe prompt forwarding (PAI-740). 5.9.2 = CLI issue create/update safely assigns existing tags without replacement (PAI-791).
      image = "ghcr.io/inspr-at/paimos:5.20.0"; # explicit live pin; bump deliberately with the PAIMOS release/deploy flow. 5.20.0 = Pharos request links (PAI-812), SQLite writer-starvation removal (PAI-835), release-note correction (PAI-838), and stable fail-closed Codex steer discovery/fallback (PAI-840). 5.19.0 = repaired Codex steer transport (PAI-825, PAI-831) plus Amy webhook sender-key delivery (PAI-828). 5.18.0 = instant bidirectional agent bus with durable simple/steer delivery intent, encrypted receiver targets, Grok Bot HTTPS wake, and exact Codex queue/steer delivery (PAI-826). 5.17.2 = exact-build Agent Mode multi-project/multi-delivery navigation acceptance coverage plus relay publication sync (PAI-806, PAI-820). 5.17.1 = explicit action-request typing, a trusted body boundary, human-only held-action visibility, and canonical-ledger security regression proof (PAI-817). 5.17.0 = flag-gated Grok Build delivery with a fixed no-shell, tools-off boundary; Grok Bot remains human-delivered (PAI-816). 5.16.0 = durable agent inbox cursors plus native Claude and Codex delivery adapters (PAI-816); 5.9.1 = releases use a DCO-signed protected PR and tag its exact validated squash merge (PAI-790). 5.9.0 = explicit CLI issue IDs prevent ambiguous writes; Go security/toolchain advisories are patched (PAI-792, PAI-794). 5.8.18 = reproducible product captures use a complete, placeholder-free seeded PAI-1 walkthrough (PAI-696); 5.8.15 = frontend dev toolchain resolves patched Vite, Vitest, and brace-expansion with zero audit findings (PAI-758); 5.8.14 = knowledge list rejects ignored positional type arguments before any API call (PAI-760); 5.8.13 = admins choose one shared login/sidebar texture, triangle by default (PAI-738); 5.8.12 = unbranded instances use neutral gray defaults while instance overrides remain intact (PAI-737); 5.8.11 = Voice Intake exposes every accessible active project in a candidate-first searchable picker (PAI-757); 5.8.10 = Voice Intake ranks every accessible project by charter and rarity-weighted, size-normalized evidence (PAI-756); 5.8.9 = Voice Intake impact resolution caps candidates at 20, uses one project-scoped bulk lookup, and stores deterministic arrays (PAI-727); 5.8.8 = Voice Intake history slider debounces revision fetches, rejects stale responses, and bounds nested transcript restores (PAI-726); 5.8.7 = Voice Intake prevents TTS self-transcription, cancels late mic starts, revokes audio blobs, and permits blob media in CSP (PAI-731); 5.8.6 = Voice Intake reconnect healing preserves replayed events and rejects stale hydration responses (PAI-729); 5.8.5 = Voice Intake credentials and audio stay on canonical ElevenLabs HTTPS endpoints (PAI-730); 5.8.4 = Voice Intake relations are bound to the analyzed project and transactionally reject stale, moved, deleted, or cross-project targets (PAI-728); 5.8.3 = one-command, provenance-safe marketing captures with hotspot verification (PAI-695); 5.8.2 = public claims, trust links, release hygiene, and doc sync follow the canonical shipped site (PAI-689); 5.8.1 = live knowledge freshness derives the API schema and is Bash 3.2-safe (PAI-687); 5.8.0 = agent runs carry inspectable repository/branch/base→head commit evidence (PAI-702); 5.7.1 = sidebar shows the configured brand name, PPM here (PAI-736); 5.7.0 was identifier-first login, OIDC_SSO_DOMAINS unset here so behaviour is unchanged (PAI-743); 5.6.4 was SSO sessions skip the local-2FA nag (PAI-742); 5.6.3 was super-admin bootstrap fix (PAI-739, M138 no-op here); 5.6.2 was CLI credential hygiene (PAI-685); 5.6.1 was orchestrator lost-wakeup fix (PAI-725); 5.6.0 was per-language spec cache + header consolidation (PAI-734/735); 5.5.0 was voice cost gates + metering (PAI-724); 5.4.0 was ELI speak-back + configurable session budget (PAI-714); 5.3.3 was intake polish (PAI-721); 5.3.2 was voice lifecycle fixes (PAI-719); 5.3.1 was the mic Permissions-Policy fix (PAI-717); 5.3.0 was voice UX polish (PAI-715); 5.2.0 was ElevenLabs speech input (PAI-710); 5.1.0 was the Voice Intake epic (PAI-703). History: 4.8.0 sat here while live ran 5.0.0 (deploy flow sed-edits the yml, git restore reverted it) — a reconcile would have DOWNGRADED ppm over a 5.0.0-migrated DB. Caught in the OPS-116 QA, 2026-08-01.
      container_name = "ppm";
      restart = "unless-stopped";
      environment = [
        "PORT=8888"
        "PAIMOS_AGENT_BUS_INSTANCE=ppm"
        "PAIMOS_AGENT_BUS_WEBHOOK_HOSTS=api2.cursor.sh"
        "PAIMOS_AGENT_BUS_ALLOW_PRIVATE_WEBHOOKS=false"
        "COOKIE_SECURE=true"
        "BRAND_PRODUCT_NAME=PPM"
        "BRAND_WEBSITE_URL=https://pm.barta.cm"
        "BRAND_PUBLIC_URL=https://pm.barta.cm"
        "BRAND_EMAIL_FROM=noreply@barta.cm"
        "BRAND_DB_FILENAME=ppm.db"
        "BRAND_MINIO_BUCKET=ppm-attachments"
        "BRAND_HEALTH_SERVICE_NAME=ppm"
        "BRAND_TOTP_ISSUER=PPM"
        "OIDC_PROMPT=select_account"
      ];
      env_file = [
        "/run/agenix/csb1-ppm-env"
      ];
      volumes = [
        "ppm_data:/app/data"
      ];
      networks = [
        "traefik"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false" # OPS-125: composeStack owns this service's image
        "traefik.enable=true"
        "traefik.http.routers.ppm.rule=Host(`pm.barta.cm`)"
        "traefik.http.routers.ppm.tls.certresolver=default"
        "traefik.http.routers.ppm.tls=true"
        "traefik.http.services.ppm.loadbalancer.server.port=8888"
        "traefik.docker.network=csb1_traefik"
        "traefik.http.routers.ppm.middlewares=cloudflarewarp@file"
      ];
    };
    # ============================================
    # Janus - secret metadata control plane
    # ============================================
    janus = {
      # Source lives at github.com/inspr-at/janus (go-envelope/). This canonical
      # organization release is deployed from a cosign-signed image with SPDX
      # SBOM + SLSA build provenance, pinned by digest.
      # To bump: cut a go-envelope-v* release, verify, then update the digest.
      image = "ghcr.io/inspr-at/janus/janus-envelope:go-envelope-v1.182@sha256:70da4f98f46a1cfa42da2f66fba37d0ee59d46d2af4d6b49843992be7999306e";
      container_name = "janus";
      restart = "unless-stopped";
      # The image's named janus account is uid 100/gid 101. Pin the numeric
      # identity because uid 100 is the reviewed read-only custody bridge.
      user = "100:101";
      group_add = [
        "991"
      ];
      read_only = true;
      cap_drop = [
        "ALL"
      ];
      security_opt = [
        "no-new-privileges:true"
      ];
      tmpfs = [
        "/tmp:rw,noexec,nosuid,nodev,size=16m"
      ];
      environment = [
        "JANUS_PUBLIC_URL=https://vault.barta.cm"
        "JANUS_PRODUCT_MODE=self_hosted"
        "JANUS_DATA_DIR=/data"
        "JANUS_CATALOG_FILE=/catalog/agenix-catalog.json"
        "JANUS_REQUIRE_AUTH=true"
        "JANUS_UNSAFE_BOOTSTRAP_OWNER=false"
        "JANUS_VIEWER_GROUPS=janus:viewer"
        "JANUS_OWNER_GROUPS=janus:admin"
        "JANUS_APPROVER_GROUPS=janus:approver"
        "JANUS_AUDITOR_GROUPS=janus:auditor"
        "JANUS_OPERATOR_GROUPS=janus:operator"
        "JANUS_SECURITY_ADMIN_GROUPS=janus:security_admin"
        "JANUS_BREAK_GLASS_ADMIN_GROUPS=janus:break_glass_admin"
        "JANUS_SERVICE_ADMIN_GROUPS=janus:service_admin"
        "JANUS_WORKLOAD_ADMIN_GROUPS=janus:workload_admin"
        "OIDC_ISSUER=https://auth.inspr.at"
        "OIDC_PROJECT_ID=375139131258306571"
        "JANUS_MANAGED_SETUP_PHAROS_ORIGIN=https://pharos.barta.cm"
        "JANUS_MANAGED_SETUP_PHAROS_RETURN_ORIGIN=https://pharos.barta.cm"
        "JANUS_MANAGED_SETUP_INTERNAL_TOKEN_FILE=/run/janus/managed/internal-token"
        "JANUS_MANAGED_SETUP_VERIFICATION_KEYS_FILE=/etc/janus/managed/pharos-verification-keys.json"
        "JANUS_MANAGED_SETUP_MANIFEST_PATHS=/managed-services/manifest.json"
        "JANUS_MANAGED_WEB_TRANSACTION_SOCKET=/run/janus-managed-central/transaction.sock"
        "JANUS_MANAGED_HOST_TOKEN_GENERATION_DIR=/run/pharos/beacon-token-hashes"
        "JANUS_MANAGED_HOST_ENVELOPE_OUTBOX_DIR=/var/lib/janus-managed-central/outbox"
      ];
      env_file = [
        "/run/agenix/csb1-janus-env"
      ];
      volumes = [
        "janus_data:/data"
        "./janus/catalog:/catalog:ro"
        {
          type = "bind";
          source = "/run/agenix/csb1-janus-managed-internal-token";
          target = "/run/janus/managed/internal-token";
          read_only = true;
          bind = {
            create_host_path = false;
          };
        }
        {
          type = "bind";
          source = "/etc/janus/managed/pharos-verification-keys.json";
          target = "/etc/janus/managed/pharos-verification-keys.json";
          read_only = true;
          bind = {
            create_host_path = false;
          };
        }
        {
          type = "bind";
          source = "/run/pharos/managed-service-declarations";
          target = "/managed-services";
          read_only = true;
          bind = {
            create_host_path = false;
          };
        }
        {
          type = "bind";
          source = "/run/janus-managed-central";
          target = "/run/janus-managed-central";
          read_only = true;
          bind = {
            create_host_path = false;
          };
        }
        {
          type = "bind";
          source = "/var/lib/janus-managed-central/outbox";
          target = "/var/lib/janus-managed-central/outbox";
          read_only = true;
          bind = {
            create_host_path = false;
          };
        }
        "janus_pharos_production_hash_out:/run/pharos/beacon-token-hashes:ro"
      ];
      networks = [
        "traefik"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false" # OPS-125: composeStack owns this service's image
        "traefik.enable=true"
        "traefik.http.routers.janus.rule=Host(`vault.barta.cm`)"
        "traefik.http.routers.janus.tls.certresolver=default"
        "traefik.http.routers.janus.tls=true"
        "traefik.http.services.janus.loadbalancer.server.port=8080"
        "traefik.docker.network=csb1_traefik"
        "traefik.http.routers.janus.middlewares=cloudflarewarp@file"
      ];
    };
    # ============================================
    # Janus Rust engine — staged approved-use runtime
    # ============================================
    janus-engine-staged = {
      # Disabled by default. Initialize and verify with:
      #   just janus-engine-smoke
      #
      # This is intentionally not on Traefik and does not replace the live
      # go-envelope service above. It uses the same non-prod Docker volumes and
      # manifests as the smoke harness; no production secret or host SSH key is
      # mounted into the staged Rust engine. Use the smoke harness, not manual
      # project-wide compose lifecycle commands, when testing this profile.
      image = "ghcr.io/inspr-at/janus/janus-engine:rust-engine-v0.1.33@sha256:5b14100e0601810116e210b0b9eabe6b8d1a833792d0bc29fba239641c0a3752";
      container_name = "janus-engine-staged";
      profiles = [
        "janus-engine-staged"
      ];
      restart = "unless-stopped";
      user = "65532:65532";
      read_only = true;
      cap_drop = [
        "ALL"
      ];
      security_opt = [
        "no-new-privileges:true"
      ];
      network_mode = "none";
      stdin_open = true;
      entrypoint = [
        "/usr/local/bin/janus-warden"
      ];
      tmpfs = [
        "/tmp:rw,noexec,nosuid,nodev,size=16m,uid=65532,gid=65532,mode=0700"
      ];
      environment = [
        "JANUS_PRODUCT_MODE=self_hosted"
        "JANUS_ROLE_AUTHORIZATION_MODE=enforced"
        "JANUS_ROLE_BINDINGS_ROOT=/var/lib/janus/role-authorization/bindings"
        "JANUS_ROLE_AUDIT_FILE=/var/lib/janus/role-authorization/audit.jsonl"
        "JANUS_WARDEN_AUDIT_FILE=/var/lib/janus/role-authorization/warden-audit.jsonl"
        "JANUS_PERMIT_DIR=/run/janus/permits"
        "JANUS_WARDEN_PERMIT_DIR=/run/janus/permits"
        "JANUS_RUN_PERMIT_DIR=/run/janus/permits"
        "JANUS_WARDEN_BACKEND=age"
        "JANUS_WARDEN_DESTINATION=janus-engine-nonprod-smoke"
        "JANUS_WARDEN_EXECUTOR=janus-run@csb1"
        "JANUS_RUN_EXECUTOR=janus-run@csb1"
        "JANUS_WARDEN_SCOPE=janus/csb1/staged"
        "JANUS_RUN_SCOPE=janus/csb1/staged"
        "JANUS_WARDEN_SCOPE_ORGANIZATION=inspr"
        "JANUS_WARDEN_SCOPE_PROJECT=janus"
        "JANUS_WARDEN_SCOPE_REPOSITORY=nixcfg"
        "JANUS_WARDEN_SCOPE_ENVIRONMENT=staged"
        "JANUS_SCOPE_ORGANIZATION=inspr"
        "JANUS_SCOPE_PROJECT=janus"
        "JANUS_SCOPE_REPOSITORY=nixcfg"
        "JANUS_SCOPE_ENVIRONMENT=staged"
        "JANUS_WARDEN_AGE_MANIFEST_FILE=/etc/janus/secretspec.toml"
        "JANUS_AGE_MANIFEST_FILE=/etc/janus/secretspec.toml"
        "JANUS_WARDEN_AGE_METADATA_FILE=/etc/janus/metadata.toml"
        "JANUS_AGE_METADATA_FILE=/etc/janus/metadata.toml"
        "JANUS_WARDEN_AGE_PROFILE=csb1"
        "JANUS_AGE_PROFILE=csb1"
        "JANUS_WARDEN_AGE_STORE_DIR=/var/lib/janus/secrets"
        "JANUS_AGE_STORE_DIR=/var/lib/janus/secrets"
        "JANUS_LIFECYCLE_EVIDENCE_DIR=/var/lib/janus/secrets/.lifecycle-evidence"
        "JANUS_WARDEN_AGE_IDENTITY_FILE=/run/janus/age/identity"
        "JANUS_AGE_IDENTITY_FILE=/run/janus/age/identity"
        "JANUS_WARDEN_AGE_RECIPIENTS_FILE=/run/janus/age/recipient.pub"
        "JANUS_AGE_RECIPIENTS_FILE=/run/janus/age/recipient.pub"
        "JANUS_RUN_PROFILE_MANIFEST=/etc/janus/managed-commands.toml"
        "JANUS_MANAGED_PROFILE_MANIFEST=/etc/janus/managed-commands.toml"
      ];
      volumes = [
        "./janus/nonprod-smoke/secretspec.toml:/etc/janus/secretspec.toml:ro"
        "./janus/nonprod-smoke/metadata.toml:/etc/janus/metadata.toml:ro"
        "./janus/nonprod-smoke/managed-commands.toml:/etc/janus/managed-commands.toml:ro"
        "janus_engine_smoke_secrets:/var/lib/janus/secrets"
        "janus_engine_smoke_permits:/run/janus/permits"
        "janus_engine_smoke_age:/run/janus/age:ro"
        {
          type = "bind";
          source = "/var/lib/janus-role-authorization-csb1/staged";
          target = "/var/lib/janus/role-authorization";
          bind = {
            create_host_path = false;
          };
        }
      ];
      healthcheck = {
        test = [
          "CMD"
          "/usr/local/bin/janusd-use"
          "--help"
        ];
        interval = "30s";
        timeout = "15s";
        retries = 3;
        start_period = "10s";
      };
      labels = [
        "com.centurylinklabs.watchtower.enable=false" # OPS-125: composeStack owns this service's image
        "traefik.enable=false"
      ];
    };
    # ============================================
    # Janus managed-service transaction boundary
    # ============================================
    janus-managed-transactiond = {
      image = "ghcr.io/inspr-at/janus/janus-engine:rust-engine-v0.1.33@sha256:5b14100e0601810116e210b0b9eabe6b8d1a833792d0bc29fba239641c0a3752";
      container_name = "janus-managed-transactiond";
      profiles = [
        "janus-managed-service"
      ];
      restart = "no";
      init = true;
      user = "100:993";
      read_only = true;
      cap_drop = [
        "ALL"
      ];
      security_opt = [
        "no-new-privileges:true"
      ];
      pids_limit = 64;
      mem_limit = "128m";
      cpus = "0.50";
      network_mode = "none";
      entrypoint = [
        "/usr/local/bin/janusd-web-transactiond"
      ];
      tmpfs = [
        "/tmp:rw,noexec,nosuid,nodev,size=16m,uid=100,gid=993,mode=0700"
      ];
      environment = [
        "JANUS_PRODUCT_MODE=production"
        "JANUS_RELEASE_CHANNEL_POLICY=/etc/janus/managed/release-channels-v1.json"
        "JANUS_RELEASE_ADMISSION_RECEIPT=/etc/janus/managed/release-admission.json"
        "JANUS_RELEASE_ARTIFACT_DIGEST=sha256:5b14100e0601810116e210b0b9eabe6b8d1a833792d0bc29fba239641c0a3752"
        "JANUS_RELEASE_AUDIT_FILE=/var/lib/janus-managed-central/audit/release-admission.jsonl"
        "JANUS_RELEASE_EXECUTOR=janusd-web-transactiond"
        "JANUS_RUNTIME_AUDIT_FILE=/var/lib/janus-managed-central/audit/runtime.jsonl"
        "JANUS_SCOPE_ORGANIZATION=inspr"
        "JANUS_SCOPE_PROJECT=janus"
        "JANUS_SCOPE_REPOSITORY=nixcfg"
        "JANUS_SCOPE_ENVIRONMENT=production"
        "JANUS_LIFECYCLE_ENTRY_EXECUTOR=janusd-web-transactiond"
        "JANUS_LIFECYCLE_TOMBSTONE_DIR=/var/lib/janus-managed-central/tombstones"
        "JANUS_AGE_MANIFEST_FILE=/etc/janus/managed/secretspec.toml"
        "JANUS_AGE_METADATA_FILE=/var/lib/janus-managed-central/metadata.toml"
        "JANUS_AGE_PROFILE=production"
        "JANUS_AGE_STORE_DIR=/var/lib/janus-managed-central/age-store"
        "JANUS_AGE_IDENTITY_FILE=/run/agenix/csb1-janus-managed-age-identity"
        "JANUS_AGE_RECIPIENT=age12njev59mvt5vyxghh43w9gvxkurdhatkj2y30k25uttg7swphuqsj6vyku"
        "JANUS_RUN_PROFILE_MANIFEST=/etc/janus/managed/managed-env-files.toml"
        "JANUS_MANAGED_PROFILE_MANIFEST=/etc/janus/managed/managed-env-files.toml"
        "JANUS_MANAGED_WEB_TRANSACTION_SOCKET=/run/janus-managed-central/transaction.sock"
        "JANUS_MANAGED_WEB_TRANSACTION_CATALOG_FILE=/etc/janus/managed/web-transaction-catalog.json"
        "JANUS_MANAGED_WEB_TRANSACTION_ALLOWED_UID=100"
      ];
      volumes = [
        {
          type = "bind";
          source = "/var/lib/janus-managed-central";
          target = "/var/lib/janus-managed-central";
          bind = {
            create_host_path = false;
          };
        }
        {
          type = "bind";
          source = "/run/janus-managed-central";
          target = "/run/janus-managed-central";
          bind = {
            create_host_path = false;
          };
        }
        {
          type = "bind";
          source = "/run/agenix/csb1-janus-managed-host-signing-key";
          target = "/run/agenix/csb1-janus-managed-host-signing-key";
          read_only = true;
          bind = {
            create_host_path = false;
          };
        }
        {
          type = "bind";
          source = "/run/agenix/csb1-janus-managed-age-identity";
          target = "/run/agenix/csb1-janus-managed-age-identity";
          read_only = true;
          bind = {
            create_host_path = false;
          };
        }
        {
          type = "bind";
          source = "/etc/janus/managed/secretspec.toml";
          target = "/etc/janus/managed/secretspec.toml";
          read_only = true;
          bind = {
            create_host_path = false;
          };
        }
        {
          type = "bind";
          source = "/etc/janus/managed/managed-env-files.toml";
          target = "/etc/janus/managed/managed-env-files.toml";
          read_only = true;
          bind = {
            create_host_path = false;
          };
        }
        {
          type = "bind";
          source = "/etc/janus/managed/hooks.toml";
          target = "/etc/janus/managed/hooks.toml";
          read_only = true;
          bind = {
            create_host_path = false;
          };
        }
        {
          type = "bind";
          source = "/etc/janus/managed/web-transaction-catalog.json";
          target = "/etc/janus/managed/web-transaction-catalog.json";
          read_only = true;
          bind = {
            create_host_path = false;
          };
        }
        {
          type = "bind";
          source = "/etc/janus/managed/release-channels-v1.json";
          target = "/etc/janus/managed/release-channels-v1.json";
          read_only = true;
          bind = {
            create_host_path = false;
          };
        }
        {
          type = "bind";
          source = "/etc/janus/managed/release-admission.json";
          target = "/etc/janus/managed/release-admission.json";
          read_only = true;
          bind = {
            create_host_path = false;
          };
        }
      ];
      healthcheck = {
        # The release image is FROM scratch and has no shell. Container process
        # liveness plus this exec-form binary probe is complemented by the
        # host-side readiness check for the exact private socket.
        test = [
          "CMD"
          "/usr/local/bin/janusd-use"
          "--help"
        ];
        interval = "5s";
        timeout = "3s";
        retries = 3;
        start_period = "5s";
      };
      labels = [
        "com.centurylinklabs.watchtower.enable=false"
        "traefik.enable=false"
      ];
    };
    # ============================================
    # Janus managed-secret production canary
    # ============================================
    janus-managed-canary = {
      image = "alpine:3.22.5@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce";
      container_name = "janus-managed-canary";
      profiles = [
        "janus-managed-service"
      ];
      restart = "no";
      init = true;
      user = "65534:65534";
      read_only = true;
      cap_drop = [
        "ALL"
      ];
      security_opt = [
        "no-new-privileges:true"
      ];
      pids_limit = 32;
      mem_limit = "32m";
      cpus = "0.10";
      network_mode = "none";
      tmpfs = [
        "/run/canary:rw,noexec,nosuid,nodev,size=1m,uid=65534,gid=65534,mode=0700"
      ];
      volumes = [
        {
          type = "bind";
          source = "/run/janus-managed/svc_0bca8d31f7e2/slot_49c0e8a17d63.env";
          target = "/run/secrets/canary-api-token";
          read_only = true;
          bind = {
            create_host_path = false;
          };
        }
      ];
      command = [
        "/bin/sh"
        "-ec"
        "umask 077\ntest -s /run/secrets/canary-api-token\nsha256sum /run/secrets/canary-api-token | cut -d' ' -f1 > /run/canary/loaded.sha256\nexec sleep 2147483647\n"
      ];
      healthcheck = {
        test = [
          "CMD-SHELL"
          "test -s /run/secrets/canary-api-token && test -s /run/canary/loaded.sha256 && test \"$$(sha256sum /run/secrets/canary-api-token | cut -d' ' -f1)\" = \"$$(cat /run/canary/loaded.sha256)\""
        ];
        interval = "5s";
        timeout = "3s";
        retries = 3;
        start_period = "5s";
      };
      labels = [
        "com.centurylinklabs.watchtower.enable=false"
        "traefik.enable=false"
      ];
    };
    # ============================================
    # MinIO - Object storage (PPM attachments)
    # ============================================
    minio = {
      image = "minio/minio:RELEASE.2025-01-20T14-49-07Z";
      container_name = "minio";
      restart = "unless-stopped";
      command = "server /data --console-address \":9001\"";
      env_file = [
        "/run/agenix/csb1-minio-env"
      ];
      volumes = [
        "minio_data:/data"
      ];
      networks = [
        "traefik"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false" # OPS-125: composeStack owns this service's image
        "traefik.enable=true"
        "traefik.http.routers.minio-console.rule=Host(`minio.barta.cm`)"
        "traefik.http.routers.minio-console.tls.certresolver=default"
        "traefik.http.routers.minio-console.tls=true"
        "traefik.http.services.minio-console.loadbalancer.server.port=9001"
        "traefik.docker.network=csb1_traefik"
        "traefik.http.routers.minio-console.middlewares=cloudflarewarp@file"
      ];
    };
    # Pharos dashboard (PHAROS-12/39) — INSPR-native FleetCom successor.
    # Public human routes are protected by Zitadel OIDC plus the Pharos operator
    # allowlist below; beacons use tailnet /report and PHAROS-8 machine auth.
    # FleetCom is decommissioned; Pharos is the live fleet dashboard.
    pharosd = {
      # 0.1.84 = owner-intent/origin replay binding, HTTPS-only transport, exact media semantics, and disabled compression decoding (PHAROS-206).
      # Keep the readable release tag, but bind it to the verified immutable
      # linux/amd64 manifest used by both server and bundled beacon.
      image = "ghcr.io/inspr-at/pharos/pharosd:0.1.91@sha256:65f8494f313f18d63880e74d5f2eded4b98b8f383797643edf02a7ff47f69af2";
      container_name = "pharosd";
      restart = "unless-stopped";
      init = true;
      user = "10001:992";
      group_add = [
        "991"
      ];
      read_only = true;
      cap_drop = [
        "ALL"
      ];
      security_opt = [
        "no-new-privileges:true"
      ];
      pids_limit = 128;
      mem_limit = "512m";
      cpus = "1.0";
      tmpfs = [
        "/tmp:rw,noexec,nosuid,nodev,size=64m,mode=1777"
      ];
      healthcheck = {
        test = [
          "CMD"
          "/usr/local/bin/pharosd"
          "healthcheck"
        ];
        interval = "30s";
        timeout = "3s";
        start_period = "15s";
        retries = 3;
      };
      environment = [
        "PHAROS_ADDR=0.0.0.0:8080"
        "RUST_LOG=info"
        "PHAROS_DB=/data/pharos.json"
        "PHAROS_MANIFEST_PATHS=/manifests/hsb8.json"
        "PHAROS_MANAGED_SERVICE_MANIFEST_PATHS=/managed-services/manifest.json"
        "PHAROS_MANAGED_SETUP_SIGNING_KEY_FILE=/run/pharos/managed-setup-signing-key"
        "PHAROS_MANAGED_SETUP_JANUS_ORIGIN=https://vault.barta.cm"
        "PHAROS_MANAGED_SETUP_INTERNAL_TOKEN_FILE=/run/pharos/managed-setup-internal-token"
        "PHAROS_HOST_PREFERENCES_PATH=/config/pharos-host-preferences.json"
        "PHAROS_NIXCFG_DISPATCH_ENABLED=1"
        "PHAROS_NIXCFG_DISPATCH_TOKEN_FILE=/run/pharos/nixcfg-dispatch-token"
        "PHAROS_HOST_REMOVAL_DISPATCH_ENABLED=1"
        "PHAROS_JANUS_PUBLIC_URL=https://vault.barta.cm"
        "PHAROS_HCLOUD_API_TOKEN_ENV_FILE=/run/pharos/providers/hetzner-cloud.env"
        # Execution is available only through the attended plan/review/confirm
        # flow. No provider mutation occurs from connection tests or plan review.
        "PHAROS_HCLOUD_PROJECT_LABEL=Pharos production"
        "PHAROS_HCLOUD_EXECUTE=1"
        # The dedicated root-only csb1 identity and its exact selected public key
        # were verified before activating the managed provisioning assistant.
        "PHAROS_PROVISIONING_EXECUTOR_READY=1"
        "PHAROS_PROVISIONING_OWNER_HOST=csb1"
        "PHAROS_PROVISIONING_SCOPE_ORGANIZATION=inspr"
        "PHAROS_PROVISIONING_SCOPE_PROJECT=pharos"
        "PHAROS_PROVISIONING_SCOPE_REPOSITORY=nixcfg"
        "PHAROS_PROVISIONING_SCOPE_ENVIRONMENT=production"
        # csb1 is the trusted executor for other hosts; it cannot retire itself.
        "PHAROS_RETIREMENT_OWNER_HOST=csb1"
        "PHAROS_REQUIRE_BEACON_TOKEN=1"
        "PHAROS_BEACON_TOKEN_MODE=janus"
        "PHAROS_BEACON_TOKEN_HASH_DIR=/run/pharos/beacon-token-hashes"
        "PHAROS_ALERT_WEBHOOK_ENV_FILE=/run/pharos/alert-webhook.env"
        # OIDC (PKCE) — public dashboard auth via Zitadel (PHAROS-4). Beacons hit
        # /report (auth-exempt) over the tailnet; humans use https://pharos.barta.cm.
        "PHAROS_OIDC_ISSUER=https://auth.inspr.at"
        "PHAROS_OIDC_CLIENT_ID=379451733002223624@pharos"
        "PHAROS_OIDC_REDIRECT_URI=https://pharos.barta.cm/auth/callback"
        # Authorization identifiers are explicit and value-free. This migration
        # reference is derived only from an OIDC email_verified=true claim.
        "PHAROS_ALLOWED_OPERATORS=verified-email-ref:e65b48cbfa4cd57b4ab89eb88eb758b77f8e66bcdd11bc3b86655f358fe12f27"
        "PHAROS_ACCESS_POLICY_FILE=/etc/pharos/access-policy.json"
      ]
      # NIX-381 / PHAROS-206 — reporter-only Paimos delivery-stage adapter. It
      # can observe and report; it cannot create, confirm, claim or execute a
      # host action. The consequential UpdateRestart stays an attended operator
      # decision: the adapter refuses to report success unless that job already
      # carries an operator confirmation.
      ++ paimosDeliveryEnvironment;
      ports = [
        "127.0.0.1:8088:8080"
        "100.64.0.4:8088:8080"
      ];
      volumes = [
        "pharos_data:/data"
        "./pharos/access-policy.json:/etc/pharos/access-policy.json:ro"
        "./pharos/manifests:/manifests:ro"
        "/run/pharos/managed-service-declarations:/managed-services:ro"
        "/home/mba/Code/nixcfg/modules/pharos-host-preferences.json:/config/pharos-host-preferences.json:ro"
        "/run/agenix/csb1-pharos-nixcfg-dispatch-token:/run/pharos/nixcfg-dispatch-token:ro"
        {
          type = "bind";
          source = "/run/agenix/csb1-janus-managed-pharos-signing-key";
          target = "/run/pharos/managed-setup-signing-key";
          read_only = true;
          bind = {
            create_host_path = false;
          };
        }
        {
          type = "bind";
          source = "/run/agenix/csb1-janus-managed-internal-token-pharos";
          target = "/run/pharos/managed-setup-internal-token";
          read_only = true;
          bind = {
            create_host_path = false;
          };
        }
        "janus_pharos_production_hash_out:/run/pharos/beacon-token-hashes:ro"
        "janus_pharos_production_provider_out:/run/pharos/providers:ro"
        "/run/agenix/csb1-watchtower-env:/run/pharos/alert-webhook.env:ro"
      ]
      # NIX-381 — the adapter config plus one inode per credential. The derived
      # exact-replay journal needs no mount: pharosd writes it beside PHAROS_DB
      # as /data/pharos.json.paimos-delivery-journal.json, already durable in
      # the csb1_pharos_data volume above.
      ++ paimosDeliveryVolumes;
      networks = [
        "traefik"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false" # OPS-125: composeStack owns this service's image
        "com.centurylinklabs.watchtower.enable=true"
        "traefik.enable=true"
        "traefik.http.routers.pharos.rule=Host(`pharos.barta.cm`)"
        "traefik.http.routers.pharos.tls.certresolver=default"
        "traefik.http.routers.pharos.tls=true"
        "traefik.http.services.pharos.loadbalancer.server.port=8080"
        "traefik.docker.network=csb1_traefik"
        "traefik.http.routers.pharos.middlewares=cloudflarewarp@file"
      ];
    };
    # Pharos beacon (PHAROS-6) — reports csb1's status + nix freshness to pharosd
    # every 60s. Host network → reaches pharosd at the tailnet IP. Runs as mba
    # (uid 1000) to read the nixcfg checkout natively; git computes commits-behind.
    # (Interim container deploy; native musl Nix-module onboarding is PHAROS-6/7.)
    pharos-beacon = {
      image = "ghcr.io/inspr-at/pharos/pharosd:0.1.91@sha256:65f8494f313f18d63880e74d5f2eded4b98b8f383797643edf02a7ff47f69af2";
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
        "/run/agenix/pharos-beacon-csb1-env"
      ];
      environment = [
        # Used only by the inherited image healthcheck; pharos-beacon uses
        # PHAROS_URL below for reports.
        "PHAROS_ADDR=0.0.0.0:8088"
        "PHAROS_URL=http://100.64.0.4:8088"
        "PHAROS_INTERVAL=60"
        "PHAROS_HOSTNAME=csb1"
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
        "/run/current-system/kernel-modules/lib/modules:/host/run/current-system/kernel-modules/lib/modules:ro"
        "/var/lib/csb1-docker/pharos-backup-status:/pharos-backup-status:ro"
      ];
      labels = [
        "com.centurylinklabs.watchtower.enable=false"
        "traefik.enable=false"
      ];
    };
    # ============================================
    # OPS-136 — adopted from legacy project `inspr-at`
    # (/home/mba/docker/inspr-at/docker-compose.yml) on the SAME volumes and
    # network. All images pinned at the digests observed live 2026-08-04 —
    # adoption day moves ZERO software versions. The zitadel upgrade (image is
    # from 2024-07-31, ~2 years behind) is its own deliberate ticket.
    # Volumes keep their inspr-at_/paimos_ prefixes via external+name below —
    # renaming them would strand the IdP database.
    # ============================================
    inspr-www = {
      # inspr.at edge: serves www + paimos/pharos/janus/v1 subdomains. Its
      # routers carry ALL inspr.at web properties — downtime here takes the
      # whole family including the Pharos UI.
      image = "caddy:2-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648"; # OPS-136: pinned at adoption; floating policy is a later reviewed change
      container_name = "inspr-www";
      restart = "unless-stopped";
      networks = [
        "traefik"
      ];
      volumes = [
        # deploy.sh (INSPR-side) writes immutable builds under releases/ and
        # atomically flips releases/current; site/ is the frozen v1 archive.
        # Paths stay byte-identical to the legacy project on purpose.
        "/home/mba/docker/inspr-at/releases:/srv/releases:ro"
        "/home/mba/docker/inspr-at/site:/srv/v1:ro"
        "/home/mba/docker/inspr-at/Caddyfile:/etc/caddy/Caddyfile:ro"
        "inspr_at_caddy_data:/data"
        "inspr_at_caddy_config:/config"
      ];
      labels = [
        "traefik.enable=true"
        "traefik.docker.network=csb1_traefik"
        # One router per public hostname keeps certificate issuance isolated.
        "traefik.http.routers.inspr-www.rule=Host(`www.inspr.at`)"
        "traefik.http.routers.inspr-www.tls=true"
        "traefik.http.routers.inspr-www.tls.certresolver=default"
        "traefik.http.routers.inspr-www.middlewares=cloudflarewarp@file"
        "traefik.http.routers.inspr-www.service=inspr-sites"
        "traefik.http.routers.inspr-paimos.rule=Host(`paimos.inspr.at`)"
        "traefik.http.routers.inspr-paimos.tls=true"
        "traefik.http.routers.inspr-paimos.tls.certresolver=default"
        "traefik.http.routers.inspr-paimos.middlewares=cloudflarewarp@file"
        "traefik.http.routers.inspr-paimos.service=inspr-sites"
        "traefik.http.routers.inspr-pharos.rule=Host(`pharos.inspr.at`)"
        "traefik.http.routers.inspr-pharos.tls=true"
        "traefik.http.routers.inspr-pharos.tls.certresolver=default"
        "traefik.http.routers.inspr-pharos.middlewares=cloudflarewarp@file"
        "traefik.http.routers.inspr-pharos.service=inspr-sites"
        "traefik.http.routers.inspr-janus.rule=Host(`janus.inspr.at`)"
        "traefik.http.routers.inspr-janus.tls=true"
        "traefik.http.routers.inspr-janus.tls.certresolver=default"
        "traefik.http.routers.inspr-janus.middlewares=cloudflarewarp@file"
        "traefik.http.routers.inspr-janus.service=inspr-sites"
        "traefik.http.routers.inspr-v1.rule=Host(`v1.inspr.at`)"
        "traefik.http.routers.inspr-v1.tls=true"
        "traefik.http.routers.inspr-v1.tls.certresolver=default"
        "traefik.http.routers.inspr-v1.middlewares=cloudflarewarp@file"
        "traefik.http.routers.inspr-v1.service=inspr-sites"
        # Catch first-time plain-HTTP visits before HSTS can apply.
        "traefik.http.routers.inspr-sites-http.rule=Host(`inspr.at`) || Host(`www.inspr.at`) || Host(`paimos.inspr.at`) || Host(`pharos.inspr.at`) || Host(`janus.inspr.at`) || Host(`v1.inspr.at`)"
        "traefik.http.routers.inspr-sites-http.entrypoints=web"
        "traefik.http.routers.inspr-sites-http.middlewares=inspr-sites-https@docker"
        "traefik.http.routers.inspr-sites-http.service=inspr-sites"
        "traefik.http.middlewares.inspr-sites-https.redirectscheme.scheme=https"
        "traefik.http.middlewares.inspr-sites-https.redirectscheme.permanent=true"
        "traefik.http.middlewares.inspr-edge-hsts.headers.stsSeconds=31536000"
        "traefik.http.middlewares.inspr-edge-hsts.headers.stsIncludeSubdomains=true"
        "traefik.http.middlewares.inspr-edge-hsts.headers.stsPreload=true"
        # Apex stays routable for identity paths; www is canonical otherwise.
        "traefik.http.routers.inspr-apex.rule=Host(`inspr.at`)"
        "traefik.http.routers.inspr-apex.tls=true"
        "traefik.http.routers.inspr-apex.tls.certresolver=default"
        "traefik.http.routers.inspr-apex.middlewares=inspr-edge-hsts@docker,inspr-canonical-redirect@docker,cloudflarewarp@file"
        "traefik.http.routers.inspr-apex.service=inspr-sites"
        "traefik.http.middlewares.inspr-canonical-redirect.redirectregex.regex=^https?://inspr\\.at/(.*)"
        "traefik.http.middlewares.inspr-canonical-redirect.redirectregex.replacement=https://www.inspr.at/$\${1}"
        "traefik.http.middlewares.inspr-canonical-redirect.redirectregex.permanent=true"
        "traefik.http.services.inspr-sites.loadbalancer.server.port=80"
        "com.centurylinklabs.watchtower.enable=false" # OPS-136: composeStack owns this service now (was =true under watchtower)
      ];
    };
    inspr-auth = {
      # Go OIDC session backend for inspr.at/{enter,login,welcome,logout}.
      # Source: inspr-at/inspr-site `auth/`, built and published by its
      # auth-image workflow (INSPR-253): BuildKit provenance + SPDX SBOM,
      # cosign-signed with the workflow OIDC identity, Trivy-gated since 0.2.0.
      # 0.2.0 = Go 1.26 + current go-oidc/oauth2/go-jose (INSPR-307). Replaces
      # the 2026-05-11 rescue build. Rollback target (same manifest digest,
      # re-homed into this private package, cosign custody-signed):
      #   ghcr.io/inspr-at/inspr-site/inspr-auth:legacy-20260511@sha256:090c82cff2dd3c5efddfb73c445f22c34898d8e9653abd9cbb746ca26125d59f
      # The units pull this private package through composeStack.registryLogins
      # (NIX-384); the old public ghcr.io/inspr-at/inspr-auth package is being
      # deleted (INSPR-253).
      image = "ghcr.io/inspr-at/inspr-site/inspr-auth:0.2.0@sha256:d1fc446ff49f03617d574b775fc9435f035f24ad7b280b9024f1b6b53560838f";
      container_name = "inspr-auth";
      restart = "unless-stopped";
      networks = [
        "traefik"
      ];
      environment = {
        OIDC_ISSUER = "https://auth.inspr.at";
        BASE_URL = "https://inspr.at";
        LISTEN = ":8080";
      };
      env_file = [
        # OIDC_CLIENT_ID, OIDC_CLIENT_SECRET, COOKIE_KEY, INSPR_AUTH_SA_PAT,
        # ZITADEL_API_PAT — see secrets/csb1-inspr-auth-env.age
        "/run/agenix/csb1-inspr-auth-env"
      ];
      labels = [
        "traefik.enable=true"
        "traefik.docker.network=csb1_traefik"
        # Priority 100 > inspr-www's default so these paths win on the apex.
        "traefik.http.routers.inspr-auth.rule=Host(`inspr.at`) && (PathPrefix(`/enter`) || PathPrefix(`/login`) || PathPrefix(`/welcome`) || PathPrefix(`/logout`))"
        "traefik.http.routers.inspr-auth.priority=100"
        "traefik.http.routers.inspr-auth.tls=true"
        "traefik.http.routers.inspr-auth.tls.certresolver=default"
        "traefik.http.routers.inspr-auth.middlewares=cloudflarewarp@file,inspr-edge-hsts@docker"
        "traefik.http.services.inspr-auth.loadbalancer.server.port=8080"
        "com.centurylinklabs.watchtower.enable=false"
      ];
    };
    zitadel-postgres = {
      # 🔴 THE identity database. external+name volume below — a project-
      # prefixed volume here would start the IdP on an empty database.
      image = "postgres:16-alpine@sha256:4e6e670bb069649261c9c18031f0aded7bb249a5b6664ddec29c013a89310d50"; # OPS-136: pinned — never float a database engine
      container_name = "zitadel-postgres";
      restart = "unless-stopped";
      stop_grace_period = "120s";
      networks = [
        "traefik"
      ];
      environment = {
        POSTGRES_USER = "zitadel";
        POSTGRES_DB = "zitadel";
      };
      env_file = [
        # POSTGRES_PASSWORD — init-only on an existing volume (recovery
        # material); see secrets/csb1-zitadel-postgres-env.age
        "/run/agenix/csb1-zitadel-postgres-env"
      ];
      volumes = [
        "zitadel_postgres_data:/var/lib/postgresql/data"
      ];
      healthcheck = {
        test = [
          "CMD"
          "pg_isready"
          "-U"
          "zitadel"
        ];
        interval = "10s";
        timeout = "5s";
        retries = 6;
      };
      labels = [
        "com.centurylinklabs.watchtower.enable=false"
        "traefik.enable=false"
      ];
    };
    zitadel = {
      # IdP at auth.inspr.at. Digest = the image observed live 2026-08-04
      # (created 2024-07-31; `:stable` had never been re-pulled). Upgrading
      # is a separate ticket with its own DB-migration plan.
      image = "ghcr.io/zitadel/zitadel:stable@sha256:5fb493fdb73204667cdd05715ef5f140049bf2781e10fd8ca407ce5aaa29f3df";
      container_name = "zitadel";
      restart = "unless-stopped";
      depends_on = {
        zitadel-postgres = {
          condition = "service_healthy";
        };
      };
      networks = [
        "traefik"
      ];
      # OPS-136: was `--masterkey <value>` via .env interpolation — the key
      # rode the container command line (visible in inspect/proc). Now read
      # from ZITADEL_MASTERKEY env (agenix). Flag verified on this exact
      # image (P0, 2026-08-04).
      command = [
        "start-from-init"
        "--masterkeyFromEnv"
        "--tlsMode"
        "external"
      ];
      environment = {
        ZITADEL_DATABASE_POSTGRES_HOST = "zitadel-postgres";
        ZITADEL_DATABASE_POSTGRES_PORT = "5432";
        ZITADEL_DATABASE_POSTGRES_DATABASE = "zitadel";
        ZITADEL_DATABASE_POSTGRES_USER_USERNAME = "zitadel";
        ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE = "disable";
        ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME = "zitadel";
        ZITADEL_DATABASE_POSTGRES_ADMIN_SSL_MODE = "disable";
        # NOTE: changing ExternalDomain after first init requires reset.
        ZITADEL_EXTERNALDOMAIN = "auth.inspr.at";
        ZITADEL_EXTERNALPORT = "443";
        ZITADEL_EXTERNALSECURE = "true";
        # Traefik terminates TLS; zitadel listens HTTP on the docker net.
        ZITADEL_TLS_ENABLED = "false";
        ZITADEL_PORT = "8080";
        # First-instance bootstrap — inert on the existing database, kept
        # for empty-volume disaster recovery fidelity. Password via agenix.
        ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME = "zitadel-admin";
        ZITADEL_FIRSTINSTANCE_ORG_HUMAN_FIRSTNAME = "Zitadel";
        ZITADEL_FIRSTINSTANCE_ORG_HUMAN_LASTNAME = "Admin";
        ZITADEL_FIRSTINSTANCE_ORG_HUMAN_EMAIL_ADDRESS = "admin@auth.inspr.at";
        ZITADEL_FIRSTINSTANCE_ORG_HUMAN_EMAIL_VERIFIED = "true";
        ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORDCHANGEREQUIRED = "false";
        ZITADEL_FIRSTINSTANCE_ORG_NAME = "INSPR";
        ZITADEL_FIRSTINSTANCE_ORG_MACHINE_MACHINE_USERNAME = "bootstrap-sa";
        ZITADEL_FIRSTINSTANCE_ORG_MACHINE_MACHINE_NAME = "Bootstrap";
        ZITADEL_FIRSTINSTANCE_ORG_MACHINE_PAT_EXPIRATIONDATE = "2099-12-31T23:59:59Z";
        ZITADEL_FIRSTINSTANCE_PATPATH = "/machinekey/pat.txt";
      };
      env_file = [
        # ZITADEL_MASTERKEY, ZITADEL_DATABASE_POSTGRES_USER_PASSWORD,
        # ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD,
        # ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD — csb1-zitadel-env.age
        "/run/agenix/csb1-zitadel-env"
      ];
      volumes = [
        # Bind (not named volume): host dir is chowned to UID 1000 so
        # zitadel's non-root user can write the bootstrap PAT (legacy fix).
        "/home/mba/docker/inspr-at/.machinekey:/machinekey"
      ];
      labels = [
        "traefik.enable=true"
        "traefik.docker.network=csb1_traefik"
        "traefik.http.routers.zitadel.rule=Host(`auth.inspr.at`)"
        "traefik.http.routers.zitadel.tls=true"
        "traefik.http.routers.zitadel.tls.certresolver=default"
        "traefik.http.routers.zitadel.middlewares=cloudflarewarp@file,inspr-edge-hsts@docker"
        "traefik.http.routers.zitadel-http.rule=Host(`auth.inspr.at`)"
        "traefik.http.routers.zitadel-http.entrypoints=web"
        "traefik.http.routers.zitadel-http.middlewares=inspr-sites-https@docker"
        "traefik.http.routers.zitadel-http.service=zitadel"
        "traefik.http.services.zitadel.loadbalancer.server.port=8080"
        # zitadel speaks h2c on the backend for its gRPC services; without
        # this the console breaks while /oauth/v2/* still works.
        "traefik.http.services.zitadel.loadbalancer.server.scheme=h2c"
        "com.centurylinklabs.watchtower.enable=false"
      ];
    };
    # ============================================
    # OPS-136 — adopted from legacy project `paimos`
    # (/home/mba/docker/paimos/docker-compose.yml)
    # ============================================
    paimos-www = {
      image = "caddy:2-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648"; # OPS-136: pinned at adoption; floating policy is a later reviewed change
      container_name = "paimos-www";
      restart = "unless-stopped";
      networks = [
        "traefik"
      ];
      volumes = [
        "/home/mba/docker/paimos/site:/srv:ro"
        "/home/mba/docker/paimos/Caddyfile:/etc/caddy/Caddyfile:ro"
        "paimos_caddy_data:/data"
        "paimos_caddy_config:/config"
      ];
      labels = [
        "traefik.enable=true"
        "traefik.docker.network=csb1_traefik"
        "traefik.http.routers.paimos.rule=Host(`paimos.com`) || Host(`www.paimos.com`)"
        "traefik.http.routers.paimos.tls=true"
        "traefik.http.routers.paimos.tls.certresolver=default"
        "traefik.http.routers.paimos.middlewares=paimos-www-redirect@docker,cloudflarewarp@file"
        "traefik.http.middlewares.paimos-www-redirect.redirectregex.regex=^https?://www\\.paimos\\.com/(.*)"
        "traefik.http.middlewares.paimos-www-redirect.redirectregex.replacement=https://paimos.com/$\${1}"
        "traefik.http.middlewares.paimos-www-redirect.redirectregex.permanent=true"
        "traefik.http.services.paimos.loadbalancer.server.port=80"
        "com.centurylinklabs.watchtower.enable=false" # OPS-136: composeStack owns this service now (was =true under watchtower)
      ];
    };
  };
  volumes = {
    pharos_data = { };
    janus_pharos_production_hash_out = {
      external = true;
      name = "\${JANUS_PHAROS_HASH_OUT_VOLUME:-janus_pharos_production_hash_out}";
    };
    janus_pharos_production_provider_out = {
      external = true;
      name = "\${JANUS_PHAROS_PROVIDER_OUT_VOLUME:-janus_pharos_production_provider_out}";
    };
    docmost_db_data = { };
    docmost_redis_data = { };
    docmost_data = { };
    paperless_db_data = { };
    paperless_redis_data = { };
    paperless_data = { };
    paperless_media = { };
    paperless_consume = { };
    hausv_postgres_data = { };
    ppm_data = { };
    janus_data = { };
    janus_engine_smoke_age = {
      external = true;
      name = "\${JANUS_SMOKE_AGE_VOLUME:-janus_engine_smoke_age}";
    };
    janus_engine_smoke_secrets = {
      external = true;
      name = "\${JANUS_SMOKE_STORE_VOLUME:-janus_engine_smoke_secrets}";
    };
    janus_engine_smoke_permits = {
      external = true;
      name = "\${JANUS_SMOKE_PERMIT_VOLUME:-janus_engine_smoke_permits}";
    };
    minio_data = { };
    # OPS-136 — volumes adopted from the legacy inspr-at/paimos projects.
    # 🔴 external + name is load-bearing: without it, project csb1 would
    # create fresh empty `csb1_*` volumes and the IdP would boot on a blank
    # database. Names must stay byte-identical to the legacy prefixes.
    inspr_at_caddy_data = {
      external = true;
      name = "inspr-at_caddy_data";
    };
    inspr_at_caddy_config = {
      external = true;
      name = "inspr-at_caddy_config";
    };
    zitadel_postgres_data = {
      external = true;
      name = "inspr-at_zitadel_postgres_data";
    };
    paimos_caddy_data = {
      external = true;
      name = "paimos_caddy_data";
    };
    paimos_caddy_config = {
      external = true;
      name = "paimos_caddy_config";
    };
  };
  networks = {
    internal = null;
    traefik = null;
    smtp = null;
    hausv-proxy = {
      internal = true;
      ipam = {
        config = [
          {
            subnet = "10.253.254.0/29";
          }
        ];
      };
    };
    hausv-egress = null;
    docker-sock-traefik = {
      internal = true;
    };
  };
}

# ── comments from the retired yml that could not be auto-anchored ──
# [traefik]       # HostDash owns / on cs1.barta.cm; keep Traefik's API on /api and
# [traefik]       # /dashboard if the dashboard is enabled later.
# [pharosd]       # The beacon image inherits pharosd's loopback readiness probe. Publish
# [pharosd]       # the same listener locally so that role-specific health stays truthful.
# [pharosd]       # Tailnet bind kept for beacon ingestion (/report stays auth-exempt).
# [restic-cron-hetzner] # 1:30am (was on: CRON_BACKUP_EXPRESSION: "30 1 * * *")
