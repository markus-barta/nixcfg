# IB Gateway on hsb0 (paper) — enabled

**Status (2026-09-09)**: Compose service `ib-gateway` is **enabled** (paper) on hsb0.
Default `compose up` / stack reconcile starts it. Password is wired via agenix
(`TWS_PASSWORD_FILE`). **Mac IB Gateway must stay down** while hsb0 owns the
paper session. Desks reach the API via SSH local forward to `127.0.0.1:4002`
until a Tailscale-scoped bind is designed. Do **not** bind `0.0.0.0` or open
firewall 4002 to the LAN.

| Item                | Value                                                                              |
| ------------------- | ---------------------------------------------------------------------------------- |
| Image               | `ghcr.io/gnzsnz/ib-gateway:10.45` (Mac desks use 10.45; stable channel = 10.45.1j) |
| Mode                | paper only (`TRADING_MODE=paper`)                                                  |
| API bind            | `127.0.0.1:4002` → container `4004` (socat → internal `4002`)                      |
| Live API            | **not published** (no `4001`/`4003`)                                               |
| IBKR login          | username `markusbarta` (one login for paper + live); password via agenix           |
| Paper account (ref) | `DUR970597` — selected by `TRADING_MODE=paper`                                     |
| Live account (ref)  | `U28240205` — only if `TRADING_MODE=live`/`both`; **port 4001 not published**      |
| Settings volume     | `/var/lib/ib-gateway/tws_settings` (`TWS_SETTINGS_PATH`)                           |
| Heap / mem          | `JAVA_HEAP_SIZE=768`; compose `mem_limit=1280m`                                    |
| Docs upstream       | https://github.com/gnzsnz/ib-gateway-docker                                        |

## One IBKR login

Interactive Brokers uses **one username/password** (`markusbarta`) for both the
paper account (`DUR970597`) and the live account (`U28240205`). Which book you
get is selected at Gateway start via `TRADING_MODE` (`paper` / `live` / `both`),
not via separate credentials. This host stays **`paper` only** and does **not**
publish live API port `4001` until Markus explicitly keys a live cut.

## Security

- IB API is **plaintext TCP**. Port is bound to **localhost only** until an SSH
  tunnel or Tailscale-scoped bind is designed. Do **not** open firewall 4002 to
  the LAN and do **not** bind `0.0.0.0` yet.
- Mac IB Gateway (desks Joe/Joel/J on `127.0.0.1:4002`) and hsb0 **cannot both
  own the same IB session**. Keep Mac Gateway stopped while hsb0 is primary
  (`EXISTING_SESSION_DETECTED_ACTION=primary`).
- No Traefik. Watchtower disabled.

## Credentials (agenix)

Password secret: `secrets/hsb0-ib-gateway-password.age` (decryptable by Markus +
hsb0). Body must be the **raw paper password only** (no `KEY=`, no quotes,
preferably no trailing newline). Username in compose: `TWS_USERID=markusbarta`.
Volume mount + `TWS_PASSWORD_FILE` are active.

Verify decrypt (should print only `***` length, not the secret):

```fish
agenix -d secrets/hsb0-ib-gateway-password.age | wc -c
```

## Desk access (SSH local forward)

Until Tailscale bind is designed, desks keep using `127.0.0.1:4002` via a lasting
SSH local forward from the Mac (Mac Gateway must stay down):

```bash
ssh -fN -o ExitOnForwardFailure=yes -L 127.0.0.1:4002:127.0.0.1:4002 hsb0
```

Restart the tunnel the same way if it dies (e.g. after sleep/network change).
Confirm nothing else is bound on Mac `4002` first (`lsof -nP -iTCP:4002 -sTCP:LISTEN`).

## Park again

Restore `profiles = [ "ib-gateway" ];`, comment out the password volume/env,
switch, confirm container gone. Settings under `/var/lib/ib-gateway/tws_settings`
are kept.

## Still gated / follow-ups

- Interactive / device 2FA on first login (approve on IBKR mobile if prompted)
- IB TrustedIPs / API access approval for hsb0 if required
- Remote access design (Tailscale bind); firewall 4002 stays closed
- Live trading ports remain unpublished
