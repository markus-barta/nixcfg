# Make SMTP config declarative with agenix

**Priority**: P40
**Status**: Backlog
**Created**: 2026-02-17

---

## Problem

SMTP credentials are currently stored as plain text files on each host (`~/docker/smtp/variables.env`), rather than using agenix like all other secrets. This is inconsistent with the rest of the infrastructure and creates operational drift.

## Solution

Store SMTP credentials in age secrets and inject them via docker-compose using agenix-mounted secrets, following the same pattern as restic-hetzner-env and other secrets.

## Implementation

- [ ] Create `secrets/<host>-smtp-env.age` for each affected host (hsb0, hsb1, csb0)
- [ ] Add secret definitions to `secrets/secrets.nix`
- [ ] Update docker-compose.yml on each host to mount `/run/agenix/<host>-smtp-env` instead of local `./smtp/variables.env`
- [ ] Remove `~/docker/smtp/variables.env` from hosts after deployment
- [ ] Test email delivery on each host

## Acceptance Criteria

- [ ] SMTP credentials stored in agenix (age files)
- [ ] docker-compose uses agenix-mounted secrets
- [ ] Email notifications work on all hosts
- [ ] No plain-text SMTP credentials in host filesystem
- [ ] Runbooks updated if needed

## Notes

Affected hosts:

- hsb0: has smtp container in docker-compose.yml (just added)
- hsb1: existing smtp container with local variables.env
- csb0: existing smtp container with local variables.env

Pattern to follow: same as `restic-hetzner-env` secret handling.
