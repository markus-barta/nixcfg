# joe-board-pusher (hsb0)

Read-only paper IB client (`clientId` 50 → `100.64.0.6:4002`) projecting
`inspr.joe.household.v1` and POSTing to `https://cs0.barta.cm/joe/inbox` every
`JOE_PUSH_INTERVAL_SEC` (default 30).

Never connects to live 4001. Never places orders. Uses shared agenix push token.

Stage-0 money excludes grandfathered paper SXR8 lot + leftover TSLA×1 (CONFIG.md) from
since-start / stand / totals; action/learning still name open legacy holdings.

## Position rows

Per-desk `positions[]` is emitted only after a completed, account-matched IB
`reqPositions` subscription (`position` … `positionEnd`). Missing key means
unavailable; `[]` means complete known-empty coverage. Disconnect/reconnect
invalidates coverage until the next completed subscription.

Symbol mapping: `INTC` → `j`, `SXR8`/`TSLA` → `joel`. Unknown symbols are never
mapped to Joe. Broker observation times come from IB events, not the push heartbeat.
Monetary fields (`mark`, `marketValue`, `openPnl`) are omitted unless contract
currency is proven `EUR`. `dayPnl` stays `null` until a real day feed exists.

Run synthetic replay tests: `npm test` (fixtures are labelled synthetic, not live).

## Consumer schema disagreements (HOSTD-32)

`/joe/data.schema.json` still has `additionalProperties: false` on `position` and
does not yet declare the frozen Wave-D extensions `position.currency` or
`position.accountingScope`. This producer therefore omits those fields rather than
emitting silent extras. Legacy grandfather rows remain visible on the Joel desk;
Stage-0 money exclusion is unchanged in desk `money` totals.
