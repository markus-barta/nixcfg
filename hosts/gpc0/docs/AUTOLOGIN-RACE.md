# gpc0 Autologin Failure — kmscon vs Wayland DRM Race

## TL;DR

After a `nixos-rebuild boot` + reboot on 2026-04-30, gpc0 stopped
auto-logging into Plasma. SDDM fired autologin successfully, but the
Plasma Wayland session died ~58 seconds later because `kwin_wayland`
could not open `/dev/dri/card1` (EBUSY) — the AMD GPU's only DRM node
was held by something else during early boot. SDDM regreeted and asked
for a password, which works.

**Suspected culprit**: `services.kmscon.extraConfig` was set on this
host, which causes `kmsconvt@tty1.service` to take ownership of the
DRM node on tty1 — exactly where SDDM puts its autologin session.

**Fix**: kmscon is commented out in `configuration.nix`. The kernel
console (`console.font = terminus 20n`) already gives a readable
big-font tty1 without kmscon, and on a Plasma desktop machine kmscon
is rarely seen anyway.

**Rollback**: uncomment the line, `nixos-rebuild boot`, reboot.

## Symptoms (Observed 2026-04-30)

1. After GRUB and a brief boot animation, the screen showed multiple
   `login:` prompts stacked vertically (~10 lines).
2. After ~1 minute, SDDM's Plasma greeter appeared on a different VT.
3. Manual login with the user's password worked normally.
4. Subsequent reboots are expected to behave the same way until the
   timing race is resolved.

## Root-Cause Analysis

### What the journal showed

`journalctl -b 0` for the failed boot (timestamps trimmed):

```
22:06:52  sddm[4819]: Adding new display...
22:06:52  sddm-helper[4867]: pam_unix(sddm-autologin:session): session opened for user mba
22:06:53  sddm-helper[4867]: pam_kwallet5: open_session called without kwallet5_key
22:06:53  sddm-helper[4867]: Starting Wayland user session: ...startplasma-wayland
22:06:54  systemd[4904]: Started KDE Wayland Compositor.
22:06:54  kwin_wayland[5933]: No backend specified, automatically choosing drm
22:06:54  kwin_wayland[5933]: Failed to open /dev/dri/card1 device (Device or resource busy)
[...same line repeats ~70 times across 58 seconds...]
22:07:51  sddm-helper[4867]: pam_unix(sddm-autologin:session): session closed for user mba
22:07:51  sddm[4819]: Greeter starting...                  ← password screen
22:08:15  sddm[4819]: Authentication for user "mba" successful  ← user typed password
```

The autologin path **did fire**. PAM opened the session. Plasma's
systemd user manager started KWin. KWin failed to acquire the GPU and
spun for a minute on `EBUSY`, after which the user session collapsed
and SDDM regreeted.

### Why card1, not card0

This box has an AMD Radeon RX 9070 XT. The kernel currently exposes
the GPU as `/dev/dri/card1` (with `renderD128` for headless render
clients). There is **no** `card0` — `ls /dev/dri/` confirms only one
card. So this is not "two GPUs racing" — it is "one GPU, two
processes both want exclusive modeset on it".

### Who was holding card1 during the failed window

By the time we logged in and inspected (after the manual login), card1
was held cleanly by `kwin_wayland` and `Xwayland` for the active
Plasma session, and `kmsconvt@tty1.service` was `inactive (dead)`. The
race window had already cleared.

The most likely holder during the failed window is
`kmsconvt@tty1.service`. It is a kmscon instance that takes over
tty1's KMS modeset to render its bigger font, and tty1 is exactly the
VT SDDM picked (`Using VT 1` in the journal). When SDDM-autologin
launched kwin on the same VT, kwin tried to claim the same DRM node
and got EBUSY for as long as kmscon held it.

There is a secondary hypothesis (amdgpu firmware/DC subsystem still
initializing this early in boot, refusing modeset to a second
client). We cannot fully rule it out from the journal alone, but the
timing fits kmscon better:

- The failure window is bounded (~58s) — consistent with a userspace
  service eventually exiting on idle, less consistent with a driver
  that is still busy.
- After the autologin session collapsed, kwin grabbed card1 cleanly
  on the next greeter — no driver-readiness wait was needed.
- `kmsconvt@tty1.service` is `loaded inactive dead` _after_ boot,
  matching "ran during boot, then exited".

### Why this didn't happen before

The recent `nixos-rebuild boot` pulled in a nixpkgs bump that updated
some combination of kmscon, sddm, kwin, kernel, and amdgpu firmware.
Boot timing shifted by milliseconds and the autologin path now
consistently lands on the wrong side of the race.

## Solution

Disable kmscon by commenting out the only line that configures it:

```nix
# services.kmscon.extraConfig = "font-size = 26";
```

`console.font = "${pkgs.terminus_font}/share/consolefonts/ter-u20n.psf.gz";`
already provides a readable big-font kernel console on tty1, so the
day-to-day experience is unchanged. On a Plasma desktop machine,
kmscon's KMS-based console is rarely seen anyway — the tty switch
fallback path is enough.

This removes one userspace process from the early-boot DRM contention
on tty1 and should let kwin acquire `/dev/dri/card1` immediately on
autologin.

## Rollback

If autologin still fails on the next reboot, the kmscon change is not
the root cause. Uncomment the line:

```nix
services.kmscon.extraConfig = "font-size = 26";
```

Then `sudo nixos-rebuild boot --flake ~/Code/nixcfg#gpc0` and reboot.

If the autologin race persists with kmscon disabled, the next things
to try are:

1. Add a systemd `After=systemd-modules-load.service` ordering hint to
   `display-manager.service` so SDDM autologin waits for amdgpu module
   load to fully settle.
2. Pin SDDM's autologin to a different VT than the one Plymouth /
   getty / kmscon may be touching (e.g. `services.displayManager.sddm.settings.X11."X-Greeter".VTNumber = 7;`).
3. Disable Plymouth (if enabled) so it doesn't keep the framebuffer
   during the SDDM handoff.

## Verification After Reboot

On the next boot:

```
ssh mba@gpc0.lan
sudo journalctl -b 0 | grep -c "Failed to open /dev/dri/card1"
# expect: 0
systemctl is-active display-manager.service
# expect: active
loginctl list-sessions
# expect: a session for user mba on tty1 / VT2 with type=wayland
```

If the count is `0` and a Plasma session for `mba` shows up without
manual login, the fix worked.

## References

- This file: `hosts/gpc0/docs/AUTOLOGIN-RACE.md`
- Linked from: `hosts/gpc0/configuration.nix` (kmscon block)
