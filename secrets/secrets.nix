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

  # Markus' personal key (~/.ssh/id_rsa)
  markus = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt"
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

  miniserver-bp = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIINZUHm99JEREiB538opcE04Ho/2EpgoE26EKVGdc4oF root@miniserver-bp"
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

  # NixFleet agent API token
  # Format: NIXFLEET_TOKEN=xxx (for NixOS EnvironmentFile)
  # Edit: agenix -e secrets/nixfleet-token.age
  # TODO: Rename to shared-nixfleet-token.age
  "nixfleet-token.age".publicKeys =
    markus ++ hsb0 ++ hsb1 ++ hsb8 ++ csb0 ++ csb1 ++ gpc0 ++ miniserver-bp;

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
  # GitHub PAT for @merlin-ai-mba (workspace git push)
  # Edit: agenix -e secrets/hsb0-openclaw-github-pat.age
  "hsb0-openclaw-github-pat.age".publicKeys = markus ++ hsb0;
  # M365 calendar (read-only) - Azure AD app: Merlin-AI-hsb0-cal
  # TODO: Uncomment when Azure AD app is created and .age files exist
  # "hsb0-openclaw-m365-cal-client-id.age".publicKeys = markus ++ hsb0;
  # "hsb0-openclaw-m365-cal-tenant-id.age".publicKeys = markus ++ hsb0;
  # "hsb0-openclaw-m365-cal-client-secret.age".publicKeys = markus ++ hsb0;

  # WireGuard private key for miniserver-bp (BYTEPOETS VPN)
  # Edit: agenix -e secrets/miniserver-bp-wireguard-key.age
  "miniserver-bp-wireguard-key.age".publicKeys = markus ++ miniserver-bp;

  # OpenClaw Percaival secrets
  # Edit: agenix -e secrets/miniserver-bp-openclaw-*.age
  "miniserver-bp-openclaw-telegram-token.age".publicKeys = markus ++ miniserver-bp;
  "miniserver-bp-openclaw-gateway-token.age".publicKeys = markus ++ miniserver-bp;
  "miniserver-bp-openclaw-openrouter-key.age".publicKeys = markus ++ miniserver-bp;
  "miniserver-bp-openclaw-brave-key.age".publicKeys = markus ++ miniserver-bp;

  # gogcli keyring password for OpenClaw Percaival container
  # Format: GOG_KEYRING_PASSWORD=<password> (KEY=VALUE for Docker environmentFiles)
  # Edit: agenix -e secrets/miniserver-bp-gogcli-keyring-password.age
  "miniserver-bp-gogcli-keyring-password.age".publicKeys = markus ++ miniserver-bp;

  # M365 (CLI for Microsoft 365) credentials for OpenClaw Percaival
  # Azure AD app: Percy-AI-miniserver-bp (dedicated app registration)
  # Format: Plain text value (no KEY=VALUE)
  # Edit: agenix -e secrets/miniserver-bp-m365-client-id.age
  # Edit: agenix -e secrets/miniserver-bp-m365-tenant-id.age
  # Edit: agenix -e secrets/miniserver-bp-m365-client-secret.age
  "miniserver-bp-m365-client-id.age".publicKeys = markus ++ miniserver-bp;
  "miniserver-bp-m365-tenant-id.age".publicKeys = markus ++ miniserver-bp;
  "miniserver-bp-m365-client-secret.age".publicKeys = markus ++ miniserver-bp;

  # GitHub PAT for Percy AI (@bytepoets-percyai)
  # Format: GITHUB_PAT=<token>
  # Edit: agenix -e secrets/miniserver-bp-github-pat.age
  "miniserver-bp-github-pat.age".publicKeys = markus ++ miniserver-bp;

}
