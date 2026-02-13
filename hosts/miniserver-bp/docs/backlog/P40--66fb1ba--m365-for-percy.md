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

### Phase 1: Install himalaya binary (DONE)

**Dockerfile** (`hosts/miniserver-bp/docker/Dockerfile`):

```dockerfile
# Install himalaya (CLI email client for IMAP/SMTP)
# https://github.com/pimalaya/himalaya
RUN curl -sL https://github.com/pimalaya/himalaya/releases/download/v1.1.0/himalaya.x86_64-linux.tgz \
    | tar xz -C /tmp && mv /tmp/himalaya /usr/local/bin/himalaya && chmod +x /usr/local/bin/himalaya
```

**configuration.nix** changes:

- Volume mount added: `/var/lib/openclaw-percaival/himalaya:/home/node/.config/himalaya:rw`
- Activation script creates directory: `/var/lib/openclaw-percaival/himalaya`
- chown includes: `1000:1000`

**Build steps**:

```bash
cd ~/Code/nixcfg/hosts/miniserver-bp/docker
docker build -t openclaw-percaival:latest . --no-cache
sudo systemctl restart docker-openclaw-percaival
docker exec openclaw-percaival himalaya --version
```

- [x] Binary installed in Dockerfile
- [x] Docker image rebuilt
- [x] Container restarted
- [ ] Verify: `docker exec openclaw-percaival himalaya --version`

### Phase 2: Configure IMAP credentials

- [ ] Create app password in Microsoft/Outlook (if 2FA enabled)
- [ ] Create `/var/lib/openclaw-percaival/himalaya/config.toml`:

  ```toml
  [accounts.bytepoets]
  email = "percy.ai@bytepoets.com"
  display-name = "Percy AI"
  default = true

  [accounts.bytepoets.backend]
  type = "imap"
  host = "outlook.office365.com"
  port = 993
  encryption.type = "tls"

  [accounts.bytepoets.backend.auth]
  type = "password"
  login = "percy.ai@bytepoets.com"
  password = "app-password-here"

  [accounts.bytepoets.message.send]
  backend.type = "smtp"
  backend.host = "smtp.office365.com"
  backend.port = 587
  backend.encryption.type = "starttls"

  [accounts.bytepoets.message.send.backend.auth]
  type = "password"
  login = "percy.ai@bytepoets.com"
  password = "app-password-here"
  ```

- [ ] Fix ownership: `sudo chown -R 1000:1000 /var/lib/openclaw-percaival/himalaya`
- [ ] Test: `docker exec openclaw-percaival himalaya envelope list`

### Phase 3: Enable skill in OpenClaw

- [ ] Install skill: `clawhub install lamelas/himalaya`
- [ ] Or use bundled version (should work now that binary is present)
- [ ] Verify: `docker exec openclaw-percaival openclaw skills list | grep himalaya`

## Skills

- himalaya skill is bundled in OpenClaw: `openclaw skills list` shows it (requires binary)
- Skill: https://clawhub.ai/lamelas/himalaya

## Notes

- **Why himalaya?** Simpler than M365/Graph API - just IMAP/SMTP
- **Microsoft Outlook**: Need app password if 2FA is enabled
- **Similar to gogcli**: Binary in Dockerfile, config in volume mount
- **Release URL**: Must use correct filename `himalaya.x86_64-linux.tgz` (not `himalaya-linux-x86_64.tar.gz`)

## References

- Skill: https://clawhub.ai/lamelas/himalaya
- CLI: https://github.com/pimalaya/himalaya
- Docs: https://pimalaya.org/himalaya/cli/latest/
