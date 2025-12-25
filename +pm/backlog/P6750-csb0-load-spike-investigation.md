# P6750 - csb0 Load Spike Investigation

**Created**: 2025-12-25  
**Priority**: P6750 (Medium)  
**Status**: Backlog  
**Host**: csb0

---

## Description

Investigate the root cause of the major CPU load spike on `csb0` (cloud server) observed on 2025-12-25.
The system became unresponsive, requiring a hard reboot.

Initial findings point to resource exhaustion, possibly due to Node-RED or another Docker container.

---

## Goals

1. **Identify Source**: Pinpoint which process/container caused the resource exhaustion.
2. **Implement Limits**: Add Docker resource limits (memory/CPU) to prevent a single container from taking down the host.
3. **Alerting**: Ensure monitoring (Uptime Kuma) alerts on high load _before_ the system becomes unresponsive.

---

## Tasks

- [ ] Review system logs around the time of the incident (`journalctl`).
- [ ] Review Docker container logs.
- [ ] Audit Node-RED flows for infinite loops or high-frequency triggers.
- [ ] Implement `deploy.resources` limits in `docker-compose.yml` for all containers.
- [ ] Set up load-based alerting in Uptime Kuma.

---

## Acceptance Criteria

- [ ] Root cause identified and documented.
- [ ] Resource limits applied to all `csb0` containers.
- [ ] Verified that high load triggers a notification.

---

## Related

- Incident Report: `docs/incidents/2025-12-25-csb0-load-spike.md`
- Safety Resilience: `+pm/backlog/P4900-infra-safety-resilience.md`
