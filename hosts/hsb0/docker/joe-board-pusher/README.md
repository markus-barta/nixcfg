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

The switch-set image is `hsb0-joe-board-pusher:household-v2-switch-set-r21-202611031258` (JOED-149 revision 11; pusher, stager, executor and mailbox runtime), selected by the active `v2` release set (OPS-354 activation). The immediate shared-image rollback retains `household-v2-switch-set-r19a-202610230614` and the asserted running generation. The separate v1/variant B rollback remains `hsb0-joe-board-pusher:household-v2-switch-set-r16d-202610201800` (the `current` set, which restores the pre-cutover hsb0 tree).
The pusher, isolated stager, executor and mailbox runtime use that same immutable image;
the executor source remains on its existing mount. `pull_policy = "never"`
prevents an automatic rebuild or pull. Build this new tag during the separately
reviewed host promotion; keep `flat-net-reconcile-perf-202610010310` intact for
rollback. Never rebuild over either published tag. The base image digests,
package manifests and `npm ci` remain unchanged.

Both runtime source pins name the committed rev-11 implementation
`729ddf040951a5a0f4ee3acada8613d62255227e`. `git rev-parse REV:SOURCE_PATH`
gives pusher tree `eda3c8d69c3b555c9136bf30195d1ffafa82f99f` and executor tree
`92e261d0dd504b30d8ec8850641310e129f7a8fe` (the executor implementation is unchanged).
The later tag-only README/test edits are excluded from the pusher build context;
the executor's image-comment edit changes no copied runtime source. These Git
pins identify source snapshots; the new tag still needs its separately approved build.

R16d refreshes the read-only position subscription with `cancelPositions` then
`reqPositions` every 120 seconds on the existing five-second tick, while the
session is ready. One reply stays in flight until `positionEnd` or retirement of
its connection generation. Each reply starts a fresh accumulator and atomically
replaces the previous position set at completion, so omitted contracts disappear.
Partial callbacks retain the last completed rows and clock. Only that completed
reply advances position coverage; `updatePortfolio` and `accountDownloadEnd`
cannot prove a complete position set and never renew its clock. Both all-desk
and J family activity use this clock, independently of accounting/mark ages.
A missing end ages coverage out after 420 seconds (stale at 421 seconds).
KEEP classification and v1 projection/POST bytes for identical inputs stay unchanged.

R16e renews the gateway confirmation with a read-only `reqCurrentTime` heartbeat
every 20 seconds, independently of other socket traffic. Only the current
generation's reply on an established, connected target-account session advances
`apiReplyCheckedAt`, using its local receipt time and the existing readiness-gated
publication path. Position coverage stays on its 120-second cadence; heartbeat
replies never renew position, account-summary or mark source clocks. Missing
replies leave the check to age out under the unchanged 60-second readiness rule.

R16d → R16 rollback needs no pair move-aside: the stager, persisted sequence
state, pair schema and source-clock semantics are unchanged. Preserve pairs,
the current pointer, sequence high-water, lock, receipt log and v1 bodies.
The separate R16 → R15 move-aside procedure remains required in the host runbook.

## Phase B exact values (JOED-86; revision 11 provenance in JOED-149)

The active v2 host configuration passes **`JOE_V2_CONTRACT_REV=11` to both
the pusher and the isolated stager**. The approved rev-11 board must precede
runtime activation. Revision 10 remains an explicit rollback; revision 9 is
the default for an absent or unrecognized setting. This setting is independent
of `JOE_PUSH_SCHEMA`; it neither selects a POST target nor enables publication.
The lock supervisor forwards the selected revision alongside its existing
environment allowlist. Changing the declarative setting prepares the next
host activation; it is not evidence of deployment or live producer sign-off.

The bounded private observation carries scalar exactness evidence after the
existing v1 calculation/settlement. It contains no account, execution or conid
identifiers and no ledger. The stager still validates source clocks and gateway
readiness independently of its advancing generation clock.

| Value                                | Revision-10 emission rule                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Position quantity, last, worth, OPEN | Match the broker position to exactly one `updatePortfolio` callback by conid and quantity. Copy native-currency values without rounding, with actual callback `updatedAt`. Every field has its own callback clock; a valid price cannot renew retained worth/OPEN. Missing, ambiguous or mismatched callbacks stay `null/not_exact_yet`; observations over the existing five-minute mark bound use `position_stale`. Position coverage keeps its separate 420-second bound.                                                                                                                                                                                                                                                                   |
| Desk equity, OPEN, since start       | Use that desk's existing FIFO result only after complete all-account history, ownership and broker-position reconciliation. Missing/unclaimed/pre-ledger input uses `ledger_unreconciled`. Independently reconciled siblings can remain exact when another desk lacks a mark; totals require all three exact summands. Stale inputs stay null.                                                                                                                                                                                                                                                                                                                                                                                                |
| Desk DAY                             | Additionally require the durable, once-daily exact America/New_York midnight SOD proof. Missing/missed/reseeded SOD and `session_open_proxy` use `null/sod_missing`. Copy `sod-virtual-equity` evidence with its actual period and observation time; the v1 approximate DAY remains unchanged.                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Since-start base                     | EUR **5,000 per desk**, EUR **15,000 aggregate**, as verified in JOED-85 against `project.mjs`, `desk-ledger.mjs` and `family-ledger.mjs`. Unknown base withholds `totalPnl/not_exact_yet`. The verified FIFO accounting period remains 2026-09-10 New York onward.                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| J/other converted desk money         | Every converted field carries `money.fx` with the actual IB `ExchangeRate` used, quote EUR and its original callback time. Missing, stale, future, nonpositive or unrepresentable rates keep money null. DAY is exact across two rates when its durable SOD rate proof exists at or before `periodStart` and the current rate is fresh (300 seconds); both must cover the same currency pair. `money.dayPnl.fx` keeps the current rate. When rates differ, `pnlSources.day.detail` names the SOD rate source and observation time (no rate values, at most 240 characters). Missing or late SOD FX proof stays `not_exact_yet`; missing SOD stays `sod_missing`. A single valuation requiring multiple foreign rates remains `not_exact_yet`. |
| Cash and KEEP                        | Cash is solely fresh EUR `TotalCashValue` in `brokerAccount.cash`; NAV never substitutes. There is no per-desk cash property. SXR8/TSLA remain `scope:keep, desk:null` and never enter desk money or totals. Position DAY remains reasoned null.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |

Per-desk `pnlSources.day/open` lets exact siblings coexist with unavailable
desks. Aggregate evidence and totals stay unavailable until every corresponding
desk field is exact; sums use decimal integer units. Neither a heartbeat nor
the retained v1 equity vector can renew an economic input. An unavailable
callback field or rate is never rounded into apparent exactness.

### Two proven Today conversions

Revision **11** is active in the host configuration. Each eligible desk's
available `sod-virtual-equity` DAY source adds `pnlSources.day.fx` with
`start: { source, observedAt }` and `end: { source, observedAt }`. Both sources
are `ib-account-ExchangeRate`. The start comes from durable SOD proof at or
before `periodStart`; the current observation must be at or after the start.
These objects contain no rates. Rates stay in the existing `money.fx` path,
including the current rate in `money.dayPnl.fx`. Proven equal-rate conversions
also carry the two observations. EUR-only desks, missing proof, unavailable
DAY and invalid timestamp ordering omit the structured provenance. It is
never reconstructed from `day.detail`; the rev-10 detail behavior is preserved.

Rollback: set **`JOE_V2_CONTRACT_REV=10` in both pusher and stager**. This keeps
revision-10 snapshot behavior and omits the new structured DAY FX objects.

The new runtime reads preserved rev-9, rev-10 and rev-11 pairs without
changing enrollment, allocator floor, sequence high-water, lock or old receipts.
Default output retains the rev-9 receipt digest; activated output records the
vendored rev-11 digest. A rev-10 receipt cannot claim rev-11 structured FX;
a rev-9 receipt cannot validate a Phase-B pair. Turning the setting off changes
future output; it does not erase a committed pair or an
uncertain pending POST. A rollback to an older binary after activation needs
the coordinator's archive/move-aside procedure, preserving sequence state and
lock; never reset or delete history. Keep the compatible board during that rollback.

### Complete contract re-vendoring

Vendor **all 17 files** under JoeDesk `contracts/`, exactly, from immutable
commit `36fecfeb7e56400db3076304d150e9eeb2beb05b`. The independent
`release/contracts.json` pin is revision **11**, contract-set SHA256
`c266b39e33e6e15be491263b0ca3575598dd264da3e1a9f6d5a147fc9f1bd49b`.
Use local `git show <commit>:<path>` bytes; no runtime fetch or partial schema
copy. `contracts.lock.json` lists the complete sorted filename, size and SHA256
closure. The set digest hashes compact JSON entries in sorted path order with
property order `{path:"contracts/<name>",size,sha256}`. Check it against the
independent release pin before writing the lock. Update the fixed verifier's
source/revision/set constants and the worker's activated receipt digest
together, retaining the rev-9 and rev-10 compatibility digests. `node verify-contracts-entry.mjs`
verifies the fixed closure before imports at build time and worker startup;
missing, extra, changed or linked files fail closed. The Docker source closure
includes `v2-exact-values.mjs`.

Validation: `node --test` in this directory, as in `.github/workflows/check.yml`. Synthetic
tests cover the real FIFO/adapter evidence path, per-field callback clocks,
reconciliation failures, SOD/proxy rejection, FX provenance, KEEP/cash, complete
sums, rev-11 timestamp boundaries, schema/acceptance and durable restart. A byte comparison loads the
pre-change stager from local Git and proves default rev-9 output unchanged,
even when offered exact-value evidence; a second comparison preserves rev-10 bytes.
This is local patch evidence; cross-family
review, OPS promotion, live paper proof and Amy's sign-off belong to the
coordinator.

## household.v2 publication switch (OPS-408)

Only the pusher can POST. hsb0 adds `JOE_PUSH_SCHEMA=inspr.joe.household.v2`
iff the selected release set's `board.data_schema` is `v2`. An absent or any
other value retains v1 POST bytes, logs and cycle records. Pusher, stager and
executor images all follow that release set; the candidate tag alone activates
nothing. The build context and restart trigger still capture every production
`.mjs`; changing source changes the host derivation even before activation.
`T100-joedesk-release.py --prove-current` compares the complete v1 runtime
against `67e15fad` with `build` removed, and evaluates a synthetic r17 v2 set.

Each v2 cycle uses `StageStore.readCommittedPair()`: `current.json` is the
stager's commit marker, and its existing `readPair` validates the closed pair,
receipt, contract digest and snapshot hash. The publisher reads only the pair
named by that marker, never reservations, `.next-*`, temporary files or a newer
uncommitted `pair-*`. It sends the validated file's original Buffer, without
JSON reserialization or field edits, with the existing Bearer/Content-Type
headers. The pusher's nested bind of exactly `/var/lib/joe-board-pusher/v2` is
read-only only in v2 mode, covering the existing writable parent mount. The
stager retains its writable v2 mount and `network_mode = "none"`.

The pusher owns `/var/lib/joe-board-pusher/v2-post-state.json` (0600, outside
`v2`). One fsync/rename/directory-fsync transaction stores `lastPosted`, a
pending sequence/body digest reserved before transmission, and the latest
**128 POST outcomes**, with a hard **65536-byte** bound. Keeping receipts with
the cursor makes their settlement atomic and independent of stager pruning.
Outcomes contain only status, seq, generatedAt, receivedAt (null when absent),
recordedAt, bodySha256 and a closed outcome. No body, token, raw response or
account value is logged. Its recognized `.tmp` sibling is safely overwritten
after ownership/mode/link checks following a pre-rename crash.
Emitted `v2_post` lines carry `gateway` and, when false, a value-free `lastError` reason code for the HOSTD-58 supervisor; unknown gateway evidence omits both fields and cannot trigger a restart.

A new process sends the newest committed pair; thereafter only a sequence above
the durable cursor is eligible. One send stays in flight. Uncertain replies
retry committed bytes, never regenerate them. A 422 `sequence_replayed` is a
terminal recorded outcome, covering an identical retry or the exact pair seeded
by migrate-v2. That response alone cannot prove remote byte identity; OPS must
seed the board from this same retained pair and preserve the allocator. Other
failures retain the pending fingerprint for retry. Missing/corrupt pairs or
posting state fail closed; no new committed sequence means no POST and never a
v1 fallback. An old pair's original generation stays old, so the board's own
freshness expiry remains honest.

V1 is still computed and stored in `v1-cycles/<seq>.json` through the existing
handoff. Its receipt's `v1PostStatus` is `not_posted_v2_active`; after a successful
body write `v1Status` has that same value. `v1_unbound` still means an actual
storage/binding failure and never means intentional non-publication. The shared
cycle validators accept the new status, so collector hash/sequence/observation
binding still works. OPS-392 evidence collectors must require a numeric successful
v1 HTTP status for v1 acceptance: `not_posted_v2_active` proves stored v1 evidence
only, never board acceptance. V2 acceptance comes from the matching body hash and
sequence in `v2-post-state.json` outcomes.

After migrate-v2 seeds seq N from the retained committed pair, the first flip
POST can be **N with identical bytes**, or **greater than N** if staging advanced.
It is not guaranteed to be strictly greater. `StageStore.reserve` increments
and durably writes `sequence-state.json.lastReservedSeq` before publishing a
pair; `open` restores and validates that high-water. This requires preserving
the same allocator and using the exact pair for migration, not an independent
seed or re-enrollment.

Run the real board contract test with `JOEDESK_CHECKOUT` pointing at the pinned
read-only d36b5295 checkout. It skips explicitly when unset. The normal path
starts a loopback HTTP server; where the sandbox denies listen, the explicit
`JOEDESK_CONTRACT_TRANSPORT=in-process` path dispatches through the real
`createJoeServer` request handler and storage. Report that path separately:
it proves server acceptance/retention, not socket transport.

R17 → r16d needs no move-aside before v2 activation. After activation, r16d
rejects the new receipt status; archive all retained pairs, current pointer and
stager receipt log outside `v2`, preserving sequence state and lock. See the
host RUNBOOK for the coordinated rollback, including board schema and executor
guards. The new posting-state file is ignored by r16d.

## household.v2 switch-set staging (OPS-392)

The existing `joeHouseholdV2StageEnabled` flag enables the independent
`joe-household-v2-stage` service in the Phase A candidate. The Results producer
remains disabled (`nixcfg.joeResultsProducer.enable = false`). This build
adds useful account and position evidence to local staging. The stager itself
never POSTs; the separate pusher switch above controls publication. PAPER only;
live remains locked. In v1 mode all accounting, token source, POST bytes and
interval remain unchanged. By default (revision 9), desk money and totals
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
 sourceObservedAt:{equity:string|null,cash:string|null,positions:string|null},
 apiReplyCheckedAt:string|null, positions:[{symbol,side,desk,scope}],
 deskActivity:{j,joe,joel},
 v1Cycle:{v1Sha256,v1Status,v1RepliedAt,observationId}}
```

There are at most 256 broker identities before encoding; oversize observations
are dropped whole and keep the unused credit. Busy/disconnected/backpressured
opportunities are dropped. POST settlement and the initial offer do no ledger
traversal, contract import, fsync, worker wait, second POST or queued retry.

Each attempted POST hashes the exact serialized v1 request once and gets a
unique `ops392.v1-cycle.<uuid>` observation ID. After response consumption, the
handoff carries a closed `v1Cycle` envelope: the SHA256, HTTP status (100–599),
local reply-completion time and observation ID. A rejected fetch uses
`post_failed`; failed response consumption uses `reply_failed`. Neither failure
drops the available observation. Request bodies, reply bodies, financial values
and raw POST exceptions are excluded from publication logs.

Body storage runs asynchronously **after v1 has settled**, with at most one
body write outstanding; a hung write refuses further bodies as unbound and
coalesces retention controls to the latest set instead of accumulating payloads.
Bodies above 256 KiB are unbound. The lock-holding
stager durably reserves a sequence and sends a bounded `v1_store` control frame
with that sequence and observation ID. The pusher alone writes the exact body
to `/var/lib/joe-board-pusher/v1-cycles/<seq>.json` (0600, directory 0700), fsyncs
the file and directory, then acknowledges only the sequence, ID and success bit.
The stager has no mount of `v1-cycles`, never receives a body, and keeps
`network_mode = "none"`. No new service permissions or mounts are required.

Both `receipt.json` and its `receipts.jsonl` row record `v1Sha256`, `v1Status`,
`v1RepliedAt`, `observationId` and `v1PostStatus`. The latter preserves the POST
outcome even when a failed body write changes `v1Status` to `v1_unbound`.
After 1500 ms without a storage acknowledgement, the stager records an unbound
pair and disconnects; the five-second supervisor watchdog remains independent.
Unbound and failed POSTs cannot prove v1 acceptance. Storage failures emit only
closed `v1_cycle_unbound` events. Storage can neither delay nor fail a v1 POST.

After pair pruning, the stager returns the retained sequence set (default N=10).
The pusher serializes body pruning behind its writes and keeps exactly the
existing bodies for those pair sequences, by count rather than age. A reconnect
repeats the set, removing recognized bodies orphaned by a crash or rejected pair.
Recovery after an interrupted exchange converges on that same set; missing or
failed-write bodies remain visibly unbound rather than being reconstructed.
Unknown entries, symlinks, ownership or mode mismatches stop body cleanup and
emit a value-free event. Legacy receipts without cycle metadata remain readable
and do not establish v1 provenance.

R16 uses the worker's local observation-receipt instant for v2 `generatedAt`,
captured when reserving the sequence before the optional body-store handshake.
It advances each staging cycle even during IB's roughly three-minute book cadence.
The exact v1 body hash (`v1Sha256`) binds a pair; generation equality is not
pairing evidence. V1's `generatedAt` remains inside its stored body.

NAV (`NetLiquidation`) and cash (`TotalCashValue`) retain raw account-summary
strings and currencies, including scale, negative signs and signed zero. Only
valid EUR decimal lexemes pass through; missing, non-EUR or unrepresentable
values become null with `source_unavailable`. Rev 9 uses `brokerAccount.reason`
for equity and `brokerAccount.reasons.cash` for cash. Both cover the entire paper
account including KEEP; no conversion or numeric FIFO value enters them.
The private `sourceObservedAt` clocks come from the individual NAV/cash summary
callbacks and completed position replies. An unrelated callback
cannot renew another source. Legacy frames without those clocks still use book
time. `brokerAccount.observedAt` is the oldest source of the money actually
emitted (or the oldest known account source when both values are null);
`positions.observedAt` retains the position-coverage source time. These clocks
are independent of v2 generation. At generation, sources older than
420 seconds (or in the future) withhold NAV/cash with `source_unavailable`.
This shared 420-second freshness bound covers desk readers, NAV, cash, position
coverage and gateway staleness: about twice IB's 180-second cadence plus margin.
Expired position coverage leaves all values null with `source_unavailable`,
clears unproven desk ownership, and sets the coverage reason accordingly.

Gateway readiness requires a completed account-matched account-summary or
positions API reply, or a current-generation `currentTime` heartbeat reply on
an established target-account session. TCP, account download and login alone are
insufficient. `checkedAt` is the qualifying reply's local receipt instant. Both its age
at source generation and at staging receipt must be nonnegative and under 60s.
Old, future and stale replies are not ready; account money is then withheld.
With no completed reply, omit gateway rather than fabricate a timestamp.
The worker mirrors the board's post-acceptance checkedAt regression gate and
fsyncs its nonfuture high-water before publishing; equal checks are accepted.
Future replies never advance this durable watermark. A check ahead of receipt
but within a skewed generation skips the whole pair to avoid disagreeing with
the board's generatedAt-relative watermark. The read-only order refresh below
does not renew readiness. Readiness expires when no qualifying reply renews it.
Checks older than 420 seconds use `snapshot_stale`. Rev 9 requires a boolean
`apiSessionReady`, so unavailable readiness is represented by `false` plus its
reason; the contract does not allow a null readiness flag. The stricter existing
60-second readiness rule still applies.

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

Desk rows use exactly `desks[].state` from the [data schema](./contracts/data.schema.json), unchanged since rev 9:
`stuck` if a position, order or execution reader is unavailable, has unknown
ownership, or its observation is older than the shared 420-second pusher
bound; otherwise `working` if that desk has
positions, active open orders or executions on the executor's current New York
day, and `sit-out` if empty. Each reader timestamp is fresh exactly in the
inclusive interval `generatedAt - 420s` through `generatedAt + 30s`; a missing
or unparseable timestamp is unavailable and a timestamp beyond either bound is
stale. Readers newer than the book remain fresh. Diagnostics use the post-v1 observation time
instead of book time. Read-only `reqAllOpenOrders` runs on connect and
every 60 seconds, checked by the existing 5-second maintenance tick, with at
most one reply in flight. Each reply collects a fresh set keyed by
`(orderId, clientId)`; `openOrderEnd` atomically replaces the previous set,
including an empty set, and stamps its generation-scoped completion clock.
While a reply is in flight the last completed set and clock remain unchanged;
a missing end marker blocks overlapping requests and the old clock expires
after 420 seconds, yielding `stuck`. Unsolicited callbacks, publication and
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
change v1 reader availability. In default revision 9, `desks[].action` says
"Valuation is not exact yet." and desk money stays null with individual
`not_exact_yet` reasons. Revision 10 reports whether all or some desk values are
available, following the actual money fields. KEEP scope is unchanged.

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
memory/swap limit, 1 CPU (JOED-100: 0.25 starved the cold start past the watchdog) and 32 processes. It runs as 1000:1000 with a read-only
root, no capabilities and no-new-privileges. Only the private v2 state and IPC
directories are writable. The supervisor discards child stdout/stderr, enforces
a separate 60-second startup deadline and five-second per-job watchdog, kills the actual `flock --no-fork` worker,
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

The worker verifies the exact 17-file revision-11 closure before importing any
contracts. Source time is calendar-validated UTC from `book.ts`; missing or
invalid source time suppresses staging. Generation uses the worker's receipt
clock and is clamped to the durable `lastGeneratedAt` floor. That existing field
keeps the current state format backward compatible, including r15 state and
unpublished reservations recovered after a crash. A clock rollback that would
put generation more than five seconds ahead suppresses staging until the clock
catches up; generation never regresses. Each sequence is fsynced, renamed and
parent-directory-fsynced before use; crashes may burn numbers, never reuse them.
The stable `.allocator.lock` inode is never replaced. A second writer cannot
acquire it. New reservation identities use the unique v1 cycle ID; legacy
`["ops392.switch-set.v2",generationInstant]` identities and Phase A reservation identities
with a null gateway watermark remain readable. Older contract-set staged pairs fail closed and require coordinator
review before promotion; never reset enrollment or sequence state to migrate.

Readers follow only `current.json` to an immutable `pair-<seq>` directory.
`snapshot.json` holds exact validated ingress bytes without `receivedAt`;
`receipt.json` records the real local staging receipt, sequence/generation,
`generatedAdvancedAt`, snapshot SHA256 and contract-set SHA256. On each advancing
v2 generation, `generatedAdvancedAt` is the staging receipt instant, independent
of v1's generation. Receipt is not
proof of live board acceptance. Pair files and directory become durable before
the pointer's own atomic replacement. `RETAIN_PAIRS` defaults to **10**; the
`StageStore.retainPairs` constant override permits 10–1024. Keep the newest N
pairs by sequence count only, never age; the current pointer is protected.
Recovery validates retained and orphan pairs before pruning. Pruning atomically
renames an old pair to a recognized `.retired-<seq>` tombstone so interrupted
cleanup remains recoverable. `receipts.jsonl` is a separate fsynced append-only
0600 log with one record per staged/resolved sequence: `seq`, outcome
(`committed`, `rejected`, or recovered `staged`), generation/staging/record timestamps,
and `pairSha256` (the snapshot byte hash from the pair receipt), plus its format.
It contains no payload values and outlives pair pruning; restart never appends a
duplicate. A crash can burn an unbuilt reservation without a staged pair/record.
A durable orphan is recorded as `staged`; the pointed-to pair is `committed`,
meaning local pointer publication only. The supervisor emits exactly
`{event:"v2_stage_committed",seq}` for a completed commit. Unknown files, wrong
ownership/modes, inconsistent sequences/digests or torn log lines disable staging
and preserve evidence. v1 state is untouched.

Receipt recovery uses an optional, atomically replaced 0600 checkpoint named
`receipts-checkpoint.json` in **stager-only persistent storage**. Its directory
comes only from the absolute `JOE_V2_STAGE_CHECKPOINT_DIR` environment variable.
Unset or empty disables all checkpoint reads/writes and uses the original full
scan. The directory must already exist as a real directory (no symlink), owned
by the stager's uid:gid with mode exactly 0700. Shared paths are refused,
including `/run/joe-household-v2`, the v2 state directory and its pusher-visible
parent `/var/lib/joe-board-pusher`, and the socket directory; ancestors and
descendants of those shared paths and aliases into them are also refused.
Invalid configuration disables the feature for that worker with one value-free
`{event:"v2_stage_checkpoint_disabled",reason:"directory_unsafe"}` log line.
There is no fallback to `/run/joe-household-v2/receipts-checkpoint.json`; a stale
file there is ignored, never read or replaced.

It records a line-boundary byte offset, the last receipt sequence at that offset,
and SHA256 of every preceding byte. Startup streams the prefix hash in 64 KiB
chunks, checks the boundary row's sequence, and parses/validates only the tail.
After completed recovery and fsynced appends, the checkpoint stays before the
last `retainPairs + 1` non-rejected receipts; each retained pair must still
match a validated receipt (including v1 binding).
During full and resumed scans, validated progress is saved every 4 MiB at a
line boundary strictly before the oldest retained pair's receipt. A startup
deadline kill can therefore resume after rehashing the saved prefix, rather
than repeat JSON/binding validation from byte 0. Completed scans and fsynced
appends keep the usual conservative boundary without rehashing history on each
job. Hash state and recent boundary anchors stay bounded in memory.
Missing/corrupt/unsafe checkpoints, hash/offset/sequence disagreement, or a
retained pair before the checkpoint cause a full scan with the original strict
checks. Invalid or torn log rows still disable staging without truncation.
Checkpoint write failures leave the authoritative state/log intact and permit
the next start to verify an older checkpoint or perform a full scan.

Recovery cost is O(log bytes) for streamed SHA256, plus JSON/binding validation
for the tail (normally 11 receipts and one boundary row at default retention),
plus validation of retained pairs. Rejected rows since the oldest retained pair
also belong to that tail. Full recovery validates every receipt, so its CPU cost
grows with history; a checkpoint bounds the usual expensive validation work,
not the bytes hashed. With the persistent host mount below, the checkpoint
survives both container recreation and host reboot, avoiding a reboot-triggered
full scan. A missing mount, unset variable or unusable checkpoint safely falls
back to the full scan under the longer startup deadline. A missing directory
is never created by the worker.
OPS measured approximately **0.12 s CPU/MB** for full validation on hsb0. The
**60 s** startup deadline permits roughly **400–450 MB at 1.0 CPU**, or
**100–110 MB at 0.25 CPU**, allowing for startup overhead. Reverting the stager
to **0.25 CPU reintroduces the risk** of hitting the startup deadline. Periodic
checkpoints let validation accumulate across restarts, provided the cache is
writable and each attempt can rehash the prefix and validate another 4 MiB;
the remaining retained-pair tail must also fit within one startup attempt.
These are approximate host measurements, not timing guarantees.

The network-facing pusher shares the **0700 `/run/joe-household-v2` mount** and
runs as the same UID as the network-less stager. Mode 0600, ownership and
O_NOFOLLOW therefore do not separate those writers. A matching SHA256 proves
byte equality, not that the prefix was previously validated: a forged checkpoint
could conceal malformed history or decreasing sequences and hide a retained
receipt. OPS-392's trust boundary requires the checkpoint directory to be
mounted **only into the stager**, never into the pusher, even read-only. The
pusher's `v2/` mount remains read-only. The checkpoint is trusted validation
progress only within this isolated mount; prefix hashing detects changes to
the receipt bytes, and boundary/tail/pair validation still runs.

OPS must include these exact host changes in the same PR (this source patch
does not edit host configuration):

- In `hosts/hsb0/configuration.nix`, add the systemd tmpfiles rule
  `"d /var/lib/joe-household-v2-stage-checkpoint 0700 1000 1000 - -"`
  to `systemd.tmpfiles.rules` (the stager runs as uid:gid `1000:1000`).
- In `hosts/hsb0/docker/compose-spec.nix`, append
  `"/var/lib/joe-household-v2-stage-checkpoint:/var/lib/joe-household-v2-stage-checkpoint:rw"`
  to `services.joe-household-v2-stage.volumes`, and set its `environment` to
  include
  `"JOE_V2_STAGE_CHECKPOINT_DIR=/var/lib/joe-household-v2-stage-checkpoint"`.
  Keep both the mount and variable exclusive to `joe-household-v2-stage`;
  do not add them to `joe-board-pusher` or place the checkpoint under its
  `/var/lib/joe-board-pusher` mount. The lock-holding child receives this variable
  through the launcher's explicit environment allowlist.

It is outside `v2/`, whose unknown-entry checks in previous releases remain
unchanged; rollback ignores the cache and can append receipts normally. A later
forward start validates those appends as tail rows. Rolling back the mount/env
configuration leaves this worker safe with checkpoints disabled; rolling back
the worker leaves the isolated cache unused. No allocator format change is
required. Recovery tests execute the supplied
previous-main worker and the pinned r15 recovery code against new state.

Once ready, the supervisor emits only `{event:"v2_stage_ready",startupMs,
rowsScanned,scanMode}` (`full` or `tail`); row counts include the single boundary
row checked on a nonempty prefix. Startup expiry uses `worker_startup_timeout`;
per-job expiry remains `worker_timeout`. Startup timing covers worker launch
through readiness and carries no receipt or payload values.

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
17 files directly against JoeDesk 36fecfeb7e56400db3076304d150e9eeb2beb05b
(set c266b39e33e6e15be491263b0ca3575598dd264da3e1a9f6d5a147fc9f1bd49b). The pusher-local
verifier exports a fixed-path `verify()`; `node verify-contracts-entry.mjs`
is the unconditional Docker build entry. It is tested on valid and damaged rev 11 closures. Linux
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

`image-import-closure.test.mjs` runs through that same CI discovery path. It
parses every Dockerfile COPY, follows relative imports, re-exports and literal
dynamic imports from all Node entrypoints, and checks the executor's declared
mounted source separately. Missing modules are named; removing
`executor-attribution.mjs` from COPY reproduces the pre-fix failure. The masked
705 inventory fixture covers 30 fills: j5 ×10 and j2 ×6 roll up to J ×16 with
each internal `subDesk` retained, while joe ×14 stays Joe. Duplicate order keys
and unknown intent desks fail closed; unknown-desk events contain only the desk
token and fixed cause.

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
dropped financial callbacks keep arriving. Otherwise, the supervisor sends a
read-only current-time probe every 20 seconds even while other callbacks arrive.
The unchanged 15-second response deadline is shorter than that interval. Only
`currentTime` satisfies it; unrelated activity cannot hide a missing reply.
One probe stays in flight; a timeout retires its generation through the existing
retry path before the next probe can run. Shutdown cancels every connection, snapshot,
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

JOED-100 bounds the capture metadata in `family-history.json`. On every save,
overlapping or contiguous KNOWN receipts are coalesced, retaining the latest
original receipt for exact replay/source-reuse checks. A digest
and observation count replace the old capture provenance; historical source IDs are
no longer an exhaustive replay index. Membership lists are deduplicated by execution
and commission ID. Legacy digest-only receipts remain digest-only, with aggregate
observation counts; compaction never invents their missing memberships. Every raw
execution revision, orphan commission, account/classifier binding and economic
observation time stays intact. No KNOWN receipt becomes COMPLETE.

Compaction leaves every COMPLETE receipt untouched, including its ID, authority,
membership, window and observation time, as well as truncated replies and legacy
memberships.
This preserves official-chain recovery, midnight imports and desk-boundary checks.
Distinct coverage/proof boundaries still require storage; redundant polling does
not add KNOWN receipt history. Saved coverage keeps exhaustive `receiptIds` lists;
readers also accept the compact reference format. Only the in-memory projection's
diagnostic references keep at most the first/last IDs, with `receiptCount` and
`receiptIdsSha256` when there are more than two. These references are not membership
proofs.

CLI stdout contains exactly one JSON summary; compaction and size-warning events
go to stderr. Preview reports the post-compaction receipt count and IDs that an
import would save, without writing the state file.
CLI imports report receipt IDs from the saved file. If compaction absorbed an
imported KNOWN receipt, its `importedReceiptId` list is empty. Re-importing an older
KNOWN source after its binding was merged can still add a receipt and extend the
target; exact historical source replay/reuse checks require provenance the bounded
compacted state no longer retains. Retained original receipts and conflicting
execution/commission facts still fail closed as before.

Load compacts files at **16 MiB** or more, before accepting their state. A separate
**64 MiB** recovery-read ceiling permits an existing file above the write cap to
self-heal; an irreducible state above **32 MiB** remains unavailable. The next
successful capture persists the repaired state and advances its target even when
the broker returns no new executions or commissions. Callers adopt the saved
compacted snapshot in memory. Writes retain the **32 MiB** hard cap and the existing
exclusive temporary file, mode 0600, file fsync, atomic rename and directory fsync.
No manual move-aside is required. `family_history_compacted` logs only before/after
byte counts on a compacted load, or a save that compacts and reduces the last
read/written file by at least **1 MiB** or **10%**. Save measures the single serialized
write body. `family_history_size_warning` logs only byte counts if more than **24 MiB**
remains after compaction. Schema/version and executor coverage/record semantics
remain unchanged. Compacted files remain readable by the previous release, so
rollback needs no history-file migration. Compaction cannot close an actual
historical completeness gap.

The offline regression fixture builds **127,058** real-writer receipts over 50 days
at 34-second intervals, with 100 execution/commission records. It reduces
**166,792,900 B → 190,644 B**, preserving the executor-visible fields. Receipts
dominate the original size (148,181,383 B as a standalone pretty-printed array),
followed by repeated coverage references (9,663,600 B); execution/commission arrays
are only 36,903/11,053 B. A **34,104,001 B** on-disk fixture recovers and saves as
**45,209 B** after its next update. These are synthetic measurements, not live-host
verification. Run `node --test history-compaction.test.mjs` to reproduce them.

The sibling `family-ledger.json` keeps deduplicated execution/commission rows and
the current query identity set, replacing its scalar coverage timestamps; its cap
is **16 MiB**, not 32 MiB. Executor attribution memory is keyed by
account/client/exec ID, retaining one proof and at most one conflict per key, under
**100,000 entries / 32 MiB**. Neither appends a receipt per capture, so unchanged
replays have no time-to-cap. Growth depends on new identities/record sizes: at 100
new attribution identities per day, the entry ceiling is at most 1,000 days from
empty (the byte ceiling can arrive first). A calendar estimate for either sibling
needs an observed new-fill rate; repeated capture cadence alone cannot supply it.

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

OPS-557 adds `fillAttributionOverrides` to the canonical ownership policy. An
override matches only its exact `execId`, before executor/clientId assignment;
an absent or unknown execution identity never claims another fill. Complete
J/all-desk accounting, revision and day-boundary sources require **exactly one
effective fill per override**. Missing, corrected-away or duplicate matches
fail closed before monetary output, including independently exact desk output.
Errors name only `fillAttributionOverrides[index]`, the rule's policy-array key;
all-desk keys use canonical execution-ID order. They never include broker or
economic values. Day-only activity and partial captured-history views are not
complete accounting sources and cannot establish this cardinality proof.
Each entry records its desk, basis and decision date. The reviewed corrections are:

| Exact execution ID        | Desk | Fill                                                         |
| ------------------------- | ---- | ------------------------------------------------------------ |
| `0000dc8f.6bb0d852.01.01` | J    | 2026-09-23 13:30:04Z, client 119, SELL 4 NVDA, conId 4815747 |
| `0000dc8f.6bd3bc59.01.01` | J    | 2026-10-06 13:40:47Z, client 229, BUY 1 NVDA, conId 4815747  |
| `00025b45.6ace1f95.01.01` | Joe  | 2026-10-12 19:50:12Z, client 28, BUY 4 NVDA, conId 4815747   |

All three carry basis `OPS-557 cross-booked NVDA close, 2026-11-04` and date
`2026-11-04`. ClientId assignments, KEEP exclusions, the retained family
classifier and raw broker captures stay unchanged. The same exact-fill
supplement feeds J FIFO, fee/FX readiness, captured history, activity and flat-net
mark selection, so J agrees with all-desk accounting. J and Joe both finish flat
on NVDA (`conId 4815747`), matching the account; no residual NVDA mark is needed.
The six-fill `fixtures/ops557-nvda.json` is a small synthetic regression fixture,
not a copied live history. Counterpart execution IDs and economic inputs absent
from the brief are synthetic.
The legacy-route entry remains an explicit exact-fill guard even though OPS-392
already assigns that fill to J. Its cardinality must still hold; retaining the
guard preserves the reviewed policy digest and history basis.

OPS-557 also publishes `historyBasis` on J and Joe from the first snapshot:
`desk-policy-` plus the first 12 **lowercase** hex characters of the canonical
ownership-policy SHA-256 (with OPS-567, `desk-policy-a7b2b7316e31`). It is carried
through the v1 projection and v2 observation, committed pair and publisher,
including when money is unavailable. It stays stable across restarts, market
updates and history revisions; only an ownership-policy change changes it.
The board cuts those two series and labels "bookkeeping basis changed" rather
than plotting the correction as investment performance. The field meets
`data.schema.json`'s `^[a-z][a-z0-9.-]*$` pattern and 96-character limit.
Joel receives no policy basis: v2 continues to omit its field, while v1 retains
its existing `joel.stage0-keep-excluded.v1` basis. All other Joel output is
unchanged. Recovery accepts retained pairs without the new field and preserves
their exact bytes; new pairs keep their recorded basis across restart.

The complete override set (identities, desks, basis and dates) binds both the
ownership-policy hash and `historyRevision`. The live pre-OPS-557/OPS-567 hash is
`c32cde7929bf505ce75e8f76fa8c81268d5aef3446927653dfe857796e86a025`.
OPS-567 also extends the hashed executor rollup table. The combined policy hash
is `a7b2b7316e318e78727095d9178df156d5f84a55b7ca801dc9a9aabb12f2591d`;
the earlier OPS-557-only basis `desk-policy-b5a60129aec4` is historical.
Removing only the fill overrides while keeping the extended rollup yields
`0f9071ea04830168c6b83acd61a9bc0a74553d40ec5fd5216dfac4564d8dd877`,
which is the gate's before-override comparison, not a live rollback policy.
The live pre-change policy's day-baseline file is retired from active use and
preserved byte-for-byte for rollback. The corrected policy selects a fresh file automatically. The
pusher now passes `allowSessionProxy: false`: Today/DAY stays unavailable/null
on the cutover day, including across restart, while corrected complete equity
continues to be persisted and displayed. At the next America/New_York
`periodStart`, a fresh pre-boundary vector plus unchanged authoritative history
and continuous coverage may establish exact SOD. Midnight alone is insufficient;
without those proofs Today stays unavailable. No prior-policy baseline is reused,
no same-day zero proxy is invented, and no retained state file is deleted.
The older R14/R15 session-proxy notes below describe the prior runtime policy;
the adapter retains that optional mode for callers that explicitly allow it.

#### OPS-557 pre-deploy replay gate

**Required before the 2026-11-10 deployment (22:25–22:40 Europe/Vienna):**
take **fresh, consistent copies on deploy day** of `family-history.json`,
`/var/lib/paper-desk-executor/ledger.json`,
`executor-attribution-memory.json` and `family-ledger.json`. Keep the private
copies outside Git and record their capture time privately. Re-take and re-run
if those inputs change before activation. Earlier ticket replays and synthetic tests do not satisfy
this gate. From this reviewed checkout, run offline against the four copies;
`--deploy-date` is the intended activation instant with an explicit timezone:

```bash
node replay-ops557.mjs --deploy-date 2026-11-10T21:25:00Z /private/deploy-day/family-history.json /private/deploy-day/ledger.json /private/deploy-day/executor-attribution-memory.json /private/deploy-day/family-ledger.json
```

Every line must say `PASS` and the exit status must be zero. Required evidence:

- Each `override[index] matches count=1` and `override[index] README fill`
  passes: exactly one effective fill matches the table's conId **4815747**,
  symbol, client, side, quantity and UTC time. Corrected-away identities fail.
  The same checks must pass with the `ledger raw` and `ledger merged` prefixes:
  the raw family ledger must contain exactly one copy, and correction merge
  plus KEEP filtering must retain it. Deduplication cannot hide an extra copy.
- `PASS history freshness` and `PASS family ledger freshness`: history
  `updatedAt` and family-ledger `coverageThrough` must each fall within the
  **60 minutes ending at `--deploy-date`**, inclusive. Missing/invalid clocks,
  older copies and clocks after that instant fail. The bound is enforced from
  source timestamps, not copy mtimes. `ledgerObservedAt` can stay old when no
  fills change; `coverageThrough` is the execution-query freshness clock.
  This bound checks those two source clocks; capture the executor ledger and
  memory together with these copies. A later activation needs a new deployment
  instant and fresh replay, even if the earlier run passed.
- `PASS J NVDA before=+8`, then `PASS J NVDA after=0` and
  `PASS Joe NVDA after=0`: the explicit **+8 → 0 on J** expectation.
- `PASS other-symbol lots unchanged count=...` and
  `PASS other-symbol realised unchanged count=...` across J, Joe and Joel.
  The gate compares each instrument's owned FIFO inputs/fees, ending quantity
  and realised result, including flat instruments; KEEP remains excluded.
- `PASS FIFO replay` and `PASS OPS-557 deploy gate`.

The script reads all four files without modifying them, resolves executor
ownership with the executor ledger and attribution memory, and runs the
production FIFO before and after the fill overrides. The J-family rollup is the
same in both comparisons. The complete raw family ledger supplies `executionRows`, exactly
as production does: it retains the `orderRef` evidence needed to prove flat
OPS-test exclusions, which normalized history intentionally omits. History
supplies the economic FIFO and commission comparison. It uses internal neutral
marks and FX solely for a deterministic economic comparison; it does not attest
current market valuation. Output is value-free: fixed check names, counts and
PASS/FAIL, with only the required
NVDA +8/0 lot quantities. It never prints prices, monetary results, input
identities or exception text. A missing input, unclaimed fill or failed replay
also fails the gate. **Any FAIL or nonzero exit = do not deploy.** Save the
value-free output as deploy evidence. This offline builder session has no fresh
host copies; the live gate remains a deployment prerequisite.

#### OPS-557 rollback to the pre-change image

The rollback target is JOED-149 (#1224), merge
`84ae0f6219eb36784376c8d49fde7b797d9a2005`, image
`household-v2-switch-set-r21-202611031258`, configured contract revision 11.
It is scheduled to activate in the 2026-11-09 23:20–2026-11-10 01:00
Europe/Vienna window, before the OPS-557/OPS-567 deployment on 2026-11-10
22:25–22:40 Europe/Vienna. Confirm it is the actual pre-switch image.
This worker rejects `desks[].historyBasis` on rev-9, rev-10 and rev-11 pairs.
Its handoff parser also rejects new observations carrying the basis. Keeping this required board
metadata therefore requires an archive/move-aside for rollback; a mixed
pusher/stager generation is not supported. Without it, recovery reports
`stage_storage_invalid` and the old publisher cannot send the committed pair.

**Desk-money limit:** after OPS-567 records any `j3` or `j4` proof in
`executor-attribution-memory.json`, r21's old rollup validator rejects the
**whole memory file**, including otherwise compatible proofs. Its executor
attribution then fails closed and J/all-desk money is unavailable. A fresh
published sequence alone does not prove desk-money recovery. Make no manual
edits to the memory file: never delete, trim, rewrite or restore an older copy
to make r21 accept it (the worker itself may still add new proofs). The recovery path for this case is to **roll forward**
to the reviewed OPS-557/OPS-567 runtime with the preserved memory. Even without
a saved proof, r21 cannot attribute a live `j3`/`j4` intent.

This is a coordinator-operated rollback procedure, not automatic cleanup:

1. Stop `joe-board-pusher` first, then `joe-household-v2-stage`, and verify both
   are stopped and no writer holds the allocator lock. Keep the board and its
   current contract revision. Prepare the approved rollback image for both
   services together; do not run an old stager alongside the new pusher.
2. Create a new mode-0700 sibling archive at
   `/var/lib/joe-board-pusher/rollback-ops557-<UTC>/`, **outside**
   `/var/lib/joe-board-pusher/v2/`. Preserve ownership and modes. Copy
   `/var/lib/joe-board-pusher/v1-cycles/` there before reconnect pruning can
   remove old bodies. Also copy `v2-post-state.json` and its `.tmp` sibling
   when present, plus `v2/sequence-state.json` and `v2/receipts.jsonl` for
   comparison. Record the `.allocator.lock` inode and saved sequence/time
   high-water. Leave the original cursor, pending POST, baseline files, family
   ledger/history, `executor-attribution-memory.json` and checkpoint directory
   untouched. Also copy the attribution memory into the archive as evidence;
   make no manual edits, trims or restores to the live original through rollback
   and roll-forward (a running worker with `remember: true` legitimately writes
   new proofs).
3. Move `/var/lib/joe-board-pusher/v2/current.json`, when present, into the
   archive first. Then move **every** `v2/pair-<seq>/` directory into the same
   archive, including compatible older pairs. Moving the pointer alone fails:
   the old worker validates retained pairs too. Leave `v2/.allocator.lock`,
   `v2/sequence-state.json` and `v2/receipts.jsonl` in place. Never re-enroll,
   reset the sequence, edit a pair, or delete receipts. If any other v2 entry
   exists (including crash residue), stop this procedure for coordinated
   recovery; do not guess at or delete it.
4. Verify the v2 directory contains exactly those three preserved files;
   compare allocator/log bytes and lock inode with step 2. Verify the archived
   pointer, all snapshot/receipt bytes and copied v1 bodies match the original
   evidence. The archive must remain outside the worker's scanned directory.
5. Start the matched rollback stager, then rollback pusher. Verify recovery
   succeeds with no current/retained pair and the saved high-water intact.
   The next healthy IB cycle must commit a sequence **above** that high-water,
   append to the existing receipt log, and publish successfully using the
   preserved posting state. Verify the board becomes fresh and check J and
   all-desk money for availability/reconciliation in the new published snapshot,
   with value-free evidence. If money is null/unavailable because the old worker
   rejects a j3/j4 proof, the sequence check is only transport recovery: preserve
   the memory and coordinate roll-forward; do not declare money recovered.
   Neither process startup nor a missing storage error alone proves recovery.
   Preserve the archive after pruning and do not reset the board or POST cursor.

**Roll-forward** is the activation procedure again, not a separate path: copy
fresh deploy-day inputs, re-run the
[pre-deploy replay gate](#ops-557-pre-deploy-replay-gate) with a **new**
`--deploy-date` (the new activation instant; the 60-minute freshness window
applies again) and require every PASS, then switch to the reviewed
OPS-557/OPS-567 runtime with the preserved attribution memory and run the same
live checks. Desk-money recovery is proven only by the next published snapshot
in which desk J's `desks[].pnlSources.open.status` is `available` (and
`pnlSources.day.status` once its SOD proof exists) and the all-desk aggregates
are no longer withheld; record that as value-free evidence. A fresh sequence
alone is transport recovery only.

When attribution remains compatible, rollback restores pre-fix ownership and
removes J/Joe's policy basis, causing another board series cut. The old policy's
own preserved baseline is selected again; it must never be copied into the
corrected policy's file.
`v2-rollback.test.mjs` loads the actual base-commit runtime/contract closure and
pins rejection, pointer-only failure, evidence preservation, monotonic recovery
and successful old-worker publication for all three supported contract revisions.
Its rev-11 case also pins whole-file rejection of a j3 proof, loss of an otherwise
valid Joe proof, unchanged memory bytes and successful attribution on roll-forward.

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

OPS-555 remains open: a marked flat-account cross-desk close can currently
leave opposite virtual lots while both desks report reconciled. The synthetic
`desk-ledger.test.mjs` reproduction opens ACME on client 27 and closes it on
client 22: an explicit flat-net mark permits J +1 / Joe -1; assigning the exact
close to J makes both flat. Missing marks fail loud, but supplying a mark does
not detect this ownership error.

An unclaimed non-KEEP executor fill blocks the **whole all-desk calculation**;
it is never silently skipped or isolated to one desk. `executor-attribution.mjs`
throws during ownership classification, and `calculateDeskEquities` in
`desk-ledger.mjs` returns `ok:false` without desk money. The proven, flat
`ops_test` exclusion is the explicit exception.

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
The candidate image is `household-v2-switch-set-r17c-202610202345`; the retained
rollback image is `household-v2-switch-set-r16d-202610201800`.

R15 attributes executor-route executions through the executor's own intent
ledger. The pusher mounts `/var/lib/paper-desk-executor` read-only at the same
path and reads a bounded snapshot of `ledger.json` on completed execution
cycles. `JOE_EXECUTOR_CLIENT_IDS` comes from the executor's declared `clientIds`
(currently 700 and 705). Those clients bypass static assignments and require
exactly one intent owning the `(clientId, orderId)` pair: a place intent's
`result.bracket` records its client plus parent/stop order IDs, and a flatten
intent's `result.flattened` records the submitted client/order pairs. Cancel,
modify-stop and recon records do not create ownership. Multiple matching
intents fail closed even if they name the same desk.

For retained economic captures without routing fields, an exact execution-ID,
client and account match in the executor ledger's `executions` must first
recover one unambiguous order ID. Missing ledger data, missing keys, no intent,
duplicate intents or conflicting execution identities leave the execution
unclaimed. Markus's 2026-09-10 decision rolls the entire J family
(J, J2, J3, J4, J5) into J. OPS-567 completes the explicit intent-desk table:
`j → j`, `j2 → j`, `j3 → j`, `j4 → j`, `j5 → j`, `joe → joe`, `joel → joel`;
no prefix parsing or orderRef inference is used. The attributed execution keeps
the original intent desk as internal `subDesk`, including `j2`–`j5`, and history
evidence retains that distinction. Rev 9 output
has no sub-desk field. Any other intent desk stays unclaimed and emits
`executor_intent_desk_unclaimed` with only `cause:intent_desk_invalid` and the
desk token (`null` for a missing/non-string desk), never account, order,
execution or financial values. Pruned intent evidence without a previously saved
exact proof remains unavailable.

The same resolver feeds J FIFO/history/fee/FX/flat-net evidence, all-desk equity,
and v2 execution/open-order activity. Joel is valued from its proven executions
when present. KEEP SXR8/TSLA is excluded before matching; 229 and every dated or
static assignment keep their boundaries. The executor's trading authority and
source are unchanged. `v2_desk_state` adds only per-executor-client matched and
unmatched execution counts when available; it exposes no ledger identities.
The intent attribution method and explicit table bind the policy hash and select a fresh
policy-keyed baseline while preserving every old baseline and capture. R15
rollback uses `household-v2-switch-set-r14-202610201330`; the earlier R14 notes remain
historical rollout evidence.

### Exact attribution memory and retention recovery (JOED-62)

The executor prunes finished intents after 14 days; the pusher retains execution
history indefinitely. Without a saved proof, each pruned intent turns its fills
into `intent_unmatched`, making all-desk equity unavailable and desk states
`stuck`. The pusher now owns
`/var/lib/joe-board-pusher/executor-attribution-memory.json`. Its schema is
`inspr.joe.executor-attribution-memory.v1`, with the configured `account`, an
`entries` object keyed by JSON `[account, clientId, execId]`, and a `conflicts`
list of quarantined keys. Each entry contains only `clientId`, `execId`,
`orderId`, `desk`, `subDesk`, `provenAt` (UTC ISO time), and `source` (`intent`
or `seed`). No prices, quantities or orderRefs are stored.

Every successful exact execution-to-intent join records its proof before claiming
the fill. Live exact intent matches remain first. Only `intent_unmatched` may
fall back to memory, and only for the same account, client, execution and order
ID; the result carries `cause:remembered` and the original desk/subDesk. A
retained row missing its order ID still needs the executor's exact unambiguous
execution identity to recover that key. Other failure causes retain priority.
This persists an earlier exact fact; no orderRef or desk inference is allowed.
Open-order rows have no execution identity and are never recorded. OPS-test
exceptions and remembered hits never create or renew a proof. KEEP and
non-executor ownership policies are unchanged.

The memory is created with mode 0600, written through an exclusive temporary
file, file fsync, atomic rename and directory fsync. Reads use `O_NOFOLLOW`,
reject non-regular files, and enforce both **100,000 entries** and **32 MiB**.
An absent file starts empty; a corrupt, incompatible, wrong-account or oversized
file fails closed and is never silently reset or pruned. A different desk,
subDesk or order for an existing execution preserves the original entry and
durably quarantines that key: it stays unclaimed as `memory_conflict`, including
after restart/pruning, with only a value-free conflict event. Persistence
failures leave attribution unavailable. A sibling `.lock` serializes pusher and
seed writes; contention fails closed for that reader, retried on the next
execution snapshot. A crash lock is never stolen automatically; OPS must verify
that no writer is running before moving aside its own stale lock. Preserve the
memory with the other pusher state across switches and rollbacks.

For fills already orphaned by pruning, OPS can copy an executor ledger snapshot
from a **pre-prune backup** into `/dev/shm/recovery` in the pusher container.
This is the preferred transport: tmpfs, gone on container stop. A private
recovery directory mounted read-only at `/recovery` during its reviewed
promotion is also supported. Do not replace the live executor ledger. After the new image is
integrated and the read-only snapshot is available inside the container, run:

```sh
docker exec <pusher> node /app/seed-attribution-memory.mjs /dev/shm/recovery/executor-ledger.json
docker exec <pusher> node /app/diag-executor-unclaimed.mjs
```

The seed accepts only absolute snapshot paths strictly below `/dev/shm/recovery/`,
`/tmp/recovery/` or `/recovery/` after path resolution. Root directories themselves, sibling
prefixes, paths escaping those roots, relative paths and snapshot symlinks are
rejected before seeding. The seed is read-only with respect to both input
ledgers and the backup. It requires `barta.paper-desk-executor-state.v1` and the
same configured `IB_DESK_ACCOUNT`, uses the pusher's validated family ledger
and exact matcher, and writes only attribution memory (`source:seed`). It adds missing proofs in
one transaction, preserves existing proof times/sources, and is idempotent.
It prints only `{seeded,alreadyPresent,conflicts,unmatched}`; input failures
produce fixed value-free JSON and a nonzero exit. `unmatched` counts configured
non-KEEP executor fills without an exact snapshot proof, including OPS tests;
it does not assign them. Conflicts quarantine the existing key without replacing
its proof. A contended write can be rerun safely. No broker/API requests, orders,
family-ledger changes or executor-ledger changes occur. Verify `remembered`
increases, `intent_unmatched` clears for the restored fills, and
`memory_conflict` remains zero. OPS owns the backup selection and release pins.

Amy approved the OPS bring-up test exception on **2026-10-21 (JOED-39)**.
Only a configured executor client's `intent_unmatched` fill can qualify. Its
original `execution.orderRef` must contain a whole, case-sensitive `|`-delimited
token matching `^ops-test(?:-[a-z0-9]+)*$`: `ops-test`, `ops-test-ko`, or e.g.
`ops-test-round-trip-2`. Substrings, other separators, whitespace, uppercase,
and empty suffix segments do not match. The marker never identifies a desk;
an exact client/order intent match always wins, and every other failure cause
keeps its existing meaning.

Each candidate's original time must parse through `executionTime` and round-trip
as a real civil time in its stated IANA zone or ISO offset. Rolled dates (30 Feb,
non-leap 29 Feb, 31 Apr), hour 24, ambiguous/gap local times and invalid offsets
stay `intent_unmatched`. This check precedes economic normalization, which can
discard routing fields or roll ISO dates. Retained rows recover an exception
only through the same exact execution/client/account/order identity and matching
time, signed quantity and price from the raw snapshot.

The complete family-ledger snapshot supplies all candidates across configured
executor clients. Latest IB corrections and duplicate replays use the family
ledger's merge rules; flatness uses its instrument key (`conId`, otherwise
STK/symbol/currency), signed side and 1e-9 quantity tolerance. Each instrument
must net flat independently. A flat set becomes `ops_test`, with no desk, desk
money, desk fees, history economics or activity; it contributes no unclaimed
executions. Non-flat sets stay unclaimed with `ops_test_not_flat` and still null
the all-desk totals. KEEP SXR8/TSLA and non-executor clients keep their policies;
raw captures, account replay, official coverage and receipt checks stay intact.
Missing/conflicting snapshots grant no exception. No pre-ledger/cutoff exception
is implemented.

Internal valuation diagnostics carry `opsTestExecutionCount`, and per-client
counts carry `opsTest` separately from `matched`/`unmatched`. Each snapshot with
excluded test fills emits one value-free `{event:"executor_ops_test",count}`
event. These diagnostics do not extend `ownershipEvidence`, the exact-key
provider contract, JoeDesk rev 9 output or frozen r15 fixtures.

After OPS integrates this proposal into the image, the read-only diagnostic is:

```sh
docker exec <pusher> node /app/diag-executor-unclaimed.mjs
```

It uses the same executor-ledger reader, `IB_DESK_ACCOUNT`,
`JOE_EXECUTOR_CLIENT_IDS`, and family-state loader as the pusher, reading
`/var/lib/paper-desk-executor/ledger.json` and
`/var/lib/joe-board-pusher/family-ledger.json`. It makes no broker/API requests
and writes neither input. One JSON object contains `ok`, `causes` (each cause's
`count`, `first`, `last` ISO time; null bounds when absent/unparseable), and
`instrumentsNotFlat` (a count). Causes include `matched`, `ops_test`,
`ops_test_not_flat`, `intent_unmatched`, `remembered`, `memory_conflict` and all
existing attribution failures. The diagnostic also reads attribution memory
without creating or changing it, including when live exact matches are present.
KEEP and non-executor rows are excluded. Events are suppressed; symbols,
financial values, account/order/execution/intent identities and orderRefs are
never printed, including on input failures. OPS should confirm exactly two
`ops_test` rows, first `2026-10-06T18:16:10.000Z`, last
`2026-10-06T19:10:30.000Z`, and zero instruments not flat after the switch.

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
