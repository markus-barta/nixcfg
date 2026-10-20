# joe-board-pusher (hsb0)

Read-only paper IB client (`clientId` 92 → `100.64.0.6:4002`) projecting
`inspr.joe.household.v1` and POSTing to `https://cs0.barta.cm/joe/inbox` every
`JOE_PUSH_INTERVAL_SEC` (default 30).

Never connects to live 4001. Never places orders. Uses shared agenix push token.

The pusher and official Node/Python reader require `IB_DESK_ACCOUNT` from the
root-owned agenix env file `hsb0-ib-desk-env`, injected through Compose `env_file`.
Missing or malformed paper-account configuration fails closed. Identity values
live in the private PPM runbook `host-hsb0`; no public default or fingerprint
is shipped.

The switch-set image is `hsb0-joe-board-pusher:household-v2-switch-set-r14-202610201330` (pusher, stager and executor runtime; OPS-392). Rollback tag: `hsb0-joe-board-pusher:household-v2-switch-set-202610201110`.
The pusher, isolated stager and executor runtime use that same immutable image;
the executor source remains on its existing mount. `pull_policy = "never"`
prevents an automatic rebuild or pull. Build this new tag during the separately
reviewed host promotion; keep `flat-net-reconcile-perf-202610010310` intact for
rollback. Never rebuild over either published tag. The base image digests,
package manifests and `npm ci` remain unchanged.

## household.v2 switch-set staging (OPS-392)

The existing `joeHouseholdV2StageEnabled` flag enables the independent
`joe-household-v2-stage` service in the Phase A candidate. The Results producer
remains disabled (`nixcfg.joeResultsProducer.enable = false`). This build
adds useful account and position evidence to local staging; it adds no v2 POST
selector. PAPER only; live remains locked. All v1 accounting, subscriptions,
token source, POST bytes and interval remain unchanged. Desk money and totals
stay null with `not_exact_yet`. Desk activity uses the existing read-only broker
replies; no executor API request or executor change is added. Historical evidence
and accounting remain omitted.

The pusher constructs its optional Unix client once at startup and reconnects
from `setImmediate` after close. Only `/run/joe-household-v2/stage.sock` is accepted.
After the v1 fetch/response settles (including rejection), the client may copy
already available source scalars and identities. An idle worker issues one
`0x01` credit. A frame is uint32-be byte length followed by UTF-8 JSON, at most
**16384 payload bytes** (16388 including the prefix):

```text
{format:"ops392.switch-set-observation.v2", bookTs,
 equity:{value,currency}|null, cash:{value,currency}|null,
 apiReplyCheckedAt:string|null, positions:[{symbol,side,desk,scope}],
 deskActivity:{j,joe,joel}}
```

There are at most 256 broker identities before encoding; oversize observations
are dropped whole and keep the unused credit. Busy/disconnected/backpressured
opportunities are dropped. There is no ledger traversal in the handoff, contract import,
fsync, awaiting the worker, second POST or queued retry in the pusher.

NAV (`NetLiquidation`) and cash (`TotalCashValue`) retain raw account-summary
strings and currencies, including scale, negative signs and signed zero. Only
valid EUR decimal lexemes pass through; missing, non-EUR or unrepresentable
values become null with `source_unavailable`. Rev 8 uses `brokerAccount.reason`
for equity and `brokerAccount.reasons.cash` for cash. Both cover the entire paper
account including KEEP; no conversion or numeric FIFO value enters them.

Gateway readiness requires a completed account-matched account-summary or
positions API reply. TCP, account download, login and currentTime activity are
insufficient. `checkedAt` is that callback's local receipt instant. Both its age
at source generation and at staging receipt must be nonnegative and under 60s.
Old, future and stale replies are not ready; account money is then withheld.
With no completed reply, omit gateway rather than fabricate a timestamp.
The worker mirrors the board's post-acceptance checkedAt regression gate and
fsyncs its nonfuture high-water before publishing; equal checks are accepted.
Future replies never advance this durable watermark. A check ahead of receipt
but within a skewed generation skips the whole pair to avoid disagreeing with
the board's generatedAt-relative watermark. Gateway readiness still requires a
completed positions or account-summary reply; the read-only order refresh below
does not renew it. Readiness expires when no qualifying reply renews it.

SXR8 and TSLA always appear with `scope:keep`, `desk:null`. Missing KEEP rows use
`side:long` from the existing long-only KEEP policy and `source_unavailable` for
every valuation field. Reported rows preserve side; all five values remain null
with `not_exact_yet`. Other broker rows copy ownership from the already computed
dated desk/family projection, including its existing partial J projection when
available. A split or ambiguous identity has no guessed desk. The legacy symbol
map is not used. Unmapped stage0 rows retain `desk:null` and
`reasons.desk:desk_unmapped`; rev 9 accepts these observations and the worker
stages the complete pair with all five valuation fields null and individually
reasoned `not_exact_yet`. KEEP and mapped stage0 rows carry no desk reason.

Desk rows use exactly `desks[].state` from [rev 9 data.schema.json](./contracts/data.schema.json):
`stuck` if a position, order or execution reader is unavailable, has unknown
ownership, or its observation is older than the existing five-minute pusher
bound (future evidence also fails closed); otherwise `working` if that desk has
positions, active open orders or executions on the executor's current New York
day, and `sit-out` if empty. Read-only `reqAllOpenOrders` runs on connect and
every 60 seconds, checked by the existing 5-second maintenance tick, with at
most one reply in flight. Each reply collects a fresh set keyed by
`(orderId, clientId)`; `openOrderEnd` atomically replaces the previous set,
including an empty set, and stamps its generation-scoped completion clock.
While a reply is in flight the last completed set and clock remain unchanged;
a missing end marker blocks overlapping requests and the old clock expires
after five minutes, yielding `stuck`. Unsolicited callbacks, publication and
cached executor order rows cannot renew this clock. A new connection generation
discards any pending reply. Execution evidence is summarized when the family
reader completes its existing read-only `reqExecutions` cycle, scheduled 30
seconds after each completion (20-second request timeout, existing retry backoff).
Identical completed replays renew execution observation time without restamping
unchanged money; missing `execDetailsEnd` cannot prove absence. Both use the same dated client ownership policy as
the desk projection; unclaimed clients are unavailable rather than guessed from
an order reference. Reader errors/disconnects invalidate evidence. The execution
summary must cover the current NY day, including weekends; midnight needs a new
completed reply. The mirrored `newYorkDay` function is tested against executor
`brakeUsage` around both midnight offsets and DST changes. The optional summary runs only with staging enabled and its failures cannot
change v1 reader availability. `desks[].action` says "Valuation is not exact yet."; all desk money
stays null with individual `not_exact_yet` reasons. KEEP rows are unaffected.

After v1 settlement, the pusher emits `v2_desk_state` on each desk's first
observation and whenever its state or cause changes, independently of stager
credit. Events contain only `event`, `desk`, `state`, `cause`, and optionally
a numeric `client` for an unowned execution. Healthy states use `cause:null`.
Unavailable or stale positions/orders/executions, execution day mismatch,
unowned executions and executions after coverage have distinct closed causes.
When several readers fail, positions take precedence, then orders, then
executions; all-desk equity failures map to `positions_unavailable` unless
J still has its existing valid family evidence. Execution failure causes cross
only the private OPS observation frame; rev 9 desk rows gain no fields.

No desk subtotal is presented as a household total. The producer also requires
individual null reasons where the ready-session schema permits omission.

The service has no networking, credentials or broker mounts, a separate 128m
memory/swap limit, 0.25 CPU and 32 processes. It runs as 1000:1000 with a read-only
root, no capabilities and no-new-privileges. Only the private v2 state and IPC
directories are writable. The supervisor discards child stdout/stderr, enforces
a five-second startup/job watchdog, kills the actual `flock --no-fork` worker,
and restarts with 1/2/4/8/16/30-second bounded backoff. Its logs contain only
closed, value-free control events.

Host tmpfiles create `/var/lib/joe-board-pusher/v2` and
`/run/joe-household-v2` as 0700, owned by 1000:1000; files/socket are 0600.
**Enrollment is explicit and one-shot**, after the operator's recorded empty
staged/accepted history. In the isolated service context, run
`node v2-stage-worker.mjs --enroll` with those same two mounts and user. It takes
the lifetime allocator lock, requires absent state and pairs, and persists
`format:"ops392.v2-sequence-state.v1"`, immutable `floor: 0`, and high water 0.
The supervisor never enrolls. An absent or corrupt state fails closed; do not
reset it to recover service. The first reserved sequence is 1. Other hosts or
reenrollment need a separate operator floor record and reviewed procedure.

The worker verifies the exact 17-file revision-9 closure before importing any
contracts. Source time is calendar-validated UTC from `book.ts`; missing or
regressing time suppresses staging. Repeated observations retain generation
and local generation-progress time. Each sequence is fsynced, renamed and
parent-directory-fsynced before use; crashes may burn numbers, never reuse them.
The stable `.allocator.lock` inode is never replaced. A second writer cannot
acquire it. The observation identity is `["ops392.switch-set.v2",bookTs]`;
legacy Phase A reservation identities with a null gateway watermark remain
readable. Older contract-set staged pairs fail closed and require coordinator
review before promotion; never reset enrollment or sequence state to migrate.

Readers follow only `current.json` to an immutable `pair-<seq>` directory.
`snapshot.json` holds exact validated ingress bytes without `receivedAt`;
`receipt.json` records the real local staging receipt, sequence/generation,
`generatedAdvancedAt`, snapshot SHA256 and contract-set SHA256. Receipt is not
proof of live board acceptance. Pair files and directory become durable before
the pointer's own atomic replacement. `RETAIN_PAIRS` defaults to **10**; the
`StageStore.retainPairs` constant override permits 10–1024. Keep the newest N
pairs by sequence count only, never age; the current pointer is protected.
Recovery validates retained and orphan pairs before pruning. Pruning atomically
renames an old pair to a recognized `.retired-<seq>` tombstone so interrupted
cleanup remains recoverable. `receipts.jsonl` is a separate fsynced append-only
0600 log with one record per staged/resolved sequence: `seq`, outcome
(`committed`, `rejected`, or recovered `staged`), source/staging/record timestamps,
and `pairSha256` (the snapshot byte hash from the pair receipt), plus its format.
It contains no payload values and outlives pair pruning; restart never appends a
duplicate. A crash can burn an unbuilt reservation without a staged pair/record.
A durable orphan is recorded as `staged`; the pointed-to pair is `committed`,
meaning local pointer publication only. The supervisor emits exactly
`{event:"v2_stage_committed",seq}` for a completed commit. Unknown files, wrong
ownership/modes, inconsistent sequences/digests or torn log lines disable staging
and preserve evidence. v1 state is untouched.

For rollback, set `joeHouseholdV2StageEnabled = false` through the normal
reviewed configuration workflow. The service, socket env/mount and updater
exclusion disappear; matching pusher/executor pins return to the previous image.
Keep durable v2 state/pairs intact. The flag-off Nix evaluation compares the
entire serialized pusher declaration to the baseline, using the same inert
build-context path in both evaluations (the real source-store hash necessarily
changes with source content).

Run `node --test` for all pusher tests. New tests cover exact baseline v1 bytes,
fetch/body rejection identity, skips, the credit/frame protocol, real child
death at persistence boundaries, contract acceptance/replay/clocks, corruption,
ENOSPC/fsync failure, source-filter closure and flag rendering. Fixtures are
synthetic/masked. The pinned verifier checks every closure file against its
independent hash/size manifest; offline handoff evidence also compares the
17 files directly against JoeDesk 84c47b647cf06a38a3f61ce7f928a10ed10eeef3
(set 000045fb7843a16be95f6a7e42d46d4b4ecb34b0efd39fc987bee444817fc9d5). The pusher-local
verifier exports a fixed-path `verify()`; `node verify-contracts-entry.mjs`
is the unconditional Docker build entry. It is tested on valid and damaged rev 9 closures. Linux
flock and memory-cgroup/OOM checks require Linux; the macOS offline run reports
those separately and does not claim container isolation has been live-verified.

### Linux isolation rehearsal

On a workstation with Docker/Colima, Nix (`<nixpkgs/lib>`), Node 22.23+ and
`trash` available, run from the repository root:

```sh
node scripts/rehearse-household-v2-stage.mjs
```

This builds a unique local image from the actual Nix-filtered source. It refuses
fleet workstation/engine names and non-Unix Docker endpoints, pins the checked
endpoint, and proves the daemon can see a unique local marker. It creates only
unique lab containers and volumes; it never opens credentials, a real account
or a broker. The pusher imports its real code and projection with synthetic
broker/token boundaries and a loopback stub inbox; its original 30-second
interval and v1 fetch block execute unchanged. The stager keeps the actual
Compose memory/swap/CPU/PID limits, network isolation and security settings.
A read-only lab mount injects OOM and hang faults into the lock-holding worker's
fsync; runtime code and the filtered image contain no fault hook. A one-shot
root initializer grants CHOWN solely to initialize fresh lab volumes; both
runtime services use the image's uid 1000.

The rehearsal checks distinct memory-cgroup inodes, the 128m limit, kernel OOM
evidence, watchdog recovery from a blocked job, forced worker death, continuing
identical v1 POST bytes/cadence, an unchanged pusher boot identity and a valid
new staged pair after each fault. Pair inspection is read-only. It removes only
its own Compose project, volumes, image and temporary directory. A final
`{"result":"ok",...}` is the runtime verdict; failure is nonzero. Allow roughly
four minutes plus image build time. CI runs `node --test` on Ubuntu/Node 22,
including real flock; this longer Docker rehearsal remains a workstation gate.

## Board health

Every complete household snapshot includes the optional consumer-compatible
pair `boardHealth` (`green`, `yellow`, or `red`) and `shortReason`. The current
reason codes are `board_ok`, `snapshot_stale`, `retained_values`,
`gateway_degraded`, `gateway_down`, `equity_unavailable`, `producer_stuck`,
`day_pending`, `open_unavailable_rth`, and `halt_on`. The old
`day_unavailable_rth` remains readable by compatible consumers but is no longer emitted.

Health is derived from the projected snapshot's source observations, never the
publisher heartbeat. Gateway loss, unavailable all-desk equity, a stuck
producer without usable equity, a structural ledger failure, or an active halt
is red. Retained or stale usable values, and missing DAY or OPEN during weekday
09:30–16:00 America/New_York, are yellow. Outside that window, unavailable
DAY and OPEN remain honest N/A and do not make a fresh board red.

A temporarily incomplete J-family calculation retains the last verified full
virtual-desk equity vector, including its household total and original oldest
input timestamp. Joe and Joel values are not erased by a J callback gap. This
is a carried valuation, never a fresh calculation; current DAY/OPEN gates and
the saved SOD reference are unchanged. The existing durable DAY store supplies
the retained vector across restarts. With no verified vector at all, the board
stays red rather than inventing a grace-period timestamp. Structural ledger
errors remain red even if retained money is displayed. Calculator diagnostics
name the actual missing input instead of the generic incomplete-family error.

## Portfolio freshness (HOSTD-64)

The account portfolio subscription is change-driven. A connected Gateway and
fresh execution/summary callbacks therefore do not prove fresh per-position
marks. An independent five-second check requests a same-session account download
when an active non-KEEP position has a missing mark or its actual finite-price
callback is four minutes old. It cancels and resubscribes this client's existing
account subscription; it does not reconnect, replace the execution generation,
place orders, or change any DAY/OPEN freshness limit or saved SOD reference.
Only broker `updatePortfolio` callbacks advance mark ages. Requests, completion
notices and publisher ticks never do so. A failed refresh retains the current
honest stale/carry behavior.

One refresh may be outstanding. Missing mark callbacks time out after 30 seconds;
retries back off from one minute to 15 minutes. Account subscription notices
are logged. IB code 2100 during our own cancel/resubscribe keeps the original
30-second deadline and requires new finite-price callbacks after the notice.
Without those callbacks, or on a subscription rejection (2101), another attempt
is deferred for 15 minutes instead of starting a subscription fight. Closed positions and KEEP SXR8/TSLA do not trigger refresh.
Outside trading hours an unchanged broker mark remains an observation of the
broker valuation, not a claim of a new trade. Logs distinguish requested,
recovered and deferred refreshes without dumping account or position data.

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
A later full legacy replay restores readiness. Alternatively, the existing official
client-94 reader supplies a continuous chain of COMPLETE dated receipts containing
every retained query identity (or higher correction), every current replay identity,
and actual matching fees. HOSTD-69 preserves the proven prefix when Gateway's
retention resets before New York midnight and queries the uncovered tail, rounded
down to whole seconds for overlap. It does not require the broker to resend old
fills that already have complete durable receipts. A wide empty receipt that omits
known fills in its interval cannot advance this chain; old receipts and all economic
rows remain untouched. No union of unproved ledger rows can establish coverage.
Missing intervals, missing fees, conflicting economics, higher known corrections
not present in receipts, future timestamps and stale tail evidence fail closed.
Only the newest proven tail watermark advances execution coverage; publication
and replay timestamps never refresh it. Query logs distinguish receipt count from
execution count and include the requested interval. Reader failures expose bounded
numeric broker codes, never raw broker messages.

A shortened replay requests a coalesced official refresh: singleflight, at most one
successful recovery query per minute, with existing failure backoff retained. A new
saved official receipt wakes the pending accounting retry without reconnecting the
Gateway. Normal history refresh remains fifteen minutes when recovery is unnecessary.
Persisted rows alone are never unioned into completeness evidence; unproved cross-day
gaps still require authoritative backfill.

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
normal money path with its €5,000 virtual capital exactly once.

DAY prefers an exact, durable America/New_York start-of-day virtual-equity
baseline. The whole-account IB DailyPnL includes KEEP and is therefore not used.
When an exact boundary vector is unavailable, the first complete fresh
KEEP-excluded virtual-equity observation in that New York day is fixed durably
as a `session_open_proxy`. Its first delta is explicitly zero because the sample
is the proxy reference, not because a broker reported zero for the full day.

`day-baseline.mjs` supplies the bounded persistence and calculation half of that
SOD path. It accepts only a complete EUR `{ j, joe, joel, total }` virtual-equity
vector under an exact source-contract fingerprint whose scope is
`stage0-virtual-desks-keep-excluded`. Each observation carries `sourceObservedAt`,
the oldest contributing mark/FX observation, a complete execution-coverage
watermark, and an effective economic-history digest. The adapter persists the
latest vector atomically and retains the freshest vector actually observed at or
before the next New York midnight. A fresh first later sample may seed only the
explicit session proxy, whose actual reference time remains distinct from the
true midnight period start.

The valuation convention is the last complete pre-boundary vector within the
declared freshness limit, followed by authoritative execution evidence that the
effective execution/fee digest did not change before the exact half-open cutoff
`[... , periodStart)`. Marks and FX need not arrive on the midnight nanosecond;
their oldest observation is recorded and bounded. The coverage receipt and proof
may arrive after midnight and may extend beyond it, but its revision must be
calculated at the midnight cutoff. This keeps post-boundary executions out of SOD.
DAY is then current proven virtual equity minus the fixed exact or proxy vector,
so closed roundtrips remain included even after their positions disappear. A
pending exact proof does not suppress an available proxy; a later valid exact
proof supersedes it. Both choices survive restart and reset on the next New York
date. Proxy metadata marks the result approximate and describes it as change
since the recorded sample, never as full-day P&L.

`desk-ledger.mjs` supplies the live vector from the complete official all-account
history, effective dated desk ownership, execution-owned FIFO, current marks, and
explicit FX observations. `createDeskDayPnlProducer` binds that provider's
canonical policy hash before accepting evidence. It persists the candidate digest
calculated through the candidate's `executionCoverage.throughInclusive` watermark;
that watermark is included in the oldest-source freshness bound even when a mark
or FX observation is slightly newer. It then calls `buildDeskDayBoundaryEvidence` against
`familyHistoryAdapter.inspectState()` for the boundary-exclusive digest. This
prevents a correction first learned after midnight from silently rewriting both
sides of the comparison. An observation exactly at midnight is accepted only with
the provider's exact-cutoff proof; any execution at that timestamp changes the
inclusive candidate digest and rejects promotion.

The digest binds the highest effective correction revision, actual fees, desk
ownership policy, and KEEP exclusion; it excludes receipt/capture timestamps.
Complete official intervals must have no gap across
`[candidate execution watermark, periodStart)`. Source method, policy hash, history
revision, ownership completeness, persistence, freshness, or coverage disagreement
rejects the affected evidence; an independently valid fixed proxy may remain
available while exact-boundary proof is pending. Runtime
state is stored atomically at
`/var/lib/joe-board-pusher/day-baseline.<policyHash>.json` beside the existing
family ledger and history sidecar on the same persistent mount. The full
lowercase SHA-256 ownership-policy hash selects the file. Legacy
`day-baseline.json` and other policies' files are preserved for rollback and
never copied into the active policy's baseline.

Stage-0 desks share one paper account and may both hold one contract.
`calculateFamily` defaults to exclusive ownership and fails with
`ambiguous cross-family ownership on contract` when the target desk and
another desk are both open on that contract. The J projection and each desk
valuation pass `ownershipMode: "virtual-shared-account"`. In that mode FIFO
lots come only from the target desk, another desk's fills on the same contract
are not an ownership failure, and the broker net is reconciled to the sum of
every desk's non-KEEP fills. One desk's open lots may differ from that net. An
open virtual lot still needs a current portfolio mark, including a zero-quantity
row when the account itself is flat. Account-portfolio callbacks omit that
contract once the broker net is zero, so the paper session requests delayed-frozen
market data for the open virtual names and records only an explicit last or close
tick. The tick's own clock is the mark time. No tick leaves the lot fail-closed.
After the first accepted last/close tick the market-data subscription is cancelled; the cached mark is held until a 240s refresh window, then re-requested. Ops can kill streaming without an image swap via `JOE_FLAT_NET_MARKS=0` or by touching `/var/lib/joe-board-pusher/disable-flat-net-marks` (no-op controller / sync skipped).

KEEP names are never requested. Exact KEEP stays SXR8×1401 and TSLA×1. A
client ID outside the dated ownership policy still fails loud.

OPS-392 adds J's legacy Mac client 229 from `2026-10-06T13:40:47Z`, inclusive,
with no end date. `J_DATED_CLIENT_ASSIGNMENTS` in `execution-history.mjs` is
the canonical assignment; `desk-ledger.mjs` composes it into the policy used
by v1 equity and v2 activity. The pusher supplies that same dated supplement
to J's FIFO, fee/FX readiness, captured history and flat-net mark selection.
The persisted family classifier stays unchanged; existing all-account captures
and ledgers remain usable. Earlier 229 activity and unknown clients still
block all-desk ownership. Both `J|` and `j|` prefixes work; a tag alone never
claims a client. The executor already normalizes only the desk prefix and
retains its separate executor-provenance/admin-attribution ownership gate;
this valuation assignment grants no broker action authority.

Raw IB fill times such as `20261006 09:40:47 US/Eastern` use the same
`executionTime` parser as the family classifier. Activity ownership and latest
fill selection compare epochs, and the summary stores canonical UTC ISO times.
The inclusive 229 boundary is enforced before activity is assigned to J;
invalid or ambiguous clocks and unowned fills still fail closed.

This assignment changes the desk policy hash. R14 selects a separate baseline
file automatically; no manual retirement or deletion is needed on switch.
The candidate image is `household-v2-switch-set-r14-202610201330`; the retained
rollback image is `household-v2-switch-set-202610201110`.

Joe order clients claimed from the 2026-09-10 America/New_York baseline are
22, 89, 90, 91, 119, 130, 131, 148, 151, and 152. The 2026-09-23 ledger listed
the IDs other than 22 and did not keep a separate first-seen instant, so each
assignment starts at the stage-0 baseline and covers every retained fill.
Read-only clients 92 and 94 place no orders and stay unassigned. The J-family
classifier is unchanged, so `family-ledger.json` and `family-history.json`
remain valid.

Those Joe assignments also changed the desk ownership policy hash. Before R14,
loading a mismatched `day-baseline.json` blocked the adapter for its entire
lifetime (`day baseline source method or classifier mismatch`). Neither the
next NY day nor a restart with the same file cleared that failure.

With R14, a new policy's file starts empty. V1 DAY remains unavailable/null
(`day_pnl_unavailable`) until the existing calculator supplies a complete fresh
KEEP-excluded equity vector proven against retained execution/fee history,
the active ownership policy, current marks and FX. Its first durable sample
establishes an explicitly approximate `session_open_proxy` today: the initial
delta is zero relative to that actual sample, and earlier day change is excluded.
The fixed reference survives restart. No prior-policy value is reused and no
historical midnight mark or FX value is invented. Invalid/stale evidence,
corrupt active-policy state, and failed persistence remain unavailable.

At the next NY calendar-day midnight, an observation from at most five minutes
before the boundary plus authoritative continuous execution coverage and an
unchanged boundary economic-history digest can promote an exact SOD baseline.
This is conditional on those proofs, not trading-day opening; without them the
first valid new-day observation supplies another approximate session proxy.
V2 still stages every desk's `dayPnl:null` with `not_exact_yet`, including after
v1 proxy or exact recovery; the bounded v2 handoff does not carry this money.
Preserve both legacy and policy-keyed files during switch and rollback. This
ownership-hash change leaves the family classifier and its retained captures
unchanged, unlike the 2026-09-22 J claim for clients 76, 78, 79, 80, and 83.

The same accepted all-desk vector supplies each desk's displayed equity,
since-start PnL, and execution-owned OPEN PnL. This includes Joe closed roundtrips
after their positions disappear. J keeps its existing accounting and history
metadata and must reconcile exactly with the J member of the all-desk result.
When current marks or FX age out, the projector may retain the last durable proven
all-desk equity vector, marks every affected desk with the oldest contributing
economic-input time, and derives since-start PnL only as retained equity minus
€5,000. New execution checks cannot refresh that carried-money clock. Accounting
portfolio rows carry a separate `markObservedAt`, updated only by a valid price;
the family calculator requires it and never substitutes a generic callback time. A retained
vector never becomes fresh DAY or OPEN evidence. If no proven vector exists, Joe
and Joel equity/since-start money and household totals are null; the projector does
not fall back to a synthetic €5,000 stand or raw portfolio callback PnL. Legacy
KEEP positions remain visible but excluded from every Stage-0 money value.

When an accepted all-desk vector is present, OPEN is each desk's owned-lot
unrealized result even if desks share a contract. The flat-residual proof
below applies only when that vector is absent.

`pnlSources.open` is `available` with method `owned-lots-current-mark-fx` only when
the complete J-family ledger reconciles every non-KEEP broker position, no foreign
non-KEEP quantity remains, every excluded position is exact configured KEEP, and
all current J marks and explicit quote-to-EUR FX rates are fresh. J OPEN is the
per-lot unrealized result in EUR; Joe and Joel are exactly zero only under that
flat-ownership proof. Any missing or residual ownership evidence makes every desk
and total OPEN value `null`; a residual cannot be assigned between Joe and Joel
from the account-netted position and is never allocated by assumption. The family
adapter requires fresh explicit FX and current complete broker positions, while
the publisher separately rejects stale or future J marks and future source times.

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
overlap. Accounting-triggered retries can use a verified prefix plus its uncovered
tail; an empty suffix keeps a stable anchor so repeated receipts coalesce. These
retries cannot postpone the periodic overlap scan that retrieves prior-day
corrections. Older unqueryable gaps remain explicit. It runs only one bounded subprocess
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
`27,28,29,50,51,52,53,54,55,56,76,78,79,80,83`; inclusion of read client 56
preserves the proven production classifier and grants no order authority.

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
`mark` is emitted with a known quote currency. Position `marketValue` stays absent;
position `openPnl` is the owned-lot current-mark result in EUR for verified J
positions and is explicitly `null` while OPEN is unavailable. `dayPnl` stays
`null` until a valid exact SOD baseline or explicit session proxy exists. Push heartbeats never advance
the broker snapshot timestamp; before the first complete broker snapshot the
publisher skips the push rather than fabricating an empty book.

Run synthetic replay tests: `npm test` (fixtures are labelled synthetic, not live).
