# msbp: Docker Infrastructure & Hello-World Container

**Created**: 2026-02-09
**Priority**: P4550 (Medium)
**Status**: Backlog

---

## Problem

msbp has Docker installed and running (via Hokage) but no containers deployed. Need to verify Docker works end-to-end and open port 8888 for the future pm-tool.

---

## Solution

1. Deploy a hello-world nginx container on port 8888
2. Open port 8888 in NixOS firewall
3. Verify reachable from office network

---

## Implementation

### Files to modify

- `hosts/miniserver-bp/configuration.nix` — open port 8888, add docker container
- `hosts/miniserver-bp/README.md` — update services table

### Docker approach

Use NixOS `virtualisation.oci-containers` (declarative Docker) rather than manual `docker run`. This keeps everything in Nix config and survives reboots.

```nix
virtualisation.oci-containers.containers.hello-world = {
  image = "nginx:alpine";
  ports = [ "8888:80" ];
  volumes = [ "/var/lib/pm-tool/html:/usr/share/nginx/html:ro" ];
};
```

Seed `/var/lib/pm-tool/html/index.html` with a simple hello page.

---

## Acceptance Criteria

- [ ] `curl http://10.17.1.40:8888` returns "Hello, World" page
- [ ] Container auto-starts on boot (declarative via NixOS)
- [ ] Port 8888 open in firewall
- [ ] README.md updated with new service
- [ ] RUNBOOK.md updated with container management commands

---

## Test Plan

### Manual Test

```bash
# From mba-imac-work
curl -s http://10.17.1.40:8888 | grep -i hello
```

### Automated Test

```bash
ssh -p 2222 mba@10.17.1.40 "docker ps | grep hello-world && curl -s localhost:8888"
```

---

## Risk

🟢 LOW — test server, no production impact

---

## Related

- P4500: pm-tool PRD
- P4600: pm-tool deployment pipeline
