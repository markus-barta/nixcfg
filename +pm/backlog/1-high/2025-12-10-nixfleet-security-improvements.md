# NixFleet Security Improvements

**Created**: 2025-12-10  
**Priority**: High  
**Status**: Ready  
**Depends On**: pkgs/nixfleet/ (current alpha)

---

## Goal

Close remaining security gaps so NixFleet is safe for broader/internal exposure (beyond limited alpha).

---

## Scope

- Dashboard auth/session hardening
- Agent authentication and transport hardening
- Frontend CSP tightening
- Operational safeguards (rate limiting/backoff)

---

## Tasks

- [ ] Sign and verify session cookies (defense in depth on top of DB sessions); add rotation/expiry logic.
- [ ] Replace CSP `'unsafe-inline'` with nonces or hashes; update templates accordingly.
- [ ] Move from single shared agent token to per-host credentials or mTLS; add migration path.
- [ ] Agent TLS hardening: CA pinning/minimum TLS, and exponential backoff on auth failures.
- [ ] Add agent-side rate limiting/backoff for command execution/reporting to avoid overload when auth fails.
- [ ] Add monitoring/alerts for auth failures and rate-limit hits.

---

## Acceptance Criteria

- Sessions use signed cookies; invalid signatures are rejected; rotation tested.
- CSP contains no `'unsafe-inline'`; pages render correctly with nonced/hashed assets.
- Agents authenticate with per-host identity (token or mTLS); shared token deprecated.
- Agent TLS pinning/min-TLS enforced; failed pin blocks communication and is logged.
- Agent loops back off on repeated failures; dashboard remains stable under auth/token mistakes.
- Basic alerts/metrics exist for auth failures and rate-limit triggers.
