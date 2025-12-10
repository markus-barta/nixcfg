# NixFleet - WebSocket Live Updates

**Created**: 2025-12-10
**Priority**: Medium
**Status**: Backlog

---

## Goal

Replace polling-based UI updates with WebSocket connections for real-time dashboard updates, especially during test runs.

---

## Current Behavior

- Dashboard requires manual page refresh to see changes
- During tests, progress is only visible after page reload
- Agent polls every 10s but dashboard doesn't auto-update

---

## Desired Behavior

- Dashboard connects via WebSocket to receive real-time updates
- Host status changes appear immediately (online/offline)
- Test progress updates live (#/# completed)
- Git hash changes highlight immediately after pull
- No need for manual page refresh

---

## Implementation Notes

### Server Side

- Add WebSocket endpoint (e.g., `/ws/updates`)
- Broadcast events on:
  - Host registration/status change
  - Command completion
  - Test progress updates
- Use FastAPI's WebSocket support

### Client Side

- JavaScript WebSocket connection in dashboard template
- Reconnect logic with exponential backoff
- Update DOM elements on message receipt
- Visual indicator for connection status

### Agent Side

- Publish test progress after each test file
- Use existing `/api/hosts/{id}/test-progress` endpoint

---

## Acceptance Criteria

- [ ] WebSocket connection established on dashboard load
- [ ] Host status updates appear within 1s
- [ ] Test progress shows live during execution
- [ ] Connection auto-reconnects on disconnect
- [ ] Works behind Traefik/Cloudflare proxy

---

## References

- FastAPI WebSocket docs: https://fastapi.tiangolo.com/advanced/websockets/
- Current polling implementation: `pkgs/nixfleet/app/main.py`
