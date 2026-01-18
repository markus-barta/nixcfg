# P4501 - csb0/csb1 Cloudflare Token Rotation - DONE

**Task:** csb0/csb1 Cloudflare Token Rotation - Initial Rotation & git cleanup
**Status:** Completed
**Session Date:** 2026-01-17

---

## Completed Work

- ✅ Rotated Cloudflare API token (scope: `barta.cm` only, IP-filtered)
- ✅ Encrypted via agenix (`secrets/traefik-variables.age`)
- ✅ Refactored csb0 with initial directory structure (`/var/lib/csb0-docker/`)
- ✅ Token deployed to both csb0 and csb1 (via symlinks to agenix)
- ✅ Old token revoked from Cloudflare
- ✅ Git history cleaned with `git-filter-repo` (old token redacted)
- ✅ Force pushed to GitHub (history rewritten)
- ✅ Verified services are running with new token

---

## Meta

- **Priority:** P3 (High)
- **Effort:** High (History rewrite)
- **Status:** Moved to Done (splitting follow-ups to P4503 and P4504)
