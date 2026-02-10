# load-spike-investigation

**Host**: csb0
**Priority**: P67
**Status**: Backlog
**Created**: 2025-12-25

---

## Problem

Major CPU load spike on csb0 (cloud server) on 2025-12-25. System became unresponsive, required hard reboot. Initial findings point to resource exhaustion, possibly Node-RED or another Docker container.

## Solution

Identify source of resource exhaustion, implement Docker resource limits, set up alerting to prevent future incidents.

## Implementation

- [ ] Review system logs around incident time: `journalctl --since "2025-12-25" --until "2025-12-26"`
- [ ] Review Docker container logs for all services
- [ ] Audit Node-RED flows for infinite loops or high-frequency triggers
- [ ] Implement `deploy.resources` limits in `docker-compose.yml` for all containers:
  - Memory limits (e.g., 512MB per container)
  - CPU limits (e.g., 0.5 CPUs per container)
- [ ] Set up load-based alerting in Uptime Kuma (alert before system becomes unresponsive)
- [ ] Document root cause in incident report
- [ ] Test that high load triggers notification

## Acceptance Criteria

- [ ] Root cause identified and documented
- [ ] Resource limits applied to all csb0 containers
- [ ] High load triggers alert notification
- [ ] Incident report created: `docs/incidents/2025-12-25-csb0-load-spike.md`

## Notes

- Related: P4900-infra-safety-resilience.md
- Priority: 🟡 MEDIUM (prevent future unplanned downtime)
- Single container should not take down entire host
