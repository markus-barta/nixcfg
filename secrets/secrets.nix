# Agenix Secrets Configuration
# https://github.com/ryantm/agenix
#
# Workflow:
#   1. Add your host's SSH key to this file
#   2. Create secret: agenix -e secrets/SECRETNAME.age
#   3. Reference in config: age.secrets.SECRETNAME.file = ./secrets/SECRETNAME.age;
#   4. After key changes: just rekey

let
  # ============================================================================
  # USER KEYS
  # ============================================================================
  # Personal SSH keys that can decrypt secrets for editing

  # Markus's user identities. Aggregate `markus` admits all currently-
  # supported personal SSH keys (legacy RSA + per-host ed25519s). Add
  # new per-host ed25519s here as they're minted under INSPR-78; remove
  # `markus_rsa_legacy` from the aggregate (and rekey) when INSPR-76
  # Phase 2 retirement completes. See modules/shared/ssh-keyring.nix
  # for the canonical metadata on each key.
  markus_rsa_legacy = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt"; # markus@iMac-5k-MBA-home.local — shared pre-2026 RSA
  markus_m5_ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP9FWi8t5l5fA4ps3+Qos2U4VbVY712kxQeIOczHaXs6 mba@mbp0"; # added INSPR-78 (2026-05-03)
  markus_mbp2607_ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFCX8hTsA5FHr+6Z/vCSq/HQI9DLpaF63XbN5YXEsch8 markus@mbp2607"; # added NIX-215 (2026-07-03) — fresh key, no carry-over

  markus = [
    markus_rsa_legacy
    markus_m5_ed25519
    markus_mbp2607_ed25519
  ];

  # gb's key (user on hsb8)
  gb = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINmt2Fio1JUABm/dq0XMI4J4juZl3DC0AQBGOXuEnUfD gb@hsb8"
  ];

  # ============================================================================
  # HOST KEYS
  # ============================================================================
  # SSH host keys from each server (get with: ssh-keyscan hostname)

  hsb0 = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO5LSuJ8JJO03QNhl/eYpoQSmJFgF6ioFDsDOKTAxql3"
  ];

  hsb8 = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDeDdND1TRTYc6rnn/xMMhNHe6I8DJ5bQxZWT3GI2wHUcd4RpkkSUhtIhjYwbwtdi3nRYlsRKPeqZ8sERNAORkThdMy9ueMq3oDwrTlMbs6jlS8atbZPiozkOji2g00+xrb2tTp0480+M2kKIYv8gSN7lHzjnA3i128YN1NNsbqanU/pZVaEe0M10G9TMWifdZqQnGxFjWrMxlSCOwhvC7OixCLbKi4YPiVQ/LkeF67su1i68qZQgJRftx9te7AJm19P4gIz2Tn+OI0a4iESnLzA4PD2Zu7eBo63B35u0ardlH1AZK7GZIa4DFAcaCp3xpRQ1N5RKEjAfYi1LhSWh2UvsVp2vFTc7NvOcSCdR6BjumcGk2k/3b71YGfAWxI+7VY74eeugVIpsAWY3ewGikn2qYQrv8Op374dLVBpmtrBZG7mXayk2uqQIdybXNFm7drsXVPDenD/Dl/mewYRmzb2vcSyLDS5sevBBgNmvMdNNyrbdjXZEo8j0IkExrYkng5p/AMgC4pUV6X/tcGTk//QnknWESmtcNeYjJy17kBiSOwZ4+WjEltqQMqMyf6elIjhN56ZhdCSTUVGe8d4t4NcCj4aS2K3rLJIR7cMFpmXTr+Bo9g/Oj3Lnoj0i8R82CjTY/0fuZSOsqpFdOAhgXGyEIHmglxC2fcyxcMZJAFaQ=="
  ];

  hsb9 = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIITMRyVS7w+i+WRK5Djy1NnxJkhu3ZYpkHHTgNqKvXU root@hsb9"
  ];

  hsb1 = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIU0cAsXtdYPO5W4ns6utAEkVvzcmOx5Xl/nVF/fvAVz"
  ];

  csb0 = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJK1DM6yCiWlEz9xXwAmCLR9j6Ylmao5AJMX8oMPDDWz"
    # "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKQk8oklcJePMtYjjBCgKaTrzZ4kqad84htRV9fzOVSd" //old key - decomissioned csb0-old 2026-01-10
  ];

  csb1 = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHWQjoKsgp+4m8M2ztlDSYtiW80loYfYMeYYJCfhIh7g"
  ];

  gpc0 = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFpykoFcMPeCtWH3aColM4fzCsslUxaHwW9DHSTi2Fr3"
  ];

  # miniserver-bp host key removed 2026-05-02 (INSPR-24): host migrated
  # to BYTEPOETS/bpnixcfg. Its host key now lives in that flake's
  # secrets/secrets.nix. The deprecated `nixfleet-token.age` below loses
  # msbp as a recipient — rekey deferred (file is on the deprecation
  # path; will be removed entirely once FleetCom Phase 2 lands).

  # ============================================================================
  # MACOS HOSTS
  # ============================================================================
  # First macOS host as agenix recipient (mbp0, added 2026-05-01).
  # macOS does NOT auto-generate /etc/ssh/ssh_host_ed25519_key — manually
  # created via:
  #     sudo ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" \
  #          -C "root@<hostname>"
  # This key is dedicated to agenix decryption; sshd is not explicitly
  # configured to use it (Apple's CryptoTokenKit handles SSH service keys
  # separately on modern macOS). See playbook field notes for context.

  "mbp0" = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH6ene6+iB5I9brFPfFwuqNil7nbJpWguycyZqv67+LU root@mbp0"
  ];

  # mbp2607 (NIX-215, 2026-07-03). Unlike mbp0's era, macOS 26 auto-generated
  # the host key when Remote Login was enabled — no manual ssh-keygen needed.
  "mbp2607" = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJVoAPf5vx/GYpIeeHRLdViG3igF041fs/GL7l1AQzo root@mbp2607"
  ];

in
{
  # ============================================================================
  # ACTIVE SECRETS
  # ============================================================================

  # AdGuard Home static DHCP leases for hsb0
  # Format: JSON array of {mac, ip, hostname}
  # Edit: agenix -e secrets/static-leases-hsb0.age
  # TODO: Rename to hsb0-adguard-leases.age
  "static-leases-hsb0.age".publicKeys = markus ++ hsb0;

  # AdGuard Home static DHCP leases for hsb8
  # Format: JSON array of {mac, ip, hostname}
  # Edit: agenix -e secrets/static-leases-hsb8.age
  # TODO: Rename to hsb8-adguard-leases.age
  "static-leases-hsb8.age".publicKeys = markus ++ gb ++ hsb8;

  # MQTT credentials for UPS status publishing on hsb0
  # Format: KEY=VALUE lines (MQTT_HOST, MQTT_USER, MQTT_PASS)
  # Edit: agenix -e secrets/mqtt-hsb0.age
  # TODO: Rename to hsb0-mqtt-client.age
  "mqtt-hsb0.age".publicKeys = markus ++ hsb0;

  # NIX-158 phase 3 P2 — hsb1 single-consumer service secrets, migrated from
  # /home/mba/secrets/*.env plaintext. Edit: agenix -e secrets/<name>.age
  "hsb1-zigbee2mqtt-env.age".publicKeys = markus ++ hsb1;
  "hsb1-funkeykid-api-env.age".publicKeys = markus ++ hsb1;
  "hsb1-watchtower-env.age".publicKeys = markus ++ hsb1;
  "hsb1-opusweb-env.age".publicKeys = markus ++ hsb1;
  "hsb1-fritz-tripwire-env.age".publicKeys = markus ++ hsb1;

  # NIX-158 phase 3 P3 — shared smarthome env (MQTT logins + many API keys),
  # consumed by homeassistant + funkeykid + nodered. Edit: agenix -e secrets/hsb1-smarthome-env.age
  "hsb1-smarthome-env.age".publicKeys = markus ++ hsb1;
  # NIX-158 phase 3 P3b — host-level /etc/secrets pair (read by BOTH the kiosk
  # mqtt-volume-control systemd unit AND containers) -> agenix owner root 0644.
  "hsb1-mqtt-client-env.age".publicKeys = markus ++ hsb1;
  "hsb1-tapo-c210-env.age".publicKeys = markus ++ hsb1;

  # Time Machine Samba credentials (tm-markus/tm-mailina shares) — two lines,
  # "markus <password>" and "mailina <password>". Edit: agenix -e secrets/hsb1-tm-smb-env.age
  "hsb1-tm-smb-env.age".publicKeys = markus ++ hsb1;

  # NIX-230/235 — hsb8 watchtower env: WATCHTOWER_HTTP_API_TOKEN (must match
  # WATCHTOWER_TOKEN in fleetcom-agent's /opt/fleetcom-agent/.env) +
  # WATCHTOWER_NOTIFICATION_URL (telegram shoutrrr). Replaces the unmanaged
  # /home/gb/secrets/watchtower.env. Edit: agenix -e secrets/hsb8-watchtower-env.age
  "hsb8-watchtower-env.age".publicKeys = markus ++ hsb8;

  # Uptime Kuma environment variables (for Apprise tokens)
  # Format: KEY=VALUE lines
  # Edit: agenix -e secrets/uptime-kuma-env.age
  # TODO: Rename to csb0-uptime-kuma-env.age
  "uptime-kuma-env.age".publicKeys = markus ++ csb0 ++ hsb0;

  # NCPS signing key for binary cache proxy on hsb0
  # Format: secret-key-file content (nix-store generated)
  # Edit: agenix -e secrets/ncps-key.age
  # TODO: Rename to hsb0-ncps-key.age
  "ncps-key.age".publicKeys = markus ++ hsb0;

  # Fritz!Box SMB share credentials for Plex on hsb1
  # Format: KEY=VALUE lines (username, password, domain)
  # Edit: agenix -e secrets/fritzbox-smb-credentials.age
  # TODO: Rename to hsb1-fritzbox-smb.age
  "fritzbox-smb-credentials.age".publicKeys = markus ++ hsb1;

  # Node-RED environment variables (Telegram bot token, etc)
  # Edit: agenix -e secrets/nodered-env.age
  # TODO: Rename to csb0-nodered-env.age
  "nodered-env.age".publicKeys = markus ++ csb0;

  # Mosquitto password file
  # Edit: agenix -e secrets/mosquitto-passwd.age
  # NOTE: This is for Mosquitto BROKER configuration (server-side)
  # TODO: Rename to csb0-mosquitto-passwd.age
  "mosquitto-passwd.age".publicKeys = markus ++ csb0;

  # Restic Hetzner SSH key
  # TODO: Rename to shared-restic-hetzner-ssh.age
  "restic-hetzner-ssh-key.age".publicKeys = markus ++ hsb0 ++ hsb1 ++ csb0 ++ csb1;

  # Restic Hetzner environment variables
  # TODO: Rename to shared-restic-hetzner-env.age
  "restic-hetzner-env.age".publicKeys = markus ++ hsb0 ++ hsb1 ++ csb0 ++ csb1;

  # hsb1 specific restic secrets (sub2)
  "hsb1-restic-ssh-key.age".publicKeys = markus ++ hsb1;
  "hsb1-restic-env.age".publicKeys = markus ++ hsb1;

  # OPUS SmartHome Stream to MQTT Bridge credentials
  # Format: KEY=VALUE lines (.env format)
  # Edit: agenix -e secrets/opus-stream-hsb1.age
  "opus-stream-hsb1.age".publicKeys = markus ++ hsb1;

  # PIXDCON MQTT credentials
  # Format: KEY=VALUE lines (MQTT_PASS)
  # Edit: agenix -e secrets/hsb1-pixdcon-env.age
  "hsb1-pixdcon-env.age".publicKeys = markus ++ hsb1;

  # hsb1 Mosquitto broker (server-side). conf carries the inline OPUS greennet
  # bridge connection (vendor-locked credential, LAN-only) + passwd holds broker
  # auth hashes — both are secrets, never plaintext in git. Encrypt from the live
  # host so no plaintext touches local disk:
  #   ssh mba@hsb1.lan "docker exec mosquitto cat /mosquitto/config/mosquitto.conf"   | agenix -e secrets/hsb1-mosquitto-conf.age
  #   ssh mba@hsb1.lan "docker exec mosquitto cat /mosquitto/config/mosquitto_passwd" | agenix -e secrets/hsb1-mosquitto-passwd.age
  "hsb1-mosquitto-conf.age".publicKeys = markus ++ hsb1;
  "hsb1-mosquitto-passwd.age".publicKeys = markus ++ hsb1;

  # IR→Sony TV bridge: SONY_TV_PSK (+ optional MQTT creds) for the FLIRC receiver
  # returned to hsb1. Contents: a single line `SONY_TV_PSK=<tv pre-shared key>`.
  # Edit: cd ~/Code/nixcfg && just edit-secret hsb1-ir-bridge-env.age
  "hsb1-ir-bridge-env.age".publicKeys = markus ++ hsb1;

  # hsb1 SMTP relay (namshi/smtp) credentials — env_file holding the hover.com
  # SMARTHOST_PASSWORD. Read by the docker daemon at container start (not a volume
  # mount). Encrypt from the live file so no plaintext touches local disk — a real
  # file works with EDITOR=cp (a /dev/stdin pipe does not):
  #   ssh mba@hsb1.lan
  #   cd ~/Code/nixcfg && EDITOR='cp /home/mba/docker/smtp/variables.env' agenix -e secrets/hsb1-smtp-env.age
  "hsb1-smtp-env.age".publicKeys = markus ++ hsb1;

  # PPM (Personal Project Management) environment variables for csb1
  # Format: KEY=VALUE lines (PPM_ADMIN_PASSWORD, COOKIE_SECURE, etc.)
  # Edit: agenix -e secrets/csb1-ppm-env.age
  "csb1-ppm-env.age".publicKeys = markus ++ csb1;

  # Janus environment variables for csb1
  # Format: KEY=VALUE lines (OIDC_CLIENT_ID, OIDC_CLIENT_SECRET, COOKIE_KEY)
  # Edit: agenix -e secrets/csb1-janus-env.age
  "csb1-janus-env.age".publicKeys = markus ++ csb1;

  # Pharos registration bootstrap env for csb1 pharosd.
  # Format: KEY=VALUE line with PHAROS_REGISTRATION_TOKEN only. This enables
  # /register token issuance; strict /report enforcement is flipped separately
  # after all deployed beacons have per-host tokens.
  "csb1-pharos-registration-env.age".publicKeys = markus ++ csb1;

  # Dedicated GitHub PAT (classic) used only by pharosd to dispatch nixcfg's
  # fixed pharos-host-settings workflow. Contents: raw token, no KEY= prefix.
  "csb1-pharos-nixcfg-dispatch-token.age".publicKeys = markus ++ csb1;

  # Pharos beacon env files. Format: KEY=VALUE with PHAROS_TOKEN only.
  # Issued via pharosd /register, then consumed by pharos-beacon Docker env_file.
  "pharos-beacon-hsb0-env.age".publicKeys = markus ++ hsb0;
  "pharos-beacon-hsb1-env.age".publicKeys = markus ++ hsb1;
  "pharos-beacon-hsb8-env.age".publicKeys = markus ++ hsb8;
  "pharos-beacon-hsb9-env.age".publicKeys = markus ++ hsb9;
  "pharos-beacon-csb0-env.age".publicKeys = markus ++ csb0;
  "pharos-beacon-csb1-env.age".publicKeys = markus ++ csb1;
  "pharos-beacon-gpc0-env.age".publicKeys = markus ++ gpc0;

  # HostDash OAuth2 Proxy env for csb0/csb1.
  # Format: KEY=VALUE lines (OAUTH2_PROXY_CLIENT_ID,
  # OAUTH2_PROXY_CLIENT_SECRET, OAUTH2_PROXY_COOKIE_SECRET)
  # Zitadel app allows both cloud dashboard callback URLs.
  "csb-hostdash-oauth2-proxy-env.age".publicKeys = markus ++ csb0 ++ csb1;

  # WEG Portal environment variables for csb1
  # Format: KEY=VALUE lines (SESSION_KEY, tenant/user JSON, HA_TOKEN)
  # Edit: agenix -e secrets/csb1-hausv-org-env.age
  "csb1-hausv-org-env.age".publicKeys = markus ++ csb1;

  # === NIX-110: csb1 docker stack migration to git — bulk env file refactor ===
  # The following secrets were previously plaintext in ~/secrets/ or
  # ./xxx.env on csb1. Moved to agenix as part of the docker-in-git
  # migration. Each is referenced by the corresponding service in
  # hosts/csb1/docker/docker-compose.yml as env_file: /run/agenix/<name>.

  # Docmost — Postgres credentials
  "csb1-docmost-postgres-env.age".publicKeys = markus ++ csb1;
  # Docmost — application config (API keys, S3 creds, etc.)
  "csb1-docmost-config-env.age".publicKeys = markus ++ csb1;
  # InfluxDB3 — bootstrap admin + tokens
  # Paperless-ngx — Postgres credentials
  "csb1-paperless-postgres-env.age".publicKeys = markus ++ csb1;
  # Paperless-ngx — application config (admin user, secret key)
  "csb1-paperless-config-env.age".publicKeys = markus ++ csb1;
  # SMTP relay (docker-smtp) — smarthost password
  "csb1-smtp-env.age".publicKeys = markus ++ csb1;
  # Restic cron (hetzner storagebox) — restic password + mail
  "csb1-restic-cron-hetzner-env.age".publicKeys = markus ++ csb1;
  # Restic SSH private key (was plaintext on disk pre-NIX-110)
  "csb1-restic-cron-id-rsa.age".publicKeys = markus ++ csb1;
  # Watchtower — HTTP API token + notifications URL
  "csb1-watchtower-env.age".publicKeys = markus ++ csb1;

  # MinIO environment variables for csb1 (PPM attachment storage)
  # Format: KEY=VALUE lines (MINIO_ROOT_USER, MINIO_ROOT_PASSWORD, etc.)
  # Edit: agenix -e secrets/csb1-minio-env.age
  "csb1-minio-env.age".publicKeys = markus ++ csb1;

  # Mosquitto broker configuration file
  # Edit: agenix -e secrets/mosquitto-conf.age
  # NOTE: This is for Mosquitto BROKER configuration (server-side)
  # TODO: Rename to csb0-mosquitto-conf.age
  "mosquitto-conf.age".publicKeys = markus ++ csb0;

  # Traefik configuration
  # TODO: Rename to csb0-traefik-static.age
  "traefik-static.age".publicKeys = markus ++ csb0;
  # TODO: Rename to csb0-traefik-dynamic.age
  "traefik-dynamic.age".publicKeys = markus ++ csb0;
  # TODO: Rename to csb0-traefik-env.age
  "traefik-variables.age".publicKeys = markus ++ csb0 ++ csb1;

  # MQTT credentials for csb0
  # Format: KEY=VALUE lines (MQTT_HOST, MQTT_USER, MQTT_PASS)
  # Edit: agenix -e secrets/mqtt-csb0.age
  # NOTE: This is for MQTT CLIENT credentials (client-side)
  # TODO: Rename to csb0-mqtt-client.age
  "mqtt-csb0.age".publicKeys = markus ++ csb0;

  # Uptime Kuma API key for Merlin (read monitors, create incidents)
  # Format: Plain text token (no KEY=VALUE)
  # Edit: agenix -e secrets/hsb0-uptime-kuma-api-key.age
  "hsb0-uptime-kuma-api-key.age".publicKeys = markus ++ hsb0;

  # Speedtest Tracker application encryption key
  # Format: Plain text Laravel key (no KEY=VALUE)
  # Edit: agenix -e secrets/hsb0-speedtest-tracker-app-key.age
  "hsb0-speedtest-tracker-app-key.age".publicKeys = markus ++ hsb0;

  # ElevenLabs API key for TTS (shared: Merlin + Nimue on hsb0)
  # Format: Plain text API key (no KEY=VALUE)
  # Edit: agenix -e secrets/hsb0-elevenlabs-api-key.age
  "hsb0-elevenlabs-api-key.age".publicKeys = markus ++ hsb0;

  # ElevenLabs API key for funkeykid TTS on hsb1
  # Format: Plain text API key (no KEY=VALUE)
  # Edit: agenix -e secrets/hsb1-funkeykid-elevenlabs-api-key.age
  "hsb1-funkeykid-elevenlabs-api-key.age".publicKeys = markus ++ hsb1;

  # Groq API key for STT — Whisper Large v3 (shared: Merlin + Nimue on hsb0)
  # Format: Plain text API key (no KEY=VALUE)
  # Edit: agenix -e secrets/hsb0-groq-api-key.age
  "hsb0-groq-api-key.age".publicKeys = markus ++ hsb0;

  # OpenClaw Merlin AI assistant secrets (hsb0)
  # Format: Plain text tokens/keys (no KEY=VALUE)
  # Edit: agenix -e secrets/hsb0-openclaw-*.age
  # Runtime: /run/agenix/hsb0-openclaw-*
  "hsb0-openclaw-gateway-token.age".publicKeys = markus ++ hsb0;
  "hsb0-openclaw-telegram-token.age".publicKeys = markus ++ hsb0;
  "hsb0-openclaw-openrouter-key.age".publicKeys = markus ++ hsb0;
  "hsb0-openclaw-hass-token.age".publicKeys = markus ++ hsb0;
  "hsb0-openclaw-brave-key.age".publicKeys = markus ++ hsb0;
  "hsb0-openclaw-icloud-password.age".publicKeys = markus ++ hsb0;
  "hsb0-openclaw-opus-gateway.age".publicKeys = markus ++ hsb0;
  "hsb0-gogcli-keyring-password.age".publicKeys = markus ++ hsb0;
  # GitHub PAT for @merlin-ai-markus (1Password: hsb0-openclaw-merlin-workspace)
  # Edit: agenix -e secrets/hsb0-openclaw-github-pat.age
  "hsb0-openclaw-github-pat.age".publicKeys = markus ++ hsb0;

  # PPM (pm.barta.cm) API key — shared by Merlin + Nimue for personal PM access.
  # Format: bare token (starts with `paimos_`).
  # Edit: agenix -e secrets/hsb0-ppm-api-key.age
  "hsb0-ppm-api-key.age".publicKeys = markus ++ hsb0;

  # Nimue agent secrets (second agent in openclaw-gateway)
  # Edit: agenix -e secrets/hsb0-nimue-*.age
  # Runtime: /run/agenix/hsb0-nimue-*
  "hsb0-nimue-telegram-token.age".publicKeys = markus ++ hsb0;
  # GitHub PAT for @nimue-ai-mai (workspace git push)
  "hsb0-nimue-github-pat.age".publicKeys = markus ++ hsb0;
  "hsb0-nimue-icloud-password.age".publicKeys = markus ++ hsb0;
  "hsb0-nimue-gogcli-keyring-password.age".publicKeys = markus ++ hsb0;
  # Google OAuth client credentials (OAuth app registration, not a token)
  # Format: JSON (downloaded from Google Cloud Console → Credentials → OAuth client)
  # Edit: agenix -e secrets/hsb0-nimue-gogcli-credentials.age
  "hsb0-nimue-gogcli-credentials.age".publicKeys = markus ++ hsb0;

  # M365 calendar (read-only) - Azure AD app: Merlin-AI-hsb0-cal
  # TODO: Uncomment when Azure AD app is created and .age files exist
  # "hsb0-openclaw-m365-cal-client-id.age".publicKeys = markus ++ hsb0;
  # "hsb0-openclaw-m365-cal-tenant-id.age".publicKeys = markus ++ hsb0;
  # "hsb0-openclaw-m365-cal-client-secret.age".publicKeys = markus ++ hsb0;

  # ============================================================================
  # MINISERVER-BP secrets — MOVED to BYTEPOETS/bpnixcfg on 2026-05-02 (INSPR-24)
  # ============================================================================
  # 14 secrets (wireguard-key + 4 openclaw + gogcli + 3 m365 + github-pat +
  # percy-nextcloud-share + mattermost-bot-token + openclaw-pmo-token, plus
  # fleetcom-token-miniserver-bp moved separately above) live in
  # bpnixcfg/secrets/. Recipients: markus_personal + miniserver-bp host
  # (transitional; INSPR-24 Stage 3 will re-encrypt to a dedicated
  # BYTEPOETS internal-ops keypair). See INSPR-24 commit history.

  # Merlin AI SSH key to access hsb1
  "hsb0-merlin-ssh-key.age".publicKeys = markus ++ hsb0;

  # ============================================================================
  # AGENT-EXCEPTION SECRETS — inspr.secrets.agents.* module (Phase 1)
  # ============================================================================
  # Layout: secrets/agents/{shared,host/<hostname>}/<NAME>.age
  # Materialized at activation to /Users/mba/.inspr/secrets/agents/<NAME>.env (INSPR-164 canonical)
  # See ~/Code/inspr/proposals/agent-secrets/ for the architecture.

  # GitHub PAT for @markus-barta on this device (mbp0).
  # Per-device for per-device revocability. Filename = GH_TOKEN.age so the
  # materialized env file is GH_TOKEN.env — gh CLI auto-picks up $GH_TOKEN.
  # Format inside the .age file: GH_TOKEN=ghp_xxxxxxxxxxxx
  # Edit: agenix -e secrets/agents/host/mbp0/GH_TOKEN.age
  # NOTE 2026-07-03 (NIX-216): content rotated to mbp2607-gh-token — the
  # BP-era mba-mbp-m5-work PAT is deleted. mbp0 shares the mbp2607 token
  # for its final days before the mbp2606 rehome (Markus's call: interim
  # per-device token would be overkill).
  "agents/host/mbp0/GH_TOKEN.age".publicKeys = markus ++ mbp0;

  # GitHub PAT for @markus-barta on mbp2607 (NIX-215). Same format.
  # Edit: agenix -e secrets/agents/host/mbp2607/GH_TOKEN.age
  "agents/host/mbp2607/GH_TOKEN.age".publicKeys = markus ++ mbp2607;

  # Onshape API credentials (key + secret) — paired Onshape developer
  # access tokens; rotate together. Migrated from retired imac0 to current
  # mbp0/M5 Max workstation during imac0 decommission prep (NIX-176).
  # Materialized to ~/.inspr/secrets/agents/ONSHAPE.env.
  # Format inside the .age file (two lines):
  #   ONSHAPE_API_KEY=<access key>
  #   ONSHAPE_API_SECRET=<secret key>
  # Recipients: markus aggregate (agent-secrets is HM-level and decrypts with
  # the user SSH key) plus mbp0 host key for recovery/rekey flexibility.
  # Edit: agenix -e secrets/agents/host/mbp0/ONSHAPE.age
  "agents/host/mbp0/ONSHAPE.age".publicKeys = markus ++ mbp0;

  # ────────────────────────────────────────────────────────────────────────
  # Shared agent secrets (cross-machine)
  # Format inside each .age file: <VARNAME>=<value>
  # Workflow per secret: agenix -e secrets/agents/shared/<NAME>.age → paste → save
  # ────────────────────────────────────────────────────────────────────────
  # Recipients = markus (user) + every macOS host using inspr.secrets.agents.
  # Add more hosts here as they join the pipeline (rekey afterwards).

  # Cloudflare DNS API token (AIA account)
  "agents/shared/CF_DNS_TOKEN_AIA.age".publicKeys = markus ++ mbp0 ++ mbp2607;

  # Cloudflare Zone API token (AIA account)
  "agents/shared/CF_ZONE_TOKEN_AIA.age".publicKeys = markus ++ mbp0 ++ mbp2607;

  # PMO (BYTEPOETS Project Management Online) secrets REMOVED 2026-07-13.
  # The instance (pm.bytepoets.com) was decommissioned with the BYTEPOETS
  # departure (2026-06-15). PMOAPIKEY / PMOURL / PMOSERVER{PASS,URL,USER} /
  # PMOSSHKEYFILELOCATION are gone from secrets/agents/shared/, and the
  # matching `instances.pmo` block is gone from markus-defaults.nix.
  # PPM (pm.barta.cm) is now the only Paimos instance.

  # PPM = Personal Project Management (Markus's personal Paimos at pm.barta.cm)
  "agents/shared/PPMAPIKEY.age".publicKeys = markus ++ mbp0 ++ mbp2607;

  # Zitadel machine-user JWT profile for inspr-services OpenTofu (INSPR-198).
  # Content: JSON key of inspr-services-tf (ORG_OWNER @ auth.inspr.at),
  # minted on csb1 by inspr-services/scripts/bootstrap-tf-sa.sh.
  # Edit: agenix -e secrets/agents/shared/ZITADEL_TF_KEY.age
  "agents/shared/ZITADEL_TF_KEY.age".publicKeys = markus ++ mbp0 ++ mbp2607;

  # Home WiFi credentials — used by awtrix-rescue and any future
  # device-provisioning helpers that drive a device through its AP-mode
  # captive portal. Paired creds in one .env file:
  #   HOMEWIFI_SSID=<ssid>
  #   HOMEWIFI_PASS=<password>
  # Edit: agenix -e secrets/agents/shared/HOMEWIFI.age
  "agents/shared/HOMEWIFI.age".publicKeys = markus ++ mbp0 ++ mbp2607;

  # ────────────────────────────────────────────────────────────────────────
  # INSPR-170: inspr.git.atelier Strategy B — per-host user SSH keys
  # ────────────────────────────────────────────────────────────────────────
  # One ed25519 keypair per (host × identity). Privkey is the contents of
  # the .age file; pubkey is registered on the matching GitHub user account
  # (markus-barta or bytepoets-mba). Generated 2026-05-12 with no expiry.
  #
  # Materialization: agent-secrets HM module decrypts at activation to
  #   ~/.inspr/secrets/agents/<host>-<atelier>-userkey.env (mode 0400)
  # The `.env` extension is a quirk of agent-secrets's filename convention —
  # SSH does not care; the file is a standard OpenSSH ed25519 private key.
  #
  # Recipients = markus aggregate only (HM-level agent-secrets decrypts via
  # user SSH key, not host key).
  #
  # Edit (re-create) workflow: agenix -e secrets/agents/host/<host>/<name>.age

  # m5 (mbp0)
  "agents/host/mbp0/m5-personal-userkey.age".publicKeys = markus;
  "agents/host/mbp0/m5-bytepoets-userkey.age".publicKeys = markus;

  # mbp2607 (NIX-215, 2026-07-03) — personal only; no BYTEPOETS key on this
  # host by design (post-exit fresh start).
  "agents/host/mbp2607/mbp2607-personal-userkey.age".publicKeys = markus;

  # Archived imac0 user keys (host decommissioned). Kept encrypted for
  # emergency recovery/audit only; archive paths are not materialized by
  # inspr.secrets.agents on any active host.
  "agents/archive/imac0/imac0-personal-userkey.age".publicKeys = markus;
  "agents/archive/imac0/imac0-bytepoets-userkey.age".publicKeys = markus;

}
