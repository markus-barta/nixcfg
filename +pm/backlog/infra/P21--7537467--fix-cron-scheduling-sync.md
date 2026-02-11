# Fix Out-of-Sync Cron and Schedule Time Issues

**Created**: 2026-02-05  
**Priority**: P2100 (High)  
**Status**: Backlog

---

## Problem

Scheduled tasks (Cron jobs) are firing at unexpected times.

1. **Clock Skew/Drift**: The system time on `hsb1` (Feb 2026) is heavily ahead of the LLM's perceived internal state (training cutoff drift).
2. **Execution Lag**: Some jobs seem to trigger arbitrarily when the gateway is reloaded or after significant delay.
3. **Stale Jobs**: Firing logic for "past" jobs needs to be verified (should they catch up or be discarded?).

---

## Solution

Analyze the root cause within the OpenClaw Cron implementation and implement safeguards.

1. **System Time Synchronization**: Ensure the agent always uses the current system timestamp as the baseline for all `atMs` calculations.
2. **State Cleanup**: Remove or disable legacy test jobs that might still be in the `jobs.json` store.
3. **Investigation**: Check if `next-heartbeat` vs `now` wake modes contribute to the perceived delay.

---

## Acceptance Criteria

- [ ] New scheduled tasks fire within ±5 seconds of target time.
- [ ] No "ghost" messages from past sessions reappear upon restart.
- [ ] Documentation updated on how to handle 2026+ timestamps for future-proof scheduling.

---

## Test Plan

### Manual Test

1. Schedule a message for "now + 2 minutes".
2. Verify it arrives promptly at the target time.

### Automated Test

```bash
# Check current cron store for unexpected entries
cat ~/.openclaw/cron/jobs.json | jq '.'
```
