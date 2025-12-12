# 2025-12-07 - gpc0 Headless Boot (TV Off)

## Status: ✅ COMPLETE (2025-12-07)

## Problem

When gpc0 boots without the TV on, it **appears** to hang at:

```
[ OK ] Reached target Graphical Interface.
```

## Analysis (2025-12-07)

**NOT A HANG!** The system boots completely fine in ~9 seconds:

```
graphical.target @8.899s
└─multi-user.target @8.898s
  └─docker.service @6.820s +2.078s
```

### What's Actually Happening

| Observation                                        | Reality                         |
| -------------------------------------------------- | ------------------------------- |
| Console shows "Reached target Graphical Interface" | Boot completed successfully     |
| No visual progress                                 | SDDM is waiting at login screen |
| System seems dead                                  | Fully operational (SSH works)   |

### Root Cause

- SDDM starts and displays login screen
- TV is off → can't see the login screen
- Last console message stays visible (nothing draws over it)
- **No autologin configured** → waits forever for login

### Hardware Info

- **GPU**: AMD (amdgpu driver)
- **Display**: HDMI-A-1 shows "connected" even with TV off
- **No failures**: All systemd units running correctly

## Solution: Enable Autologin

Add autologin so Plasma starts automatically:

```nix
# hosts/gpc0/configuration.nix
services.displayManager.autoLogin = {
  enable = true;
  user = "mba";
};
```

This way:

- System boots → SDDM starts → auto-logs in mba → Plasma starts
- When you turn on TV, desktop is already ready
- No more waiting at invisible login screen

## Alternative Solutions

1. **Wake-on-LAN** - Only boot when needed (see `2025-12-03-gpc0-wake-on-lan.md`)
2. **Virtual console autologin** - Less elegant, TTY instead of Plasma

## Acceptance Criteria

- [x] Add autologin configuration
- [x] Add KDE Wallet PAM integration
- [x] Document in configuration.nix with rationale
- [x] Update README.md with autologin section
- [x] Test: Boot with TV off, turn on TV → desktop ready ✅ PASSED (2025-12-07)
