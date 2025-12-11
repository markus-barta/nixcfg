# NixFleet - UI/UX Enhancements

**Created**: 2025-12-10
**Completed**: 2025-12-11
**Priority**: Low
**Status**: Done

---

## Goal

Minor polish and improvements for the NixFleet dashboard.

---

## Tasks

- [x] **Cache git hash locally on host** — Avoid calling git commands every 10s; cache the hash and only refresh on pull/switch
- [x] **Timestamp in locale** — Display timestamps in user's locale format instead of UTC/ISO
- [x] **Device icons** — Add icons for device types (already implemented: cloud, desktop, laptop, server, mobile, game, office)
- [x] **Test icon** — Changed from checkmark to flask/beaker icon (2025-12-11)

---

## Notes

These polish items have been completed. More complex features have been split into separate backlog items:

- **Action button locking**: [2025-12-11-nixfleet-action-button-locking.md](../backlog/2-medium/2025-12-11-nixfleet-action-button-locking.md)
- **StaSysMo metrics**: [2025-12-11-nixfleet-stasysmo-metrics.md](../backlog/3-low/2025-12-11-nixfleet-stasysmo-metrics.md)

---

## References

- [pkgs/nixfleet/README.md](../../pkgs/nixfleet/README.md)
- [.pm/done/2025-12-10-nixfleet-fleet-management.md](../../done/2025-12-10-nixfleet-fleet-management.md)
- [.pm/done/2025-12-11-nixfleet-sse-live-updates.md](2025-12-11-nixfleet-sse-live-updates.md)
