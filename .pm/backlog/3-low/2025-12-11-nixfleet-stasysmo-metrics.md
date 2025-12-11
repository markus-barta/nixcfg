# NixFleet - StaSysMo Metrics Integration

**Created**: 2025-12-11
**Priority**: Low
**Status**: Backlog

---

## Goal

Display StaSysMo system metrics (CPU, RAM, disk, network) in the NixFleet dashboard.

---

## Background

StaSysMo is our system monitoring solution that collects metrics via a daemon on each host. Currently these metrics are used for the starship prompt status bar. We could leverage this data in NixFleet for a unified fleet view.

---

## Tasks

### Agent Changes

- [ ] Read StaSysMo metrics file (if exists) during registration/poll
- [ ] Include metrics in status updates (CPU%, RAM%, disk%, load)

### API Changes

- [ ] Add metrics fields to host registration/status models
- [ ] Store metrics in database (new columns or JSON field)
- [ ] Include metrics in API responses

### Dashboard Changes

- [ ] Add metrics columns or expandable row details
- [ ] Visual indicators (progress bars, color coding for thresholds)
- [ ] Optional: sparklines for metric history

---

## Considerations

- **Performance**: Metrics add payload size to every poll
- **Storage**: How long to keep metric history?
- **Optional**: Make metrics collection opt-in via config

---

## References

- [modules/stasysmo/](../../../modules/stasysmo/)
- [pkgs/nixfleet/](../../../pkgs/nixfleet/)
