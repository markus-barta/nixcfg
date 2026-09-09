# IB Gateway on hsb0 (paper) — parked scaffold

**Status (2026-09-09)**: Compose service `ib-gateway` is **parked** behind inactive
profile `ib-gateway`. Default `compose up` / stack reconcile does **not** start it.
No credentials are wired yet. Container must stay stopped until cutover.

| Item                | Value                                                                              |
| ------------------- | ---------------------------------------------------------------------------------- |
| Image               | `ghcr.io/gnzsnz/ib-gateway:10.45` (Mac desks use 10.45; stable channel = 10.45.1j) |
| Mode                | paper only (`TRADING_MODE=paper`)                                                  |
| API bind            | `127.0.0.1:4002` → container `4004` (socat → internal `4002`)                      |
| Live API            | **not published** (no `4001`/`4003`)                                               |
| Paper account (ref) | `DUR970597` — userid/password via agenix at enable                                 |
| Live account        | `U28240205` / port 4001 stays **OFF** on hsb0                                      |
| Settings volume     | `/var/lib/ib-gateway/tws_settings` (`TWS_SETTINGS_PATH`)                           |
| Heap / mem          | `JAVA_HEAP_SIZE=768`; compose `mem_limit=1280m`                                    |
| Docs upstream       | https://github.com/gnzsnz/ib-gateway-docker                                        |

## Why parked

Same pattern as OpenClaw (`profiles = [ "openclaw" ]`, PR #561): keep the
declaration in the stack for a fast reactivate, but do not consume RAM or risk
an IB session fight with the Mac Gateway while credentials / TrustedIPs / remote
access are unfinished.

## Security

- IB API is **plaintext TCP**. Port is bound to **localhost only** until an SSH
  tunnel or Tailscale-scoped bind is designed. Do **not** open firewall 4002 to
  the LAN and do **not** bind `0.0.0.0` yet.
- Mac IB Gateway (desks Joe/Joel/J on `127.0.0.1:4002`) and hsb0 **cannot both
  own the same IB session**. Cutover = **stop Mac Gateway first**, then enable
  hsb0 (or use `EXISTING_SESSION_DETECTED_ACTION=primaryoverride` only when
  intentionally taking over).
- No Traefik. Watchtower disabled.

## Reactivate (cutover checklist)

1. Stop Mac IB Gateway (paper session on 4002).
2. Create agenix secret `secrets/hsb0-ib-gateway-password.age` (password only;
   do not commit plaintext). Uncomment `age.secrets.hsb0-ib-gateway-password` in
   `hosts/hsb0/configuration.nix`.
3. In `hosts/hsb0/docker/compose-spec.nix`:
   - Set `TWS_USERID` (paper login — not inventable in git).
   - Uncomment `TWS_PASSWORD_FILE=/run/secrets/ib-gateway-password`.
   - Uncomment the `/run/agenix/hsb0-ib-gateway-password` volume mount.
   - Remove the `profiles = [ "ib-gateway" ];` line **or** start with
     `docker compose --profile ib-gateway up -d ib-gateway`.
4. Complete 2FA / IBC TrustedIPs as required by IBKR for the new host.
5. `just switch` on hsb0 (or equivalent). Confirm `docker ps` shows `ib-gateway`
   and `ss -ltn | grep 4002` is `127.0.0.1:4002` only.
6. Point desks at hsb0 via SSH tunnel or Tailscale — not raw LAN yet.

## Park again

Restore `profiles = [ "ib-gateway" ];`, switch, confirm container gone. Settings
under `/var/lib/ib-gateway/tws_settings` are kept.

## Still gated

- Credentials (`TWS_USERID` + agenix `TWS_PASSWORD_FILE`)
- Interactive / device 2FA on first login
- IB TrustedIPs / API access approval for hsb0
- Session cutover vs Mac Gateway
- Remote access design (SSH tunnel vs Tailscale bind); firewall 4002 stays closed
