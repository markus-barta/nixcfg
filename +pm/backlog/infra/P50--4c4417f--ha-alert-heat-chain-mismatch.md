# NR: Heat-Chain Self-Heal + Telegram Alert

**Priority**: P50
**Status**: Backlog
**Created**: 2026-02-24
**Updated**: 2026-02-24

---

## Problem

Node-RED checks the floor heating chain every 5 min and publishes state to `jhw2211/health/heat-chain`. The Pixoo64 renders it visually — but there is no self-heal and no notification. Two mismatch cases are dangerous:

- **Case A:** Tado input=OFF, 4PM output=ON → runaway heating, overheating risk
- **Case B:** Tado input=ON, 4PM output=OFF → no heating when expected

Neither is auto-corrected. If no one is watching the Pixoo, it goes unnoticed.

### Root cause: 4PM MQTT is broken (silent failure)

`MQTT.GetStatus` reports `connected: true` — but the Pro 4PM (`192.168.1.169`) never actually publishes anything. Zero messages appear in the mosquitto log. This is a known Gen2 firmware issue where the broker handshake succeeds but status notifications silently fail.

**Consequence:** `flow.vr_4pm_output` in the heat-chain flow is always `undefined` → the check always evaluates to `state: unknown` → **the check never actually fires**. The existing NR flow is broken by this MQTT failure.

**Fix:** Replace MQTT-based 4PM state with a live HTTP RPC poll at check time. HTTP RPC is confirmed working (`Switch.GetStatus?id=0` returns correct state). This also eliminates the race condition between MQTT arrival time and the 5-min inject timer.

---

## Solution

Extend the existing NR heat-chain flow (`992d23c856b48610`) — no HA changes needed.

**Step 1 — Get ground truth via RPC (not MQTT):**
At each 5-min cycle, HTTP GET `http://192.168.1.169/rpc/Switch.GetStatus?id=0` → read `output` field. Use this as `vr_4pm_output`. Keep the MQTT listener as a fallback/bonus but do not rely on it.

**Step 2 — Check + self-heal:**
Compare live RPC result against `flow.wc_tado_input` (still from MQTT — Tado bridge works fine):

- Mismatch → HTTP GET `Switch.Set?id=0&on=<true|false>` to correct the 4PM output
- Wait 30s → re-check via `Switch.GetStatus?id=0`

**Step 3 — Telegram notification (mba only, via `GLOBAL_TELEGRAM_SEND++` → Apprise):**

- Self-heal succeeded → single Telegram: "🔧 FBH-WC korrigiert: Tado=X, 4PM war Y → auf Z gesetzt"
- Self-heal failed (still mismatch after re-check) → Telegram every cycle until resolved
- State returns to ok (and `heatChainAlerted` was true) → single Telegram: "✅ FBH-WC wieder OK"
- No spam when healthy: use `flow.heatChainAlerted` flag to suppress

---

## Implementation

### Pre-work (you, in NR UI)

- [ ] **Backup flows:** Export current tab `992d23c856b48610` as JSON (NR UI → hamburger → Export → current tab → download)
- [ ] **Rename tab** "Flow 2" → "FBH-WC Health" for clarity

### Changes to existing nodes (you, guided by spec below)

- [ ] **Remove** `health-chain-4pm-store` function node (stores MQTT value we can't trust)
- [ ] **Remove** `health-chain-4pm-in` MQTT-in node (4PM MQTT broken — not reliable)
- [ ] **Modify** `health-chain-fn` (check heat chain): replace `flow.get('vr_4pm_output')` with live RPC call to `http://192.168.1.169/rpc/Switch.GetStatus?id=0` — function node becomes async

### New nodes to add (you, guided by spec below)

- [ ] **http request** node: `Switch.Set` call (for self-heal)
- [ ] **delay** node: 30s pause before re-check
- [ ] **http request** node: `Switch.GetStatus` re-check
- [ ] **function** node: evaluate re-check result → decide notification path
- [ ] **function** node: build Telegram message payload
- [ ] **link out** node → route to `GLOBAL_TELEGRAM_SEND++` (tab `1447a865fe7913ee`, node `d73b29d592e47d92`)

### Testing (you)

- [ ] Test A: manually set 4PM ON via RPC while Tado=OFF → verify self-heal triggers + Telegram received
- [ ] Test B: manually set 4PM OFF via RPC while Tado=ON → verify self-heal triggers + Telegram received
- [ ] Test C: make RPC unreachable (disconnect 4PM from network) → verify repeat Telegram every cycle
- [ ] Test D: let system run 1 full cycle after fix → verify `jhw2211/health/heat-chain` publishes `state: ok`

---

## Acceptance Criteria

- [ ] `jhw2211/health/heat-chain` publishes `state: ok` or `mismatch` (never stuck on `unknown`)
- [ ] Mismatch (both directions) auto-corrected within one 5-min cycle
- [ ] Telegram received after successful self-heal (mba only, single message)
- [ ] Telegram sent every cycle while mismatch persists
- [ ] Telegram sent once when state returns to ok
- [ ] No Telegram spam when system is healthy

---

## Technical Reference

### RPC endpoints (GET, no auth required)

```
GET http://192.168.1.169/rpc/Switch.GetStatus?id=0
  → {"id":0, "source":"...", "output":true|false, ...}

GET http://192.168.1.169/rpc/Switch.Set?id=0&on=true
  → {"was_on":false}   (confirms previous state)

GET http://192.168.1.169/rpc/Switch.Set?id=0&on=false
  → {"was_on":true}
```

Confirmed working from hsb1 (tested 2026-02-24, no auth needed).

### Existing flow variables (unchanged)

- `flow.wc_tado_input` — bool, set by `health-chain-tado-store` on every Tado MQTT message. **Keep this.**
- `flow.vr_4pm_output` — **replace with live RPC at check time, do not use stored value**

### New flow variables

- `flow.heatChainAlerted` — bool, `true` while a mismatch notification has been sent. Cleared on ok.
- `flow.heatChainMismatchAt` — timestamp of first mismatch detection (for log/message context)

### Telegram message format

```js
// In the "build telegram" function node:
msg.payload = {
  telegram: {
    message:
      "🔧 FBH-WC korrigiert:\nTado=OFF, 4PM war ON → auf OFF gesetzt\n14:32",
    // no chatId needed → defaults to TELEGRAM_CHAT_ID_JHW22_MBA
  },
};
return msg;
// Wire to: GLOBAL_TELEGRAM_SEND++ (node d73b29d592e47d92, tab 1447a865fe7913ee)
// Use a Link Out node to cross tabs cleanly
```

### Modified `health-chain-fn` logic (pseudo-code)

```js
// 1. Get Tado state (from flow variable — MQTT still works for Tado)
const tadoInput = flow.get("wc_tado_input"); // true=heating requested

// 2. Get 4PM state via live RPC (not flow variable)
const rpcRes = await fetch("http://192.168.1.169/rpc/Switch.GetStatus?id=0");
const rpcData = await rpcRes.json();
const output4pm = rpcData.output; // true=ON, false=OFF

// 3. Determine state (both directions)
let state = "unknown";
if (tadoInput !== undefined && output4pm !== undefined) {
  const mismatch = tadoInput !== output4pm;
  state = mismatch ? "mismatch" : "ok";
}

// 4. Publish to MQTT (unchanged)
// 5. If mismatch → route to self-heal nodes
// 6. If ok + heatChainAlerted → route to "resolved" notification
```

### Node-RED node wiring overview

```
[inject: every 5min]
        │
        ▼
[health-chain-fn]  ← async, does RPC GetStatus + check
        │
   ┌────┴────────┐
   │ mismatch    │ ok + alerted
   ▼             ▼
[Switch.Set]   [fn: build "OK" telegram] → [link out → TELEGRAM]
   │
[delay 30s]
   │
[Switch.GetStatus re-check]
   │
   ├── fixed → [fn: build "fixed" telegram] → [link out → TELEGRAM]
   │            set heatChainAlerted=true
   │
   └── still wrong → [fn: build "still broken" telegram] → [link out → TELEGRAM]
                      (send every cycle)

[MQTT in: Tado bridge] → [store tado input] (unchanged)
[MQTT out: jhw2211/health/heat-chain]       (unchanged)
```

---

## Notes

- NR UI: `http://192.168.1.101:1880`
- Flow tab to edit: `992d23c856b48610` (rename to "FBH-WC Health")
- No nixcfg repo changes needed (NR flows live outside git)
- No HA changes needed
- `wc/shelly1-tado-bridge` Gen1 — input/0 publishes `"0"` or `"1"` (string → coerce to bool)
- Pro 4PM MQTT: `connected: true` per device, but zero messages published — do NOT rely on it
- Pro 4PM HTTP RPC: confirmed working, no auth, ~20ms response from hsb1
- `GLOBAL_TELEGRAM_SEND++` node id: `d73b29d592e47d92`, in tab `1447a865fe7913ee`
- Apprise endpoint: `http://192.168.1.101:8001/notify` (already wired in the global node)
- Backup flows before any change — NR has no git history
