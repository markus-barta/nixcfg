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
| API capability      | paper API writes enabled (`READ_ONLY_API=no`)                                      |
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

## Paper API write capability

Paper desk clients require the Gateway to accept API write operations, so the
canonical compose configuration sets `READ_ONLY_API=no`. With Gateway read-only
mode enabled, operations observed uncleared write-access confirmation dialogs
and clients timing out while waiting for `nextValidId`. After a switch and
`ib-gateway` recreate, the canonical setting makes the temporary compose
override unnecessary.

This setting permits paper API writes; it does not grant any client authority
to place orders. Each client remains responsible for its own order policy. The
Joe board pusher remains read-only by implementation, independently of the
Gateway capability used by separately authorized paper clients.

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

## Session supervisor (HOSTD-58)

Docker Up and a live socat relay on container **4004** do not mean the paper
API (**internal 4002**) is listening, and a listening API does not mean IBKR
upstream is connected. `ib-gateway-session.timer` (every 5 min) classifies:

| Phase                  | Meaning                                                                                                                              |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `slowstarting`         | Container or known restart is inside 12 min grace. No restart.                                                                       |
| `authenticating`       | IBC login in progress. Wait; do not loop restarts.                                                                                   |
| `api_ready`            | Internal **4002** LISTEN and a _recent_ joe-board-pusher publish with `gateway: true`. `generatedAt` may stay still on a quiet book. |
| `upstream_unavailable` | API 4002 is up but a current pusher publish reports `gateway: false` (1100/2110 class).                                              |
| `halted`               | Budget spent, prolonged auth, corrupt state, or IBC `fullauthrequired`. Operator action.                                             |

Recovery restarts **only** `ib-gateway`, through the existing managed lock
`/run/lock/compose-hsb0.lock` (reserve+fsync the one attempt **before** Docker
restart). No stack-wide `compose up`, no override files, no other containers.
**One restart per outage** until a real healthy session (`api_ready`) or
operator clear. Docker timeout/permission/nonzero probes are UNKNOWN: no
restart and no budget reset. A confirmed stopped container is distinct from
UNKNOWN. A `gateway: true` line published before the current Gateway start does
not reset the budget.

A recent operator/agent restart starts grace; it does not trigger an immediate
second restart. TCP to host `100.64.0.6:4002` only proves the relay. Quiet
books may keep a still `generatedAt`; publication time is the docker log
timestamp. Family-history/ledger files are ignored. Do not label a stuck
login as 2FA unless IBC evidence (`fullauthrequired` / 2FA markers) is
present. IBC `Authenticating` followed by `Login has completed` is logged-in;
that phase is kept for the current container generation (container ID + PID 1
`/proc/1/stat` start ticks, not rounded `docker ps` "Up N minutes") if later
log tails are only relay spam. A new init startticks or container ID is a real
restart; pusher health requires a publish after that exact start epoch.

### Unrecovered-session notifications (HOSTD-59)

The declared destination is managed email plus Amy's existing Grok chat. The
`email-agent-bus` adapter uses the existing `docker-smtp-1` relay for mail and
Paimos project17's `grok_bot:amy` receiver for chat. It does not start the parked
OpenClaw container or copy Amy's webhook capability or secret out of Paimos.
The message identifies the automatic paper monitor and asks Amy to SendToUser
only; it never requests a trade, restart, or account change.

`hsb0-gateway-notify-config.age` contains destination metadata. The existing
`hsb0-ppm-api-key` supplies Paimos authentication. systemd `LoadCredential`
provides private copies to this service; no destination or API key enters the
Nix store, command logs, or alert-state files. No existing secret is rekeyed.

The five-minute timer waits for at least ten minutes of sustained failure
(and ten minutes after an attempted restart), then sends on the next eligible
observation: normally 10–15 minutes before notification. Email and chat each
have independent durable delivery state. Successful delivery is announced once
per outage; failed channels retry at most once every five minutes without
resending a successful sibling. Unknown probes and restart grace do not clear
an outage. Only fresh, confirmed paper-Gateway readiness sends a recovery notice.

Mail acceptance proves the managed relay queued it. Paimos message acceptance
proves a durable bus message; the corresponding delivery must reach
`handed_off`, and Amy's user-visible message is separate evidence. A controlled
alert/recovery test must retain both message IDs and the observed delivery
results; neither HTTP200 nor SMTP queue acceptance alone proves inbox/chat display.
Do not disturb the actual Gateway to test notification delivery.

To clear a halt after fixing login by hand:

```bash
sudo touch /var/lib/ib-gateway-session/operator-clear
sudo systemctl start ib-gateway-session
```

Read-only status (no env dump, no raw logs):

```bash
systemctl status ib-gateway-session.timer
journalctl -u ib-gateway-session -n 20 --no-pager
# expect api4002 vs relay4004 in the JSON summary; never cat agenix or docker inspect
ss -ltn | grep 4002   # host bind only; supervisor measures internal 4002
```

## Park again

Restore `profiles = [ "ib-gateway" ];`, comment out the password volume/env,
switch, confirm container gone. Settings under `/var/lib/ib-gateway/tws_settings`
are kept.

## Still gated / follow-ups

- Interactive / device 2FA on first login (approve on IBKR mobile if prompted)
- IB TrustedIPs / API access approval for hsb0 if required
- Live trading ports remain unpublished
