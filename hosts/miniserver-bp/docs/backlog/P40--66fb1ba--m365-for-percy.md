# email-via-himalaya

**Host**: miniserver-bp
**Priority**: P40
**Status**: Backlog
**Created**: 2026-02-13
**Updated**: 2026-02-13

---

## Problem

Percy (Percaival) on miniserver-bp needs email access. Using IMAP via himalaya CLI (simpler than M365/Graph API).

## Solution

Install himalaya CLI in Docker container + configure IMAP credentials.

## Implementation

- [ ] **Add himalaya to Dockerfile**:
  ```dockerfile
  # Install himalaya (CLI email client for IMAP/SMTP)
  # https://github.com/pimalaya/himalaya/releases
  RUN curl -sL https://github.com/pimalaya/himalaya/releases/download/v1.1.0/himalaya-linux-x86_64.tar.gz \
      | tar xz -C /tmp && mv /tmp/himalaya /usr/local/bin/himalaya && chmod +x /usr/local/bin/himalaya
  ```
- [ ] Rebuild Docker image: `docker build -t openclaw-percaival:latest .`
- [ ] Restart container: `sudo systemctl restart docker-openclaw-percaival`
- [ ] Verify: `docker exec openclaw-percaival himalaya --version`
- [ ] **Configure IMAP credentials**:
  - Create app password in Microsoft/Outlook (if 2FA enabled)
  - Store in `/var/lib/openclaw-percaival/himalaya/config.toml`
- [ ] Test: `docker exec openclaw-percaival himalaya envelope list`

## Skills

- himalaya skill is bundled in OpenClaw: `openclaw skills list` shows it (but binary is missing)
- Install skill: `clawhub install lamelas/himalaya` (or use bundled version once binary is present)

## Notes

- **Why himalaya?** Simpler than M365/Graph API - just IMAP/SMTP
- **Microsoft Outlook**: Need app password if 2FA is enabled
- **Similar to gogcli**: Binary in Dockerfile, config in volume mount

## References

- Skill: https://clawhub.ai/lamelas/himalaya
- CLI: https://github.com/pimalaya/himalaya
- Docs: https://pimalaya.org/himalaya/cli/latest/
