# T00: NixOS Base System Test

## Purpose

Verify basic NixOS system functionality on csb0.

## Automated Tests

Run: `./T00-nixos-base.sh`

## Checks

| #   | Test               | Expected                          |
| --- | ------------------ | --------------------------------- |
| 1   | NixOS version      | Version string returned           |
| 2   | Config directory   | `/etc/nixos` or `~/nixcfg` exists |
| 3   | System generations | At least 1 generation             |
| 4   | System status      | `running` or `degraded`           |
| 5   | Docker installed   | `docker` command available        |

## Manual Verification

```bash
ssh -p 2222 mba@cs0.barta.cm

# Check version
nixos-version

# Check generations
sudo nix-env --list-generations -p /nix/var/nix/profiles/system

# Check systemd
systemctl is-system-running
systemctl --failed
```
