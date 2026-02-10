# Declarative SSH + Tailscale Fleet Config

**Priority**: P30
**Status**: Backlog
**Created**: 2026-02-10

---

## Problem

Current SSH connection setup has multiple issues:

1. **Hardcoded IPs in shell aliases** - Direct LAN IPs in fish abbreviations
2. **No Tailscale fallback** - Manual switching between LAN and VPN connections
3. **Fish-only** - No bash alias support for SSH shortcuts
4. **Inconsistent naming** - Long hostnames (mba-mbp-work) without nicknames
5. **No declarative SSH config** - SSH config not managed via Nix
6. **Old config debris** - Backup files with obsolete abbreviations (qc99, qc24, etc.)

**Current state:**

```fish
# modules/uzumaki/fish/config.nix (lines 70-77)
hsb0 = "ssh mba@192.168.1.99 -t 'zellij attach hsb0 -c'";  # Hardcoded IP
csb0 = "ssh mba@cs0.barta.cm -p 2222 -t 'zellij attach csb0 -c'";  # Public hostname
```

**User workflow:** Type `hsb0` → auto-connect with zellij session

**Issue:** No automatic LAN→Tailscale fallback when remote.

---

## Solution

Implement **declarative SSH config with automatic LAN→Tailscale fallback**, managed entirely via NixOS.

### Architecture

```
User types: hsb0
     ↓
Fish/Bash alias wraps with zellij
     ↓
SSH config (ProxyCommand)
     ├─ Try LAN (2s timeout)
     └─ Fallback to Tailscale
```

### Key Design Decisions

1. **Option C approach** - SSH config handles routing, shell aliases add zellij wrapper
2. **Nickname system** - Short aliases for long hostnames (mbpw → mba-mbp-work)
3. **ProxyCommand fallback** - 2s delay acceptable for remote connections
4. **Explicit routes** - `-lan` and `-ts` suffixes for manual control
5. **NO ControlMaster** - Skip connection multiplexing (decision: avoid complexity/risks for now)
6. **ServerAliveInterval** - Keep connections alive (60s ping)
7. **Works everywhere** - bash, fish, zsh, LLMs, automation tools

---

## Implementation

### 1. Create `modules/shared/ssh-fleet.nix`

**New file** - Declarative SSH config for all fleet hosts

```nix
{ config, lib, pkgs, ... }:
{
  programs.ssh = {
    enable = true;

    # ═══════════════════════════════════════════════════════════
    # Keep-Alive Settings (prevent timeout)
    # ═══════════════════════════════════════════════════════════
    serverAliveInterval = 60;   # Send ping every 60s
    serverAliveCountMax = 3;    # Disconnect after 3 failed pings (3min total)

    matchBlocks = {
      # ═══════════════════════════════════════════════════════════
      # HOME NETWORK HOSTS (192.168.1.0/24) - LAN with TS fallback
      # ═══════════════════════════════════════════════════════════

      "hsb0" = {
        hostname = "192.168.1.99";
        user = "mba";
        proxyCommand = "sh -c 'nc -w2 %h %p || nc hsb0.ts.barta.cm %p'";
      };
      "hsb0-lan" = { hostname = "192.168.1.99"; user = "mba"; };
      "hsb0-ts" = { hostname = "hsb0.ts.barta.cm"; user = "mba"; };

      "hsb1" = {
        hostname = "192.168.1.101";
        user = "mba";
        proxyCommand = "sh -c 'nc -w2 %h %p || nc hsb1.ts.barta.cm %p'";
      };
      "hsb1-lan" = { hostname = "192.168.1.101"; user = "mba"; };
      "hsb1-ts" = { hostname = "hsb1.ts.barta.cm"; user = "mba"; };

      "hsb8" = {
        hostname = "192.168.1.100";
        user = "mba";
        proxyCommand = "sh -c 'nc -w2 %h %p || nc hsb8.ts.barta.cm %p'";
      };
      "hsb8-lan" = { hostname = "192.168.1.100"; user = "mba"; };
      "hsb8-ts" = { hostname = "hsb8.ts.barta.cm"; user = "mba"; };

      "gpc0" = {
        hostname = "192.168.1.154";
        user = "mba";
        proxyCommand = "sh -c 'nc -w2 %h %p || nc gpc0.ts.barta.cm %p'";
      };
      "gpc0-lan" = { hostname = "192.168.1.154"; user = "mba"; };
      "gpc0-ts" = { hostname = "gpc0.ts.barta.cm"; user = "mba"; };

      "imac0" = {
        hostname = "192.168.1.150";
        user = "markus";  # Note: user is markus, not mba!
        proxyCommand = "sh -c 'nc -w2 %h %p || nc imac0.ts.barta.cm %p'";
      };
      "imac0-lan" = { hostname = "192.168.1.150"; user = "markus"; };
      "imac0-ts" = { hostname = "imac0.ts.barta.cm"; user = "markus"; };

      # ═══════════════════════════════════════════════════════════
      # PORTABLE HOST - Location-dependent (home network when docked)
      # ═══════════════════════════════════════════════════════════

      "mba-mbp-work" = {
        hostname = "192.168.1.197";  # When at home
        user = "mba";
        proxyCommand = "sh -c 'nc -w2 %h %p || nc mba-mbp-work.ts.barta.cm %p'";
      };
      "mba-mbp-work-lan" = { hostname = "192.168.1.197"; user = "mba"; };
      "mba-mbp-work-ts" = { hostname = "mba-mbp-work.ts.barta.cm"; user = "mba"; };

      # Nickname: mbpw → mba-mbp-work
      "mbpw" = { hostname = "mba-mbp-work"; };
      "mbpw-lan" = { hostname = "192.168.1.197"; user = "mba"; };
      "mbpw-ts" = { hostname = "mba-mbp-work.ts.barta.cm"; user = "mba"; };

      # ═══════════════════════════════════════════════════════════
      # WORK NETWORK HOSTS (10.17.0.0/16 BYTEPOETS) - LAN with TS fallback
      # ═══════════════════════════════════════════════════════════

      "mba-imac-work" = {
        hostname = "10.17.1.7";
        user = "markus";  # Note: user is markus, not mba!
        proxyCommand = "sh -c 'nc -w2 %h %p || nc mba-imac-work.ts.barta.cm %p'";
      };
      "mba-imac-work-lan" = { hostname = "10.17.1.7"; user = "markus"; };
      "mba-imac-work-ts" = { hostname = "mba-imac-work.ts.barta.cm"; user = "markus"; };

      # Nickname: imacw → mba-imac-work
      "imacw" = { hostname = "mba-imac-work"; };
      "imacw-lan" = { hostname = "10.17.1.7"; user = "markus"; };
      "imacw-ts" = { hostname = "mba-imac-work.ts.barta.cm"; user = "markus"; };

      "miniserver-bp" = {
        hostname = "10.17.1.40";
        user = "mba";
        proxyCommand = "sh -c 'nc -w2 %h %p || nc miniserver-bp.ts.barta.cm %p'";
      };
      "miniserver-bp-lan" = { hostname = "10.17.1.40"; user = "mba"; };
      "miniserver-bp-ts" = { hostname = "miniserver-bp.ts.barta.cm"; user = "mba"; };

      # Nickname: msbp → miniserver-bp
      "msbp" = { hostname = "miniserver-bp"; };
      "msbp-lan" = { hostname = "10.17.1.40"; user = "mba"; };
      "msbp-ts" = { hostname = "miniserver-bp.ts.barta.cm"; user = "mba"; };

      # ═══════════════════════════════════════════════════════════
      # CLOUD HOSTS - Tailscale only (no LAN)
      # ═══════════════════════════════════════════════════════════

      "csb0" = {
        hostname = "csb0.ts.barta.cm";
        user = "mba";
        port = 2222;  # Non-standard SSH port
      };
      "csb0-ts" = { hostname = "csb0.ts.barta.cm"; user = "mba"; port = 2222; };

      "csb1" = {
        hostname = "csb1.ts.barta.cm";
        user = "mba";
        port = 2222;  # Non-standard SSH port
      };
      "csb1-ts" = { hostname = "csb1.ts.barta.cm"; user = "mba"; port = 2222; };
    };
  };
}
```

**IPs confirmed:**

- ✅ imac0 LAN IP: 192.168.1.150
- ✅ mba-imac-work LAN IP: 10.17.1.7

---

### 2. Update `modules/uzumaki/fish/config.nix`

**File:** `modules/uzumaki/fish/config.nix`  
**Changes:**

```nix
fishAbbrs = {
  # ... existing abbrs (keep git, util aliases) ...

  # ═══════════════════════════════════════════════════════════
  # SSH Shortcuts (zellij auto-attach)
  # SSH config handles LAN/Tailscale fallback automatically
  # ═══════════════════════════════════════════════════════════

  # Home network
  hsb0 = "ssh hsb0 -t 'zellij attach hsb0 -c'";
  hsb1 = "ssh hsb1 -t 'zellij attach hsb1 -c'";
  hsb8 = "ssh hsb8 -t 'zellij attach hsb8 -c'";
  gpc0 = "ssh gpc0 -t 'zellij attach gpc0 -c'";
  imac0 = "ssh imac0 -t 'zellij attach imac0 -c'";

  # Work network (nicknames)
  imacw = "ssh imacw -t 'zellij attach imacw -c'";  # → mba-imac-work
  msbp = "ssh msbp -t 'zellij attach msbp -c'";     # → miniserver-bp

  # Portable (nickname)
  mbpw = "ssh mbpw -t 'zellij attach mbpw -c'";     # → mba-mbp-work

  # Cloud
  csb0 = "ssh csb0 -t 'zellij attach csb0 -c'";
  csb1 = "ssh csb1 -t 'zellij attach csb1 -c'";
};
```

**Removed lines:**

- Line 71-77: Old hardcoded SSH commands

---

### 3. Add Bash Aliases to `modules/common.nix`

**File:** `modules/common.nix`  
**Location:** After line 300 (around existing shell config)  
**Add:**

```nix
# ════════════════════════════════════════════════════════════════════════════
# BASH ALIASES - SSH shortcuts with zellij
# ════════════════════════════════════════════════════════════════════════════
# Mirrors fish abbreviations for bash compatibility
# SSH config (ssh-fleet.nix) handles LAN/Tailscale fallback
programs.bash.shellAliases = {
  # Home network
  hsb0 = "ssh hsb0 -t 'zellij attach hsb0 -c'";
  hsb1 = "ssh hsb1 -t 'zellij attach hsb1 -c'";
  hsb8 = "ssh hsb8 -t 'zellij attach hsb8 -c'";
  gpc0 = "ssh gpc0 -t 'zellij attach gpc0 -c'";
  imac0 = "ssh imac0 -t 'zellij attach imac0 -c'";

  # Work network
  imacw = "ssh imacw -t 'zellij attach imacw -c'";
  msbp = "ssh msbp -t 'zellij attach msbp -c'";

  # Portable
  mbpw = "ssh mbpw -t 'zellij attach mbpw -c'";

  # Cloud
  csb0 = "ssh csb0 -t 'zellij attach csb0 -c'";
  csb1 = "ssh csb1 -t 'zellij attach csb1 -c'";
};
```

---

### 4. Import SSH Module in `modules/common.nix`

**File:** `modules/common.nix`  
**Location:** Line ~30 (imports section)  
**Add:**

```nix
imports = [
  # ... existing imports ...
  ./shared/ssh-fleet.nix  # Fleet SSH config with Tailscale fallback
];
```

---

### 5. Update `modules/uzumaki/fish/functions.nix`

**File:** `modules/uzumaki/fish/functions.nix`  
**Location:** Around line 326 (help function)  
**Changes:**

Update the SSH shortcuts section in the `h` (help) function:

```nix
# Current:
echo -e "$color_abbr┌─ SSH Shortcuts (with zellij session) ──────────────────────────────────┐$color_reset"

# Change to:
echo -e "$color_abbr┌─ SSH Shortcuts (with zellij session) ──────────────────────────────────┐$color_reset"
printf " $color_abbr%-10s$color_reset → %-30s $color_dim# Auto LAN→TS fallback$color_reset\n" "hsb0" "ssh hsb0 -t 'zellij attach...'"
printf " $color_abbr%-10s$color_reset → %-30s $color_dim# Explicit routes$color_reset\n" "hsb0-lan" "Force LAN connection"
printf " $color_abbr%-10s$color_reset → %-30s\n" "hsb0-ts" "Force Tailscale connection"
echo ""
printf " $color_dim%-10s   %-30s %s$color_reset\n" "Nicknames:" "mbpw → mba-mbp-work" "(short aliases)"
printf " $color_dim%-10s   %-30s\n" "" "imacw → mba-imac-work"
printf " $color_dim%-10s   %-30s\n" "" "msbp → miniserver-bp"
echo -e "$color_abbr└────────────────────────────────────────────────────────────────────────┘$color_reset"
```

---

### 6. Update Documentation

#### A. Update `docs/INFRASTRUCTURE.md`

**Location:** After network topology section  
**Add:**

````markdown
## SSH Host Nicknames

Shorter aliases for commonly accessed hosts with long names:

| Nickname | Full Hostname | Purpose          | Network       |
| -------- | ------------- | ---------------- | ------------- |
| `mbpw`   | mba-mbp-work  | Work MacBook Pro | Home/Portable |
| `imacw`  | mba-imac-work | Work iMac        | BYTEPOETS     |
| `msbp`   | miniserver-bp | Office Mac Mini  | BYTEPOETS     |

### SSH Connection Examples

```bash
# Using full hostname
ssh mba-mbp-work

# Using nickname (equivalent)
ssh mbpw

# Force specific route
ssh mbpw-lan    # LAN only (fail if unreachable)
ssh mbpw-ts     # Tailscale only

# Auto-fallback (default)
ssh mbpw        # Try LAN first (2s timeout), fallback to Tailscale
```
````

### How LAN→Tailscale Fallback Works

1. **At home/office:** Connects via LAN (fast, direct)
2. **Remote/coffee shop:** Auto-fallbacks to Tailscale after 2s
3. **Zellij integration:** All aliases include `zellij attach` for session persistence

**Note:** SSH config is declaratively managed in `modules/shared/ssh-fleet.nix`.

````

---

### 7. Cleanup Old Configs

**Files to remove (via `trash`):**

```bash
trash ~/.config/fish/config.fish.backup
trash ~/.config/fish/config.fish~
````

**Reason:** Contain obsolete abbreviations:

- `qc99` → old miniserver99
- `qc24` → old miniserver24
- `qcml` → old miniserver
- `qc0`, `qc1` → old cloud server abbrs

---

### 8. Create Backlog Item for hsb2 Setup

**File:** `hosts/hsb2/docs/backlog/P70.<hash>.tailscale-network-setup.md`

**Content:**

```markdown
# Tailscale & Network Setup for hsb2

**Host**: hsb2
**Priority**: P70
**Status**: Backlog
**Created**: 2026-02-10

---

## Problem

hsb2 runs Raspbian (not NixOS), so cannot be configured declaratively via nixcfg. Need manual Tailscale installation and network setup to integrate with fleet.

## Solution

1. Install Tailscale on Raspbian manually
2. Join headscale network
3. Test LAN/Tailscale connectivity
4. Document manual setup steps for future reference

## Implementation

- [ ] SSH to hsb2: `ssh mba@192.168.1.95`
- [ ] Install Tailscale: `curl -fsSL https://tailscale.com/install.sh | sh`
- [ ] Generate auth key from csb0: `ssh mba@cs0.barta.cm -p 2222 "docker exec headscale headscale preauthkeys create --user markus --reusable --expiration 87600h"`
- [ ] Join network: `sudo tailscale up --login-server https://hs.barta.cm --authkey <KEY>`
- [ ] Verify connectivity: `tailscale status`
- [ ] Test from another host: `ssh mba@hsb2.ts.barta.cm`
- [ ] Add hsb2 to `modules/shared/ssh-fleet.nix` (after Tailscale works)
- [ ] Add hsb2 fish/bash alias
- [ ] Document in `hosts/hsb2/README.md`

## Acceptance Criteria

- [ ] hsb2 appears in `tailscale status` on all nodes
- [ ] Can SSH via `ssh hsb2.ts.barta.cm`
- [ ] LAN connection still works (192.168.1.95)
- [ ] Documentation updated

## Notes

- hsb2 is ARMv6l (512MB RAM) - keep Tailscale config minimal
- WiFi-only (no ethernet) - ensure stable connection before setup
- Manual setup means this host won't benefit from declarative config updates
```

---

## Testing Plan

### Phase 1: Local Testing (at home)

```bash
# 1. Deploy to imac0 (current machine)
cd ~/Code/nixcfg
home-manager switch --flake .#imac0

# 2. Test LAN connections
ssh hsb0         # → Should connect via 192.168.1.99 (fast)
ssh hsb0-lan     # → Force LAN
ssh hsb0-ts      # → Force Tailscale

# 3. Test cloud hosts
ssh csb0         # → Should connect via Tailscale only

# 4. Test nicknames
ssh mbpw         # → Should resolve to mba-mbp-work
ssh imacw        # → Should resolve to mba-imac-work
ssh msbp         # → Should resolve to miniserver-bp

# 5. Test zellij auto-attach
hsb0             # → Should attach to zellij session named "hsb0"
# Exit zellij, reconnect
hsb0             # → Should reattach to same session

# 6. Test bash aliases
bash
hsb0             # → Should work in bash too
```

### Phase 2: Remote Testing (coffee shop / cellular)

```bash
# 1. Disconnect from home WiFi, connect to mobile hotspot

# 2. Test auto-fallback
ssh hsb0         # → Should try LAN (2s), fallback to Tailscale

# 3. Verify all home hosts accessible
ssh hsb1
ssh hsb8
ssh gpc0

# 4. Verify cloud hosts still work
ssh csb0
ssh csb1
```

### Phase 3: Automation Testing

```bash
# 1. Test plain SSH (no zellij)
ssh hsb0 uptime              # → Should work
ssh hsb0-lan uptime          # → Force LAN
ssh hsb0-ts uptime           # → Force Tailscale

# 2. Test from bash script
cat > /tmp/test-ssh.sh <<'EOF'
#!/bin/bash
ssh hsb0 "echo 'Test from bash script'"
EOF
chmod +x /tmp/test-ssh.sh
/tmp/test-ssh.sh             # → Should work

# 3. Verify config syntax
ssh -G hsb0                  # → Show computed SSH config
```

---

## Acceptance Criteria

- [ ] All NixOS hosts have SSH config managed declaratively
- [ ] LAN connections work when on same network (fast, <1s)
- [ ] Tailscale fallback works when remote (2-3s delay acceptable)
- [ ] Fish abbreviations work (zellij auto-attach)
- [ ] Bash aliases work (zellij auto-attach)
- [ ] Nicknames resolve correctly (mbpw → mba-mbp-work, etc.)
- [ ] Explicit routes work (`-lan`, `-ts` suffixes)
- [ ] Plain SSH works (no zellij): `ssh hsb0 uptime`
- [ ] Old fish backup configs removed
- [ ] Documentation updated (INFRASTRUCTURE.md)
- [ ] Help function (`h`) shows updated SSH shortcuts
- [ ] All tests pass (Phase 1, 2, 3)
- [ ] hsb2 backlog item created

---

## File Changes Summary

### New Files

1. `modules/shared/ssh-fleet.nix` - SSH config with LAN→TS fallback
2. `hosts/hsb2/docs/backlog/P70.<hash>.tailscale-network-setup.md` - hsb2 manual setup task

### Modified Files

1. `modules/uzumaki/fish/config.nix` - Update SSH abbrs (lines 70-77)
2. `modules/common.nix` - Add ssh-fleet import + bash aliases
3. `modules/uzumaki/fish/functions.nix` - Update help output (~line 326)
4. `docs/INFRASTRUCTURE.md` - Document nicknames and fallback behavior

### Deleted Files

1. `~/.config/fish/config.fish.backup` - Old fish abbrs (qc99, qc24, etc.)
2. `~/.config/fish/config.fish~` - Old fish backup

---

## Notes

### Implementation Notes

1. **IPs Confirmed:**
   - imac0: 192.168.1.150
   - mba-imac-work: 10.17.1.7

2. **Verify Tailscale hostnames match:**
   - Run `tailscale status` to confirm hostnames
   - Ensure `mba-mbp-work` (not `mbpw`) is registered in headscale

### Design Decisions

- **NO ControlMaster** - Avoiding connection multiplexing for now (complexity/risk)
- **2s timeout** - Acceptable delay for remote LAN probes
- **ServerAliveInterval 60s** - Keep connections alive
- **ProxyCommand with nc** - Simple, reliable fallback mechanism
- **Zellij always attached** - Consistent UX, session persistence

### Risks

1. **2s delay on remote connections** - Mitigated by explicit `-ts` routes
2. **ProxyCommand requires netcat** - Standard on all systems, low risk
3. **Stale connections after network switch** - Resolved by 60s keepalive + 3min timeout
4. **User confusion with nicknames** - Mitigated by help function + documentation

---

## Next Steps

**Awaiting user confirmation: "go" to proceed with implementation**

Once approved:

1. Create `modules/shared/ssh-fleet.nix`
2. Update fish config
3. Update common.nix
4. Update documentation
5. Cleanup old configs
6. Create hsb2 backlog item
7. Test all phases
8. Commit and push
