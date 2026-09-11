# joe-board-pusher (hsb0)

Read-only paper IB client (`clientId` 92 → `100.64.0.6:4002`) projecting
`inspr.joe.household.v1` and POSTing to `https://cs0.barta.cm/joe/inbox` every
`JOE_PUSH_INTERVAL_SEC` (default 30).

Never connects to live 4001. Never places orders. Uses shared agenix push token.

## Broker recovery

The SDK `connected` event proves the local TCP/API handshake with IB Gateway; it
does not prove that Gateway is connected to IBKR upstream. Codes 1100 and 2110
therefore mark the published broker state unavailable while retaining that local
socket so Gateway's automatic restoration can be observed. The accepted book,
its economic timestamp, and its last-good gateway observation are retained
unchanged. Financial callbacks received during the outage cannot refresh them.

The first 1101 or 1102 after an observed loss retires that adapter generation
and schedules one fresh local API connection through the common retry policy.
This generation boundary is required because `position`, `updatePortfolio`, and
`accountDownloadEnd` callbacks are not request-scoped: no callback from the old
socket can complete the fresh snapshot. Repeated restoration notices on the old
generation are ignored, and restoration notices on a new connection without a
preceding observed loss do not start another reconnect cycle. The new generation
must pass the existing managed-account, positions, account-summary, and
account-download completion gates before the book becomes available again.
J-family polling, execution readiness, and FX are suspended at upstream loss and
require a fresh complete replay after restoration; the durable ledger and its
identity/coverage checks remain unchanged.

Restoration and actual local socket failures share the same replacement policy. All replacements use
one deduplicating exponential retry schedule (5 seconds to 5 minutes, with 20%
jitter). A TCP connection alone does not reset the backoff; an accepted complete
broker snapshot does. Connection attempts have a 15-second deadline. A local socket can be responsive
without providing a usable book, so every new
generation also has a separate 60-second complete-snapshot deadline. Health,
informational, and partial callbacks cannot extend it; only an accepted complete
book clears it. A declared upstream outage pauses that deadline while real inbound
notices extend a bounded five-minute socket-silence deadline without pretending
the financial book is fresh. Otherwise, an idle socket must answer a non-financial
current-time probe. Shutdown cancels every connection, snapshot, health, and retry
timer.

Stage-0 money excludes grandfathered paper SXR8 lot + leftover TSLA×1 (CONFIG.md) from
since-start / stand / totals; action/learning still name open legacy holdings.

The J desk is calculated as one economic family (J + J2–J5) from recurring,
account-scoped `reqExecutions` and matching actual `commissionReport` callbacks.
The verified period starts at 2026-09-10 00:00 America/New_York; earlier results
remain unavailable. Current explicit broker FX rates convert quote-currency FIFO
PnL and fees to EUR. The durable raw ledger lives at
`/var/lib/joe-board-pusher/family-ledger.json` and is replaced atomically.
Its state binds the account, verified period, family-client classifier, excluded
symbols, last completed capture, and New York coverage day. Because the current
execution request cannot prove a missed net-zero roundtrip across a New York
midnight, the publisher conservatively requires verified backfill at that boundary;
same-day restarts recover through a complete current-day capture.
Within a coverage day, every complete execution query must retain every identity
from the preceding successful query (or provide its higher IB correction revision).
A query that temporarily omits an identity is unavailable and retried with capped
backoff; it cannot change the persisted ledger, identity set, or coverage watermark.
Only a later complete replay containing every prior identity prefix (or a higher
revision), actual required fees, an exact merge, and a successful state save restores
J readiness. Persisted rows are never unioned into incoming evidence. This retry
policy does not prove or repair a real retention gap: authoritative missing-history
evidence and every unproved cross-day gap still require the separate backfill work.

FX uses a separately scoped `reqAccountUpdatesMulti` request. Before the five-minute
freshness window expires, the adapter cancels that request and opens a new request
ID. Only an explicit callback for the current connection and request refreshes a
rate; an unchanged cached value or publisher heartbeat cannot refresh it.

J accounting fails closed while an execution cycle is incomplete, a family fill
lacks its commission, FX is stale, position coverage is incomplete, state is missing
after the authorized bootstrap date, persisted state is corrupt, or execution-query
coverage regresses. In those cases household POSTs continue with J money set to
`null` and J positions omitted; Joe and Joel continue from the valid broker book,
and aggregate money is `null` rather than a misleading partial sum. Disconnects
require fresh executions and FX before J resumes, and any unproved New York day
boundary requires backfill rather than position-only inference.

## Position rows

Per-desk `positions[]` is emitted only after a completed, account-matched IB
`reqPositions` subscription (`position` … `positionEnd`) recognizes the target
managed account and the account/summary downloads also complete. Missing key
means unavailable; `[]` means complete known-empty coverage. Disconnect,
reconnect, or an invalid broker quantity invalidates coverage until a clean
resynchronization.

Legacy symbol mapping remains only for the disabled pre-ledger projection path.
At runtime, J positions come exclusively from the accepted family ledger rather
than projecting every account-level `INTC` row into J. `SXR8`/`TSLA` → `joel`.
Joe has no symbol mapping,
so its desk never receives a `positions` key. Unknown symbols are never mapped to
Joe. Broker observation times come from IB events, not the push heartbeat.
Rows emit `currency` (uppercase contract currency when known) and
`accountingScope` (`legacy` for grandfathered names, `stage0` otherwise).
`mark` is emitted with a known quote currency; `marketValue`/`openPnl` stay absent
until callback currency semantics are verified (EUR alone is not sufficient).
`dayPnl` stays `null` until a real day feed exists. Push heartbeats never advance
the broker snapshot timestamp; before the first complete broker snapshot the
publisher skips the push rather than fabricating an empty book.

Run synthetic replay tests: `npm test` (fixtures are labelled synthetic, not live).
