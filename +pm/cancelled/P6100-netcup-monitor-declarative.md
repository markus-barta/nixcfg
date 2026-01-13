# 2025-11-29 - Netcup Monitor - Make Fully Automatic

## Status: BACKLOG (Low Priority)

## Summary

The netcup-monitor checks daily if csb0/csb1 cloud servers are online, alerts via Telegram/Email if offline 2+ days.

**Current state**: Works fine! But requires manual setup after fresh hsb1 rebuild.

## The Problem

| Item            | Location                       | Managed by NixOS? |
| --------------- | ------------------------------ | ----------------- |
| Systemd timer   | configuration.nix              | ✅ Yes            |
| Systemd service | configuration.nix              | ✅ Yes            |
| Script          | `~/bin/netcup-monitor.sh`      | ❌ No (manual)    |
| Config/secrets  | `~/secrets/netcup-monitor.env` | ❌ No (manual)    |

After fresh hsb1 rebuild, you need to manually copy the script and secrets.

## Priority Assessment

- **Frequency of problem**: Rare (hsb1 is rarely rebuilt from scratch)
- **Monitoring itself**: Works perfectly
- **Impact**: Convenience during rare rebuilds, not fixing broken functionality

---

## Option A: Quick Fix (Recommended) ⚡

**Effort**: 5 minutes | **Solves**: 80% of the problem

Just reference the script directly from the repo instead of `~/bin/`:

```nix
# In hosts/hsb1/configuration.nix
systemd.services.netcup-monitor.serviceConfig.ExecStart =
  "${./bin/netcup-monitor.sh}";
```

**Pros**:

- Script is now managed by NixOS (no manual copy needed)
- 1-line change
- Good enough for practical purposes

**Cons**:

- Secrets still need manual setup (one-time)
- Not "fully declarative"

**Remaining manual step**: Create `~/secrets/netcup-monitor.env` once after fresh install.

---

## Option B: Full Declarative (Future) 🏗️

**Effort**: 1-2 hours | **Solves**: 100% of the problem

Full NixOS-native implementation with agenix for secrets.

### Acceptance Criteria

- [ ] Script as proper Nix package or inline
- [ ] Secrets migrated to agenix (`secrets/hsb1/netcup-monitor.age`)
- [ ] Remove all dependency on manual `~/bin/` and `~/secrets/` files
- [ ] Test: rebuild hsb1 → monitoring works without ANY manual steps

### Implementation

#### Step 1: Script as package

```nix
# hosts/hsb1/packages/netcup-monitor.nix
{ pkgs, ... }:
pkgs.writeShellApplication {
  name = "netcup-monitor";
  runtimeInputs = [ pkgs.curl pkgs.jq ];
  text = builtins.readFile ../bin/netcup-monitor.sh;
}
```

#### Step 2: Agenix secrets

```bash
# Create encrypted secret
cd secrets/hsb1
agenix -e netcup-monitor.age
```

#### Step 3: Update service

```nix
systemd.services.netcup-monitor = {
  serviceConfig = {
    ExecStart = "${netcup-monitor}/bin/netcup-monitor";
    EnvironmentFile = config.age.secrets.netcup-monitor.path;
  };
};
```

### Secrets needed

- NETCUP_REFRESH_TOKEN
- CSB0_ID, CSB1_ID
- TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
- EMAIL (optional)
- APPRISE_URL (optional)

---

## Recommendation

Start with **Option A** (quick fix) - it's pragmatic and solves the main annoyance.
Revisit **Option B** later if you want full declarative purity or are doing a secrets audit.

## Source

- Script: `hosts/hsb1/bin/netcup-monitor.sh`
- Service config: `hosts/hsb1/configuration.nix` lines 376-410
