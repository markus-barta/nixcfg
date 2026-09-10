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

Symbol mapping: `INTC` → `j`, `SXR8`/`TSLA` → `joel`. Joe has no symbol mapping,
so its desk never receives a `positions` key. Unknown symbols are never mapped to
Joe. Broker observation times come from IB events, not the push heartbeat.
Rows emit `currency` (uppercase contract currency when known) and
`accountingScope` (`legacy` for grandfathered names, `stage0` otherwise).
`mark` is emitted with a known quote currency; `marketValue`/`openPnl` stay absent
until callback currency semantics are verified (EUR alone is not sufficient).
`dayPnl` stays `null` until a real day feed exists.

Run synthetic replay tests: `npm test` (fixtures are labelled synthetic, not live).
