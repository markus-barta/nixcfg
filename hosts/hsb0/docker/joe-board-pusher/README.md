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
callbacks remain unable to extend a separate absolute five-minute deadline measured
from the first loss notice. If no restoration notice arrives, that deadline retires
the generation through the same capped retry supervisor even when informational or
dropped financial callbacks keep arriving. Otherwise, an idle socket must answer a
non-financial current-time probe. Shutdown cancels every connection, snapshot,
upstream-loss, health, and retry timer.

Stage-0 money excludes grandfathered paper SXR8 lot + leftover TSLA×1 (CONFIG.md) from
since-start / stand / totals; action/learning still name open legacy holdings.

The J desk is calculated as one economic family (J + J2–J5) from recurring,
account-scoped `reqExecutions` and matching actual `commissionReport` callbacks.
The verified period starts at 2026-09-10 00:00 America/New_York; earlier results
remain unavailable. Current explicit broker FX rates convert quote-currency FIFO
PnL and fees to EUR. The durable raw ledger lives at
`/var/lib/joe-board-pusher/family-ledger.json` and is replaced atomically.
Its state binds the account, verified period, family-client classifier, excluded
symbols, last completed capture, and New York coverage day. The legacy client-92
request remains the continuous current-day/account-scoped capture. At a New York
midnight the runtime accepts a fresh current-day replay but marks the prior boundary
as requiring authoritative history instead of permanently latching ingestion shut.
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

J full accounting fails closed while an execution cycle is incomplete, a family fill
lacks its commission, FX is stale, position coverage is incomplete, state is missing
after the authorized bootstrap date, persisted state is corrupt, or execution-query
coverage regresses. An unproved prior-day boundary returns a distinct optional
`partialAccounting` estimate when current positions, marks, actual fees, and FX are
otherwise valid; it never turns that estimate into full J equity. Invalid current
economics remain unavailable. Household POSTs continue; Joe and Joel continue from
the valid broker book, and aggregate money remains `null` rather than a misleading
partial sum until the producer receives validated complete history.

The optional producer contract for that degraded state is:

```js
{
  ok: false,
  reason: "authoritative execution coverage across midnight is incomplete",
  partialAccounting: {
    status: "CAPTURED_ESTIMATE",
    currency: "EUR",
    equity: null,
    capturedTotalPnl: Number,
    capturedRealizedPnl: Number,
    estimatedOpenPnl: Number,
    dayPnl: null,
    positions: [{ accountingScope: "captured-estimate", /* normal J row */ }],
    accounting: {
      method: "execution-fifo-net-current-fx",
      completeness: "partial",
      fxBasis: "current-observed",
      detail: String,
    },
    coverage: { status: "partial", gaps: [{ fromInclusive, toExclusive, reason }] },
    observedAt: String,
    executionCount: Number,
  },
}
```

This is J-family FIFO net of actual fees, marked and converted with freshly observed
current FX. It is neither complete J equity nor a Day P&L; both stay null. When the
fixed baseline through the prior New York midnight is covered continuously by
validated official receipts, the existing full `family` result is accepted by the
normal money path with its €5,000 virtual capital exactly once. Its accepted
`unrealizedPnl` is exposed as `J.money.openPnl`; a verified flat book therefore
publishes `openPnl: 0`. Day P&L remains null without a separate truthful day basis.

## BEST-AVAILABLE history sidecar

`execution-history.mjs`, `family-history.mjs`, and
`execution-reconciliation.mjs` provide the independent, read-only import path
for authoritative paper-API and preserved-ledger captures.
They never rewrite `family-ledger.json` or a source artifact. The sidecar store is
atomic, restart-safe, and account/classifier-bound. Capture receipts remain
immutable, while redundant official COMPLETE receipts are retained once per
New York date/covered interval: a newer immutable receipt may replace an older one
only when it fully covers the old interval and its execution and fee ID
sets are supersets. Receipts from another authority, partial or non-subsumed proofs,
older receipts without ID memberships, and all durable economic rows are retained.
Exact duplicate captures are idempotent, conflicting identities fail closed, and
all IB correction revisions remain durable while only the highest revision is
effective. Commission reports without a captured execution remain explicit orphan
fees rather than being discarded.

The concrete adapters accept the existing `family-ledger.json` shape and an
official `probe-evidence.json` request. They normalize only representation: named
IANA-zone timestamps become the same UTC instant, numeric shares become numbers,
stock multipliers become one, sides become BUY/SELL, and `commission` plus
`commissionAndFees` become one fee field. SDK/callback-only metadata is retained in
the private receipt provenance but is excluded from economic conflict checks.
An official commission may enrich an older fee with broker `realizedPNL`; a changed
execution price, quantity, side, contract, currency, fee, or already-known realized
PnL remains a hard conflict.

Every capture declares an exact half-open target interval and either `known` or
`complete` coverage. A successful legacy API end callback is still `known`. The one
complete provider is the official `ibapi` execution-window adapter: it requires the
pinned SDK identity, negotiated protobuf filter capability, paper port/client 94,
the managed target account, an exact account/time/specific-date filter and planned
New York window for every request, clean end callbacks, no request error/timeout,
`pendingPriceRevision === false` on every raw execution, and one actual commission
record for every returned execution. Its end is conservatively bounded by the
request start. A clean empty current-day response is a complete receipt for that
exact bounded interval, not evidence beyond it. Coverage
gaps are calculated as exact intervals not covered by such receipts. They keep full
J equity unavailable but do not stop the asynchronous capture loop; transient
capture, validation, and save failures remain retryable. Corrupt persisted sidecar
state alone is a fatal load error because overwriting it could erase evidence.

`projectBestAvailableHistory()` returns `status`, nullable full `equity`, a separate
`capturedSubtotal`, exact `coverage`, conservative `missingOpeningLots`, orphan fee
IDs, the latest verified complete period, and all capture receipt IDs. The subtotal
is computed internally, never accepted from a caller: effective J-family executions
and their actual fees are paired FIFO for captured roundtrips. Broker
`commissionReport.realizedPNL` is account-book supplementary evidence and is never
used as J-family money because another desk's same-symbol lots can affect its cost
basis. It may only provide a conservative clue that a captured close lacks an
opening lot. Results stay in their native currency—there is no implicit historical
FX conversion. An opening-lot gap is
reported only when a broker-realized close exceeds captured opposing quantity, not
merely because a first captured execution is a buy. Full equity requires gap-free
coverage plus a complete-accounting result bound to the same history digest.
Journals may establish the client-family classifier, but never supply an execution
price, fee, currency, FX rate, fill time, or completeness assertion.

`capturedSubtotal.points` is the partial captured-realized history, with the exact
contract `[{ at, realizedPnl }]`: `at` is an actual normalized execution timestamp
and `realizedPnl` is the cumulative result in `capturedSubtotal.currency`. Equal
timestamps are aggregated, opening-only executions add no point, and there is no
synthetic zero anchor or FX-derived point. The points are strictly chronological,
contain no account or execution IDs, and the final value equals the subtotal. A
mixed-currency or incomplete-fee result exposes no single curve. At most the last
2,048 actual timestamp points are returned; `pointsTruncated: true` says older
points were omitted while their realized result remains included in every retained
cumulative value. This curve is BEST-AVAILABLE captured evidence, never complete
EUR desk equity and never a replacement for preserved history.

Previewing is read-only; importing writes only the private atomic sidecar. Legacy
ledger and old generic-probe imports are always `known`. Only a fully validated
official-window artifact can produce `complete` receipts:

```sh
node family-history-cli.mjs preview \
  --source-type official-probe --source /absolute/path/probe-evidence.json \
  --request 9310 --state /var/lib/joe-board-pusher/family-history.json \
  --from 2026-09-10T04:00:00Z --to 2026-09-11T04:00:00Z

node family-history-cli.mjs import \
  --source-type family-ledger \
  --source /var/lib/joe-board-pusher/family-ledger.json \
  --state /var/lib/joe-board-pusher/family-history.json \
  --from 2026-09-10T04:00:00Z --to 2026-09-11T04:00:00Z

node family-history-cli.mjs import \
  --source-type official-probe --source /absolute/path/probe-evidence.json \
  --request 9310 --state /var/lib/joe-board-pusher/family-history.json \
  --from 2026-09-10T04:00:00Z --to 2026-09-11T04:00:00Z

node family-history-cli.mjs preview \
  --source-type official-window --source /absolute/path/official-window.json \
  --account "$JOE_PAPER_ACCOUNT" \
  --state /var/lib/joe-board-pusher/family-history.json \
  --from 2026-09-10T04:00:00Z --to 2026-09-11T09:00:00Z

node family-history-cli.mjs import \
  --source-type official-window --source /absolute/path/official-window.json \
  --account "$JOE_PAPER_ACCOUNT" \
  --state /var/lib/joe-board-pusher/family-history.json \
  --from 2026-09-10T04:00:00Z --to 2026-09-11T09:00:00Z
```

The production pusher uses `createFamilyHistorySessionAdapter()` with
`createFileFamilyHistoryStore()` on its existing broker session. It seeds an
absent sidecar once from the validated legacy ledger. Broker capture timeouts
retry with bounded backoff; identity, reconciliation, and persistence failures
fail closed until restart, preserving the saved sidecar. The broker book can
still be published when family history is unavailable.

In parallel, `createOfficialHistoryRefresher()` calls
`readOfficialExecutionWindow({ fromInclusive, toExclusive, targetAccount, host,
port, clientId: 94, signal })` at startup, every 15 minutes, and at the New York
day rollover. It starts at the earliest durable gap still recoverable inside the
official seven-New-York-date limit; once caught up it retains a prior/current-day
overlap. Older unqueryable gaps remain explicit. It runs only one bounded subprocess
at a time and retries failures with capped backoff. Each
successful batch is normalized with `capturesFromOfficialWindowEvidence()` and
passed to `familyHistoryAdapter.importCaptures(captures, { fromInclusive:
FAMILY_BASELINE_PERIOD_START, toExclusive })`. Reconciliation and the sidecar save
complete synchronously and atomically; a reader, validation, or save failure leaves
the prior complete intervals untouched and never stalls the main publisher.

Before full projection, the runtime imports only execution and fee identities named
by those validated official receipts into the durable family ledger. Representation-
only SDK differences normalize before comparison, new correction revisions remain
raw durable evidence, and immutable execution/fee or already-known realized-P&L
conflicts fail closed without replacing the ledger. This makes recovered closed
roundtrips part of the same FIFO calculation instead of treating a flat current book
as proof that none were missed.

Official `specificDates` is limited to the past week. If an installation has no
validated receipt for an older gap, retained ledger rows do not prove it complete;
the runtime remains on the labelled partial contract until reviewed authoritative
evidence covers that exact gap.

`createFamilyHistoryIngestor()` is a separate generic helper, not the production
session adapter. Its `fetchCapture` hook returns `{ capture, target }` and its
capture failures remain retryable.

Cold-start wiring may seed an absent sidecar from the existing ledger exactly once,
without changing that ledger:

```js
import { captureFromFamilyLedgerFile } from "./execution-history.mjs";
import { reconcileExecutionCapture } from "./execution-reconciliation.mjs";
import { createFileFamilyHistoryStore } from "./family-history.mjs";

const store = createFileFamilyHistoryStore(historyPath);
const loaded = store.load();
if (!loaded.ok) throw new Error(loaded.reason);
if (loaded.state === null) {
  const capture = captureFromFamilyLedgerFile({
    filePath: ledgerPath,
    window: target,
  });
  store.save(reconcileExecutionCapture({ capture, target }));
}
```

Here `historyPath` is the absolute `family-history.json` sidecar path, `ledgerPath`
is the absolute existing `family-ledger.json` path, and `target` is the explicit
half-open recovery interval. Subsequent ingestion must pass the loaded sidecar as
`prior`; an exact replay is idempotent and a coverage gap never latches polling
closed. The default read classifier is exactly client IDs
`27,28,29,50,51,52,53,54,55,56`; inclusion of read client 56 preserves the proven
production classifier and grants no order authority.

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
