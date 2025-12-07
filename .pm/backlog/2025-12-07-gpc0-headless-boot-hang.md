# 2025-12-07 - gpc0 Headless Boot Hang

## Status: BACKLOG (Active)

## Problem

When gpc0 boots without the TV being turned on, the system hangs at:

```
[ OK ] Reached target Graphical Interface.
```

The boot sequence completes up to "Graphical Interface" but then stops, likely waiting for a display.

## Symptoms

- Boot hangs when TV is off
- All services start OK (Docker, ZFS, etc.)
- Stops at "Reached target Graphical Interface"
- Likely SDDM/display manager waiting for display

## Possible Causes

1. **SDDM waiting for display** - Display manager may block waiting for connected display
2. **GPU driver issue** - NVIDIA/AMD driver waiting for display handshake
3. **Plymouth/boot splash** - May be waiting for framebuffer

## Potential Solutions

1. **Configure SDDM for headless boot** - Add virtual display fallback
2. **Add dummy display output** - Force GPU to see a display
3. **Disable graphical target on boot** - Boot to multi-user, start X on demand
4. **EDID emulation** - Fake display EDID data

## Investigation Steps

- [ ] Check what display manager is configured
- [ ] Check GPU type (NVIDIA/AMD/Intel)
- [ ] Review systemd boot logs: `journalctl -b`
- [ ] Check if SSH is available during hang
- [ ] Test with `systemctl isolate multi-user.target`

## Notes

- gpc0 is a gaming PC, likely has dedicated GPU
- TV as primary display = no always-on monitor
- Need solution that allows headless boot but still works when TV is on
