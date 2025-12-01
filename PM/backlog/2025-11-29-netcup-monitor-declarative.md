# 2025-11-29 - Netcup Monitor - Make Fully Automatic

## Description

The netcup-monitor checks daily if csb0/csb1 cloud servers are online, alerts via Telegram/Email/LaMetric if offline 2+ days.

**Problem**: Currently requires manual setup after rebuilding hsb1:

- Script manually copied to `~/bin/netcup-monitor.sh`
- Config manually created in `~/secrets/netcup-monitor.env`

**Goal**: Make it fully automatic — rebuild hsb1 from scratch and monitoring just works.

## Source

- Original: `hosts/hsb1/BACKLOG.md` (High Priority item)
- Current script: `hosts/hsb1/bin/netcup-monitor.sh`
- Current config: `hosts/hsb1/configuration.nix` lines 356-398

## Scope

Applies to: hsb1

## What Exists Today

| Item            | Location                       | Managed by NixOS? |
| --------------- | ------------------------------ | ----------------- |
| Systemd timer   | configuration.nix              | ✅ Yes            |
| Systemd service | configuration.nix              | ✅ Yes            |
| Script          | `~/bin/netcup-monitor.sh`      | ❌ No (manual)    |
| Config/secrets  | `~/secrets/netcup-monitor.env` | ❌ No (manual)    |

## Acceptance Criteria

- [ ] Script moved to NixOS config (inline or as package)
- [ ] Secrets migrated to agenix (`netcup-monitor.age`)
- [ ] Remove dependency on manual `~/bin/` and `~/secrets/` files
- [ ] Test: rebuild hsb1 → monitoring works without manual steps
- [ ] Test: alert fires correctly when server offline

## Implementation Options

**Option A: Inline script in NixOS**

```nix
systemd.services.netcup-monitor.serviceConfig.ExecStart =
  pkgs.writeShellScript "netcup-monitor" ''
    # script content here
  '';
```

**Option B: Package in hosts/hsb1/**

```nix
# hosts/hsb1/packages/netcup-monitor.nix
{ pkgs, ... }:
pkgs.writeShellApplication {
  name = "netcup-monitor";
  runtimeInputs = [ pkgs.curl pkgs.jq ];
  text = builtins.readFile ./netcup-monitor.sh;
}
```

## Notes

- Priority: High (critical infrastructure monitoring)
- The script already exists and works — just needs to be "nixified"
- Secrets needed: NETCUP_REFRESH_TOKEN, CSB0_ID, CSB1_ID, TELEGRAM_BOT, TELEGRAM_CHAT, EMAIL, APPRISE_URL
