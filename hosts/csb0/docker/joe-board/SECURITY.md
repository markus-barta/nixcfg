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

## OPS-354 identity boundary

JoeDesk has no published host port and uses the private Traefik network. The
edge removes client `X-Auth-Request-User`, `X-Auth-Request-Email`,
`X-Auth-Request-Preferred-Username`, `X-Auth-Request-Groups`, `X-Forwarded-User`,
`X-Forwarded-Email` and `X-Forwarded-Preferred-Username` before SSO, then forwardAuth replaces user/email from
oauth2-proxy's authenticated response. Health and token inbox use the same
strip middleware without SSO. Only exact `/joe/healthz` GET/HEAD is public
health; other methods, near-health paths, all six reads, UI and assets enter
SSO. The edge must never add, remove or rewrite `X-JoeDesk-Origin`: app-stamped
401s do not prove SSO enforcement. See T76 and the deployment runbook.
The TLS entrypoint also deletes punctuation aliases before routing/auth using
`aliasHeadersStrategy: delete` (Traefik >=3.7.12). OPS must verify the running
version before cutover because the image is unpinned. Static, live and lab
negative checks cover underscore/dot identities; v2 reads only the exact
`x-auth-request-user` key and oauth2-proxy takes identity from its session.

## Compatible data and rollback boundary

The release set selects board/pusher/executor compatibility together. v1 has
no public health or v2 contract; never give a v2 store to a v1 board. Freeze
all writers before backup/staging/swap. The shared swap requires a same-volume
new sibling, rejects symlinks/hardlinks, normalizes uid/gid and 0700/0600
modes, retains the old directory and recovers it on a failed second rename.
The production command requires root on csb0 for the swap, operator y/N
confirmations and a private verified backup/image/generation record. Remote
Docker contexts and fleet rehearsal hosts are refused. Lab fixtures and stub
authentication are never production authorization evidence. Preserve exact
images/generations/source GC roots until rollback is no longer required.

### Separate Results ingress proposal — pending JOED-27 merge + LEAD confirmation

OPS-354 item 5 deliberately exceeds README P6b item 4. Keep it as a separately
droppable review item; do not deploy it until JOED-27 merges and LEAD confirms.
The proposed exact **POST** `/joe/inbox/results` router uses identity stripping and
app-level Bearer checking, without SSO. It does not use PathPrefix. T76 tests
the exact route, priority and strip-only chain, while `/joe/inbox/results/`
and `/joe/inbox/resultsx` still require SSO, including anonymous/spoofed live
GET/HEAD/POST probes. Non-POST requests at the exact path also require SSO.
This infrastructure proposal does not claim an ingress
implementation or producer/results sign-off in the pinned candidate.
