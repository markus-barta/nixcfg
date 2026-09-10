# joe-board-pusher (hsb0)

Read-only paper IB client (`clientId` 92 → `100.64.0.6:4002`) projecting
`inspr.joe.household.v1` and POSTing to `https://cs0.barta.cm/joe/inbox` every
`JOE_PUSH_INTERVAL_SEC` (default 30).

Never connects to live 4001. Never places orders. Uses shared agenix push token.

Stage-0 money excludes grandfathered paper SXR8 lot + leftover TSLA×1 (CONFIG.md) from
since-start / stand / totals; action/learning still name open legacy holdings.

The J desk is calculated as one economic family (J + J2–J5) from exact-date,
account-scoped execution history returned by the long-lived official Python IB API
helper (`clientId` 94). Node (`clientId` 92) remains the sole owner of account,
position, FX, inbox, and durable-state work.
The verified period starts at 2026-09-10 00:00 America/New_York; earlier results
remain unavailable. Current explicit broker FX rates convert quote-currency FIFO
PnL and fees to EUR. The active v2 ledger lives at
`/var/lib/joe-board-pusher/family-ledger-v2.json` and is replaced atomically. The
original `/var/lib/joe-board-pusher/family-ledger.json` stays byte-for-byte immutable
as the v1 migration backup; activation records its SHA-256 and requires an official
overlap whose calculation matches v1 with the same book and FX. A durable activation
marker prevents a missing v2 file from silently restarting migration.

Coverage advances only after every requested New York date is returned in one
recovery session. A midnight, helper restart, server change, or gap longer than 24
hours requires replay of a known execution anchor at or before the prior watermark,
with every later identity (or higher correction) and every family fee preserved.
An anchored empty current day is valid. An unanchored historical response, vanished
identity, changed v1 backup, or assumed retention window fails closed.
Each IPC cycle is capped at seven exact dates to match the helper request bound;
that cap is not a claim that the Gateway retains seven days of history.

FX comes only from Node's existing account-update stream. Initial rates become
usable at `accountDownloadEnd`; later explicit `ExchangeRate` callbacks refresh
them. An unchanged cached value or publisher heartbeat cannot refresh a rate.

J accounting fails closed while an execution cycle is incomplete, a family fill
lacks its commission, FX is stale, position coverage is incomplete, state is missing
after the authorized bootstrap date, persisted state is corrupt, the helper protocol
mismatches, or execution-history coverage regresses. In those cases household
POSTs continue with J money set to
`null` and J positions omitted; Joe and Joel continue from the valid broker book,
and aggregate money is `null` rather than a misleading partial sum. Disconnects
require a fresh anchored helper session and fresh FX before J resumes. Position
reconciliation alone never proves execution completeness.

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
