# openclaw-deployment

**Host**: hsb1
**Priority**: P94
**Status**: Backlog
**Created**: 2026-01-13

---

## Problem

OpenClaw AI assistant needs deployment on hsb1 for home automation integration. Not yet configured.

## Solution

Deploy OpenClaw gateway service on hsb1 with Docker and Home Assistant skills.

## Implementation

- [ ] Build/install OpenClaw package from flake
- [ ] Create systemd service for openclaw-gateway
- [ ] Configure workspace directory (`~/.openclaw/`)
- [ ] Link skills: Docker, Home Assistant (see P66.56fe6e8)
- [ ] Set up credentials/API keys via agenix
- [ ] Configure Home Assistant integration
- [ ] Test basic queries (docker status, HA entities)
- [ ] Document commands in RUNBOOK.md

## Acceptance Criteria

- [ ] OpenClaw service running
- [ ] Workspace configured
- [ ] Skills loaded (Docker, Home Assistant)
- [ ] Can query docker containers
- [ ] Can query HA entities
- [ ] Credentials secured via agenix
- [ ] Documentation updated

## Notes

- Package source: Flake input or custom build
- Related: P6650 (declarative skills)
- Skills needed: Docker, Home Assistant
- Priority: 🟢 Low (nice-to-have automation enhancement)
