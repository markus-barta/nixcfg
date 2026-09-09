# IB Gateway on hsb0 (paper) — enabled

**Status (2026-09-09)**: Compose service `ib-gateway` is **enabled** (paper) on hsb0.
Default `compose up` / stack reconcile starts it. Password is wired via agenix
(`TWS_PASSWORD_FILE`). **Mac IB Gateway must stay down** while hsb0 owns the
paper session. Desks connect **directly over Tailscale** to `100.64.0.6:4002`
(MagicDNS is off for Markus — use the IP, not a hostname). Do **not** run an
SSH `-L` tunnel on the Mac. Do **not** bind `0.0.0.0` or the LAN IP
`192.168.1.99` (plaintext IB API).

| Item                | Value                                                                              |
| ------------------- | ---------------------------------------------------------------------------------- |
| Image               | `ghcr.io/gnzsnz/ib-gateway:10.45` (Mac desks use 10.45; stable channel = 10.45.1j) |
| Mode                | paper only (`TRADING_MODE=paper`)                                                  |
| API bind            | `100.64.0.6:4002` → container `4004` (socat → internal `4002`)                     |
| Live API            | **not published** (no `4001`/`4003`)                                               |
| IBKR login          | username `markusbarta` (one login for paper + live); password via agenix           |
| Paper account (ref) | `DUR970597` — selected by `TRADING_MODE=paper`                                     |
| Live account (ref)  | `U28240205` — only if `TRADING_MODE=live`/`both`; **port 4001 not published**      |
| Settings volume     | `/var/lib/ib-gateway/tws_settings` (`TWS_SETTINGS_PATH`; host dir owned uid 1000)  |
| Heap / mem          | `JAVA_HEAP_SIZE=768`; compose `mem_limit=1280m`                                    |
| Docs upstream       | https://github.com/gnzsnz/ib-gateway-docker                                        |

## One IBKR login

Interactive Brokers uses **one username/password** (`markusbarta`) for both the
paper account (`DUR970597`) and the live account (`U28240205`). Which book you
get is selected at Gateway start via `TRADING_MODE` (`paper` / `live` / `both`),
not via separate credentials. This host stays **`paper` only** and does **not**
publish live API port `4001` until Markus explicitly keys a live cut.

## Security

- IB API is **plaintext TCP**. Port is bound to the **Tailscale IP only**
  (`100.64.0.6:4002`). Firewall allows TCP `4002`, but compose does **not**
  publish on LAN `192.168.1.99` or `0.0.0.0`.
- Mac must **not** run IB Gateway and must **not** run `ssh -L …4002…`. Desks
  (Joe/Joel/J) point at `100.64.0.6:4002` over Tailscale
  (`EXISTING_SESSION_DETECTED_ACTION=primary` on hsb0).
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

## Desk access (Tailscale direct)

Desks on the Mac (and other tailnet clients) connect straight to hsb0:

```bash
# From Mac (Tailscale client 100.64.0.14) — should succeed
nc -z -w 3 100.64.0.6 4002

# Local Mac 4002 must stay free (no Gateway, no tunnel)
nc -z -w 2 127.0.0.1 4002   # expect failure
```

Scripts default `IB_GATEWAY_HOST=100.64.0.6` (override via env). Paper port
stays `4002` only. Do **not** reintroduce an SSH local forward.

Confirm on hsb0 after switch:

```bash
ss -ltn | grep 4002   # expect 100.64.0.6:4002 (not 127.0.0.1 / 0.0.0.0)
docker ps --filter name=ib-gateway
```

## Park again

Restore `profiles = [ "ib-gateway" ];`, comment out the password volume/env,
switch, confirm container gone. Settings under `/var/lib/ib-gateway/tws_settings`
are kept.

## Still gated / follow-ups

- Interactive / device 2FA on first login (approve on IBKR mobile if prompted)
- IB TrustedIPs / API access approval for hsb0 if required
- Live trading ports remain unpublished
