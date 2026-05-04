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
  markus_m5_ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP9FWi8t5l5fA4ps3+Qos2U4VbVY712kxQeIOczHaXs6 mba@mba-mbp-m5-work"; # added INSPR-78 (2026-05-03)
  markus_imac0_ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOdow+y+02Ekej5q3JD+5SSCWDDW4Hmiwwbfe9fTYUBA markus@imac0"; # added INSPR-78 (2026-05-03)

  markus = [
    markus_rsa_legacy
    markus_m5_ed25519
    markus_imac0_ed25519
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
  # First macOS host as agenix recipient (mba-mbp-m5-work, added 2026-05-01).
  # macOS does NOT auto-generate /etc/ssh/ssh_host_ed25519_key — manually
  # created via:
  #     sudo ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N "" \
  #          -C "root@<hostname>"
  # This key is dedicated to agenix decryption; sshd is not explicitly
  # configured to use it (Apple's CryptoTokenKit handles SSH service keys
  # separately on modern macOS). See playbook field notes for context.

  "mba-mbp-m5-work" = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH6ene6+iB5I9brFPfFwuqNil7nbJpWguycyZqv67+LU root@mba-mbp-m5-work"
  ];

  # imac0: second macOS host onboarded to inspr.secrets.agents (2026-05-01).
  # Host key was already present (Intel iMac, pre-INSPR setup); this is its
  # /etc/ssh/ssh_host_ed25519_key.pub registered as an agenix recipient.
  imac0 = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICIFF/rwrg7ajnKf9vFjQIK6leHbl1JqmVcrspowGW3y root@imac0"
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

  # NixFleet agent API token — DEPRECATED (replaced by FleetCom per-host tokens)
  # TODO: Remove after FleetCom is fully deployed
  "nixfleet-token.age".publicKeys =
    markus ++ hsb0 ++ hsb1 ++ hsb8 ++ csb0 ++ csb1 ++ gpc0;

  # FleetCom agent tokens — one per host, plain text bearer token
  # Generate in FleetCom UI (Hosts → Add Host), paste token into .age file
  # Edit: agenix -e secrets/fleetcom-token-<host>.age
  "fleetcom-token-hsb0.age".publicKeys = markus ++ hsb0;
  "fleetcom-token-hsb1.age".publicKeys = markus ++ hsb1;
  # hsb2: no host key in agenix (Raspberry Pi, Raspbian — not NixOS)
  "fleetcom-token-hsb8.age".publicKeys = markus ++ hsb8;
  "fleetcom-token-csb0.age".publicKeys = markus ++ csb0;
  "fleetcom-token-csb1.age".publicKeys = markus ++ csb1;
  "fleetcom-token-gpc0.age".publicKeys = markus ++ gpc0;
  # fleetcom-token-miniserver-bp.age moved to BYTEPOETS/bpnixcfg with msbp (2026-05-02)

  # FleetCom ↔ OpenClaw per-gateway operator identity (FLEET-51/52).
  # FleetCom connects to each gateway's WS RPC with a gateway-scoped
  # Ed25519 keypair + operator token. Pre-seeded into OpenClaw's
  # paired.json at container boot so the first handshake is zero-touch.
  #   -key.age : PKCS#8 Ed25519 private PEM (fleetcom container only)
  #   -tok.age : shared operator token (both fleetcom + gateway hosts)
  # Public half lives alongside the compose as a plain PEM (non-secret).
  "fleetcom-openclaw-hsb0-key.age".publicKeys = markus ++ csb1;
  "fleetcom-openclaw-hsb0-tok.age".publicKeys = markus ++ csb1 ++ hsb0;

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

  # PPM (Personal Project Management) environment variables for csb1
  # Format: KEY=VALUE lines (PPM_ADMIN_PASSWORD, COOKIE_SECURE, etc.)
  # Edit: agenix -e secrets/csb1-ppm-env.age
  "csb1-ppm-env.age".publicKeys = markus ++ csb1;

  # MinIO environment variables for csb1 (PPM attachment storage)
  # Format: KEY=VALUE lines (MINIO_ROOT_USER, MINIO_ROOT_PASSWORD, etc.)
  # Edit: agenix -e secrets/csb1-minio-env.age
  "csb1-minio-env.age".publicKeys = markus ++ csb1;

  # FleetCom environment variables for csb1
  # Format: KEY=VALUE lines (FLEETCOM_PASSWORD_HASH, FLEETCOM_TOTP_SECRET)
  # Edit: agenix -e secrets/csb1-fleetcom-env.age
  "csb1-fleetcom-env.age".publicKeys = markus ++ csb1;

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
  # Materialized at activation to /Users/mba/Secrets/age/decrypted/agents/<NAME>.env
  # See ~/Code/inspr/proposals/agent-secrets/ for the architecture.

  # GitHub PAT for @markus-barta on this device (mba-mbp-m5-work).
  # Per-device for per-device revocability. Filename = GH_TOKEN.age so the
  # materialized env file is GH_TOKEN.env — gh CLI auto-picks up $GH_TOKEN.
  # Format inside the .age file: GH_TOKEN=ghp_xxxxxxxxxxxx
  # Edit: agenix -e secrets/agents/host/mba-mbp-m5-work/GH_TOKEN.age
  "agents/host/mba-mbp-m5-work/GH_TOKEN.age".publicKeys = markus ++ mba-mbp-m5-work;

  # ────────────────────────────────────────────────────────────────────────
  # Shared agent secrets (cross-machine)
  # Format inside each .age file: <VARNAME>=<value>
  # Workflow per secret: agenix -e secrets/agents/shared/<NAME>.age → paste → save
  # ────────────────────────────────────────────────────────────────────────
  # Recipients = markus (user) + every macOS host using inspr.secrets.agents.
  # Add more hosts here as they join the pipeline (rekey afterwards).

  # Cloudflare DNS API token (AIA account)
  "agents/shared/CF_DNS_TOKEN_AIA.age".publicKeys = markus ++ mba-mbp-m5-work;

  # Cloudflare Zone API token (AIA account)
  "agents/shared/CF_ZONE_TOKEN_AIA.age".publicKeys = markus ++ mba-mbp-m5-work;

  # PMO = BYTEPOETS Project Management Online (the company Paimos instance).
  # NOTE: BYTEPOETS-context credentials. Long-term these belong in a
  # BYTEPOETS-private flake (per Pattern β), not Markus's personal nixcfg.
  # Currently in shared/ as a transitional layer until BYTEPOETS gets its
  # own flake — flag for migration when that happens.
  "agents/shared/PMOAPIKEY.age".publicKeys           = markus ++ mba-mbp-m5-work;
  "agents/shared/PMOSERVERPASS.age".publicKeys       = markus ++ mba-mbp-m5-work;
  "agents/shared/PMOSERVERURL.age".publicKeys        = markus ++ mba-mbp-m5-work;
  "agents/shared/PMOSERVERUSER.age".publicKeys       = markus ++ mba-mbp-m5-work;
  "agents/shared/PMOSSHKEYFILELOCATION.age".publicKeys = markus ++ mba-mbp-m5-work;
  "agents/shared/PMOURL.age".publicKeys              = markus ++ mba-mbp-m5-work;

  # PPM = Personal Project Management (Markus's personal Paimos at pm.barta.cm)
  "agents/shared/PPMAPIKEY.age".publicKeys = markus ++ mba-mbp-m5-work;

}
