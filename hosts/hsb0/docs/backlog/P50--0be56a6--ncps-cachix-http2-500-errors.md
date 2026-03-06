# ncps-cachix-http2-500-errors

**Host**: hsb0
**Priority**: P50
**Status**: Backlog
**Created**: 2026-03-06

---

## Problem

ncps (local Nix cache proxy on hsb0:8501) returns HTTP 500 when proxying narinfo requests to `nix-community.cachix.org`. Upstream cachix responds with HTTP/2 `GOAWAY` (PROTOCOL_ERROR), which ncps fails to handle gracefully — bubbles up as 500 to clients. Causes warnings on every `nix build` / `home-manager switch` from imac0.

Example error:

```
error: unable to download 'http://hsb0.lan:8501/<hash>.narinfo': HTTP error 500
response body: error performing HEAD request to https://nix-community.cachix.org/...:
http2: server sent GOAWAY and closed the connection; LastStreamID=..., ErrCode=PROTOCOL_ERROR
```

## Solution

- Check ncps version; update if outdated
- Investigate if ncps has HTTP/2 handling issues with cachix (known upstream bug?)
- Workaround: disable HTTP/2 for cachix in ncps config, or pin to HTTP/1.1

## Implementation

- [ ] Check ncps service status + version on hsb0
- [ ] Check ncps GitHub issues for HTTP/2 GOAWAY handling
- [ ] Apply fix (config tweak or update)
- [ ] Verify no more 500s during `just switch` on imac0

## Acceptance Criteria

- [ ] `just switch` on imac0 produces no HTTP 500 warnings from hsb0.lan:8501

## Notes

- Build still completes (warnings only, not errors) — low urgency
- Observed: 2026-03-06 during tokstat package addition
