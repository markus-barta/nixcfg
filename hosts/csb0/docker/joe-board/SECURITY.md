# Joe household board — security notes

## Assets

- Paper household PnL projection (`inspr.joe.household.v1`) on `https://cs0.barta.cm/joe/`
- Machine inbox `POST /joe/inbox` (Bearer token)
- Producer on hsb0 reading **paper** IB Gateway `100.64.0.6:4002` only

## Threats

| Threat                          | Control                                                                                                                |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Public scrape of household PnL  | Browser routes behind Traefik **hostdash-auth** (oauth2-proxy / Zitadel), same pattern as HostDash                     |
| Unauthenticated inbox write     | App-level Bearer token (agenix); Traefik inbox router has **no** OAuth middleware; missing/wrong token → 401           |
| Oversized / hostile JSON        | Body size cap (256 KiB); schema validation; reject non-`PAPER` / wrong schema; atomic store                            |
| IB credentials in cloud         | **None** on csb0 — only the push token. IB password stays on hsb0 for Gateway                                          |
| Accidental live trading         | Pusher hard-codes port 4002; refuses 4001; read-only IB API clientId 50; UI has no order controls                      |
| Token theft                     | Token in agenix (`joe-board-push-token.age`); rotate by re-encrypting + `just switch` on csb0 and hsb0                 |
| Path confusion (OAuth vs inbox) | Separate Traefik routers: `/joe/inbox` higher priority, no forwardauth; `/joe/` and `/joe/data.json` use hostdash-auth |

## Residual risk

- Bearer token is a shared secret; compromise of hsb0 or csb0 agenix material allows inbox spoofing (not broker access from csb0 alone).
- oauth2-proxy session theft could expose the board UI to an attacker who already has a browser cookie for `.barta.cm`.
- Projection is not a compliance ledger; values are Stage-0 virtual €5k desks + attributed paper PnL.
- Legacy Mac `book.json` → hsb1 path and LAN board may still exist until explicitly retired.

## Rotate push token

```fish
cd ~/Code/nixcfg
# generate and encrypt (recipients: markus + csb0 + hsb0 via secrets.nix)
openssl rand -hex 32 > /tmp/joe-board-push-token.txt
EDITOR='cp /tmp/joe-board-push-token.txt' just edit-secret secrets/joe-board-push-token.age
shred -u /tmp/joe-board-push-token.txt
# commit, merge, then:
ssh -p 2222 mba@csb0 'cd ~/nixcfg && git pull && just switch'
ssh mba@hsb0 'cd ~/nixcfg && git pull && just switch'
```

## Change push interval

Compose env `JOE_PUSH_INTERVAL_SEC` (default `30`) on `joe-board-pusher` in
`hosts/hsb0/docker/compose-spec.nix`. Redeploy hsb0.
