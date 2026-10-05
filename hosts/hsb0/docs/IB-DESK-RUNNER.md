# hsb0 paper desk runner

The durable desk path is an outbound-only pull runner on hsb0. Amy-box submits
authenticated intents as issues in the private
`markus-barta/oc-workspace-shared` repository; hsb0 polls GitHub once a minute,
executes locally against `100.64.0.6:4002`, then comments the result and closes
the issue. It opens no inbound port, needs no Amy-box Tailscale state, and never
uses a Mac.

HostDash remains display-only. The existing joe-board-pusher still publishes
the book to `https://cs0.barta.cm/joe/`; neither its behavior nor image pin is
changed. GitHub Issues is used for commands because it already supplies private
authenticated ingress, actor identity, timestamps, and an audit trail without
adding an hsb0 or cs0 API.

## Client contract

The queue repository must remain private. Only issues authored by
`markus-barta` with owner/member/collaborator association and the
`hsb0-paper-intent` label are accepted. The body is exactly one JSON object
(a fenced `json` block is also accepted):

```json
{
  "schema": "barta.paper-desk-intent.v1",
  "intentId": "j-20261005T193500Z-aapl-01",
  "desk": "j",
  "action": "place",
  "createdAt": "2026-10-05T19:35:00Z",
  "expiresAt": "2026-10-05T19:45:00Z",
  "order": {
    "symbol": "AAPL",
    "side": "BUY",
    "quantity": 2,
    "limitPrice": 250.0,
    "stopPrice": 248.75,
    "currency": "USD"
  }
}
```

`desk` is one of `j`, `j5`, `joe`, or `joel`. `action` is `recon`, `place`, or
`flatten`. Recon and flatten omit `order`. Intents expire after at most 15
minutes. `intentId` is the durable idempotency key: identical replays return the
stored result and changed content under a used ID is rejected. A crash after a
claim never automatically replays an order; the result becomes uncertain and a
fresh recon is required.

Create an intent from Amy-box, where `gh` is already authenticated:

```bash
gh issue create \
  --repo markus-barta/oc-workspace-shared \
  --label hsb0-paper-intent \
  --title "[hsb0 paper] j recon j-20261005T193500Z-recon-01" \
  --body-file /path/to/intent.json
```

A recon body is:

```json
{
  "schema": "barta.paper-desk-intent.v1",
  "intentId": "j-20261005T193500Z-recon-01",
  "desk": "j",
  "action": "recon",
  "createdAt": "2026-10-05T19:35:00Z",
  "expiresAt": "2026-10-05T19:45:00Z"
}
```

The result comment contains fresh Gateway status, the exact paper account,
positions, and open orders. Read it without any hsb0 network route:

```bash
gh issue view ISSUE_NUMBER \
  --repo markus-barta/oc-workspace-shared \
  --comments --json state,comments
```

An owned-flatten request changes only `action` to `flatten`. Flatten cancels
orders by each order's placing client ID and submits offsets for positions
derived from the durable execution/client-ID ledger. It never performs an
account-wide cancel. `SXR8`, `TSLA`, unclaimed positions, and other desks'
client IDs are excluded. The declarative `joel-ib-paper-flatten-own.timer`
runs the same owned logic for the legacy J family at 21:50 Vienna, Monday to
Friday; the old `J_OWN_FLAT=AAPL,NVDA` symbol list is gone.

## Host-side brakes

The hsb0 runner, not the submitting desk, enforces all of these before calling
IB:

- exact account `DUR970597`, host `100.64.0.6`, and paper port `4002`; any other
  account, host, or port is refused;
- only resolved IB stock types `COMMON` and `ADR`; ETFs and ambiguous contracts
  fail closed;
- protective parent-limit plus child-stop bracket, with the stop at least 0.5%
  from entry;
- per-name risk at most EUR 25, daily reserved risk at most EUR 50, notional at
  most EUR 1,000, at most two new orders per New York day, and at most three
  concurrent non-KEEP names account-wide;
- USD-only Stage-0 names, converted with a fresh IB account USD-to-EUR rate
  (EUR base must be proven) plus a 2% safety buffer;
- no piling into a symbol with an existing position or working order;
- no new order on the ledger's first New York day, because activity before the
  deployment baseline cannot prove the daily risk/new-order budget;
- `SXR8` and `TSLA` are immutable KEEP exclusions in both Nix assertions and
  runtime policy.

A non-empty local `/var/lib/ib-desk-runner/HALT` or non-empty open issue with
label `hsb0-paper-halt` refuses all new `place` actions. Recon and owned flatten
remain available. Closing the halt issue clears the remote flag; emptying the
local file clears the local flag. Every claim and result is fsync'd to
`/var/lib/ib-desk-runner/audit.jsonl`, while the private GitHub issue and result
comment provide the remote audit trail.

## Dry run

The pure policy dry run never connects to IB or GitHub:

```bash
node modules/ib-desk-runner/dry-run.mjs \
  /path/to/intent.json /path/to/snapshot.json /path/to/state.json
```

The snapshot JSON has `stockType`, `usdToEur`, `positions`, and `openOrders`; the optional
state has a `placements` array. The CI gate runs the focused policy suite plus
static checks for paper-only wiring, KEEP, HALT, the declarative timer, and the
absence of account-wide cancellation.

## Failure posture

GitHub unavailable means no intent is executed. Missing/corrupt ownership
history means no flatten is executed. Missing token means the poll service is
condition-gated and does not start. A placement that might have crossed the
IB boundary is marked uncertain and consumes its risk/new-order reservation;
operators must request recon rather than reuse its intent ID.
