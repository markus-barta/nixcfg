# P9100: Tier 1 Backup Audit - hsb0 & hsb1

## 🎯 Goal

Replicate the "csb0/csb1 migration audit" success for the home server core. Ensure all local backup logic is repatriated, secrets are standardized via `agenix`, and off-site connectivity is 100% verified.

## 🚀 Execution Strategy (Tier 1)

### 1. HSB1: Home Automation Hub (High Priority)

_Current State: Managed via separate `miniserver24-docker.git` (per P7200)._

- [x] **Discovery**: Locate the `restic-cron` source on `hsb1`.
- [x] **Repatriation**: Move `Dockerfile` and `hetzner/` scripts into `hosts/hsb1/docker/restic-cron/`.
- [ ] **Secret Audit**: Transition repository passwords and SSH keys to `agenix`.
- [ ] **Connectivity Test**: Run `restic snapshots` to verify sub-account mapping (likely `u387549-sub2`).
- [ ] **Verification**: Update `OPS-STATUS.md` to 🟢.

### 2. HSB0: DNS/DHCP Core

_Current State: ZFS snapshots only (Local-only risk)._

- [x] **Discovery**: Audit AdGuard Home and NCPS data paths.
- [x] **Implementation**: Deploy `restic-cron` container (or Nix-native restic) targeting a new Hetzner sub-account.
- [ ] **Secret Audit**: Generate and store new SFTP SSH key and repo password.
- [ ] **Initial Sync**: Verify first successful off-site snapshot.
- [ ] **Verification**: Update `OPS-STATUS.md` from 🔴 to 🟢.

## 🛠️ Step-by-Step Quality Pattern

Follow the "Slow Audit" pattern used for `csb0`:

1. **Analyze** actual runtime scripts on the host.
2. **Compare** with `nixcfg` repo state (find the gaps).
3. **Standardize** paths and symlinks (`~/docker` → `~/nixcfg/...`).
4. **Bridge** secrets through `agenix`.
5. **Verify** with live snapshot/mount tests.

## 📝 Notes

- HSB1 is critical for smart home continuity.
- HSB0 currently represents a "single point of failure" for off-site backups (only ZFS local).
