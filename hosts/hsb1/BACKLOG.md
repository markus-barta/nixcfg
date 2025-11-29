# hsb1 Backlog

Technical debt and future improvements for hsb1.

---

## 🔴 High Priority

### Netcup Monitor - Make Declarative

**Created**: 2025-11-29  
**Status**: ⏳ Manual setup, needs Nix migration

**Current State**:
The Netcup server monitor is currently set up manually:

- Script: `~/bin/netcup-monitor.sh` (manually copied)
- Config: `~/secrets/netcup-monitor.env` (manually created, gitignored)
- Timer: Defined in `configuration.nix` but points to manual script

**What Needs to Be Done**:

1. Move script to Nix derivation or `environment.etc`
2. Store secrets in agenix instead of `~/secrets/`
3. Add hsb1's host key to `secrets/secrets.nix`:
   ```
   ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIU0cAsXtdYPO5W4ns6utAEkVvzcmOx5Xl/nVF/fvAVz
   ```
4. Create `netcup-api-token.age` encrypted for hsb1
5. Update service to use Nix-managed paths

**Files to Migrate**:

- `~/bin/netcup-monitor.sh` → Nix derivation or pkgs.writeShellScript
- `~/secrets/netcup-monitor.env` → `secrets/netcup-monitor.age`

**References**:

- Script source: `hosts/hsb1/bin/netcup-monitor.sh`
- Timer config: `hosts/hsb1/configuration.nix` (search for netcup-monitor)
- Similar pattern: See how agenix is used for `static-leases-hsb0.age`

---

## 🟡 Medium Priority

(None currently)

---

## 🟢 Low Priority

(None currently)

---

## ✅ Completed

(None yet)
