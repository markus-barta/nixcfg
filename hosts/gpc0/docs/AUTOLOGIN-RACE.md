# gpc0 SDDM Autologin Race — Unresolved

## TL;DR

After a `nixos-rebuild boot` + reboot on 2026-04-30, gpc0 stopped
auto-logging into Plasma. SDDM fires autologin successfully (PAM opens
the session), but `kwin_wayland` cannot open `/dev/dri/card1` (the AMD
GPU's only DRM node). KWin retries for ~5s, exits with "No suitable
DRM devices have been found", SDDM respawns it, the cycle repeats
~20 times. After enough failures SDDM gives up and shows the password
greeter — and the greeter's own KWin (running as user `sddm`) gets
`card1` immediately and renders fine. Manual login works normally.

**We tried**: disabling kmscon (suspected of holding `card1` on tty1).
**Result**: did not fix it. kmscon was already `inactive (dead)`
during the failure window, so it was never the culprit.

**Current decision**: live with the password screen. Manual login is
~3 seconds of typing and otherwise the system is healthy. Autologin
race is left unresolved pending more investigation. kmscon stays
commented out as a small cleanup (no day-to-day visual change because
`console.font = terminus 20n` already gives a readable big-font tty).

**Rollback** (uncomment kmscon if you want it back):

```nix
services.kmscon.extraConfig = "font-size = 26";
```

…then `sudo nixos-rebuild boot --flake ~/Code/nixcfg#gpc0` and reboot.

## Symptoms (Observed 2026-04-30)

1. After GRUB and a brief boot animation, the screen shows multiple
   `login:` prompts stacked vertically (~10 lines) — these are KWin
   respawn cycles redrawing the VT.
2. After ~1 minute, SDDM's Plasma greeter appears on a different VT
   asking for the password.
3. Manual login with the user's password works normally and Plasma
   comes up cleanly. KWin holds `card1` for the rest of the session
   without issue.
4. Reboots are deterministic — every boot lands the same way until
   the underlying race is resolved.

## Investigation Timeline

### What the journal shows (canonical, this happens every boot now)

`journalctl -b 0` for any failed-autologin boot:

```
22:29:12  sddm-helper[...]: pam_unix(sddm-autologin:session): session opened for user mba
22:29:12  sddm-helper[...]: Starting Wayland user session: ...startplasma-wayland
22:29:12  systemd[...]: Started KDE Wayland Compositor.
22:29:12  kwin_wayland[2737]: No backend specified, automatically choosing drm
22:29:12  kwin_wayland[2737]: Failed to open /dev/dri/card1 device (Device or resource busy)
[... ~25 EBUSY retries within this kwin instance over ~5s ...]
22:29:17  kwin_wayland[2737]: Failed to open drm device /dev/dri/card1
22:29:17  kwin_wayland[2737]: No suitable DRM devices have been found
22:29:17  kwin_wayland[2737]: QThreadStorage: entry 7 destroyed before end of thread
[ kwin instance 2737 exits ]
22:29:17  kwin_wayland[3351]: No backend specified, automatically choosing drm
[ same pattern, new PID ]
22:29:22  kwin_wayland[3351]: Failed to open drm device /dev/dri/card1
22:29:22  kwin_wayland[3351]: No suitable DRM devices have been found
[ ... repeat with 3376, 3411, 3435, ... ~18 instances total ... ]
[ ~90s later ]
sddm[...]: Greeter starting...                  ← password screen
sddm[...]: Authentication for user "mba" successful  ← user typed password
```

Counting: ~540 `Failed to open /dev/dri/card1 device (Device or
resource busy)` lines per boot, across ~18 distinct kwin_wayland
processes. Each instance retries for ~5 seconds, exits with "No
suitable DRM devices", and SDDM (or the systemd user manager)
respawns it. After enough failures, SDDM gives up and starts the
greeter.

### Why card1, not card0

This box has an AMD Radeon RX 9070 XT. The kernel exposes the GPU as
`/dev/dri/card1` (with `renderD128` for headless render clients).
There is no `card0` — `ls /dev/dri/` confirms only one card. So this
is one GPU, not "two GPUs racing" — it is a single-DRM-node access
race.

### Who is _not_ the culprit

We ruled these out by inspecting the live system after the failed
autologin (while sitting at the SDDM password greeter):

- **kmscon** — `kmsconvt@tty1.service` is `loaded inactive (dead)`
  both during the failure window and after. The service is not
  actually running, so it is not holding `card1`. Disabling it via
  `services.kmscon.extraConfig` comment-out had **no effect** on the
  EBUSY count (in fact the count went _up_, from ~70 on the first
  failed boot to ~540 on the post-fix boot — purely because SDDM had
  more time to spin up respawn cycles before giving up).
- **Plymouth** — `plymouth-start.service`, `plymouth-quit.service`,
  and `plymouth-quit-wait.service` are all `inactive`. Not enabled
  on this host.
- **getty on tty1** — masked by SDDM. No `getty@tty1.service` in the
  unit list.

### Who _is_ the culprit (best current hypothesis)

Most likely candidate: **the autologin path's `kwin_wayland` is being
launched too early** — before the amdgpu kernel driver and
`/dev/dri/card1` are fully ready to serve a non-root userspace KMS
client. Once SDDM gives up and starts the greeter, enough wall-clock
time has passed that the device has settled, and the greeter's KWin
(running as user `sddm`) gets `card1` on first try.

Evidence supporting this:

- The greeter's KWin succeeds **the same boot** that the autologin's
  KWin failed 18 times. Same hardware, same kernel, same GPU — only
  the wall-clock time and the launching context differ.
- The EBUSY error means the device file _exists_ but the kernel is
  refusing to grant exclusive modeset to this caller right now.
- AMD Plasma 6 + Wayland autologin races on amdgpu are
  well-documented in the wider community (KDE/Plasma Bugzilla, NixOS
  Discourse, Arch forums). There is no canonical fix yet; common
  workarounds are systemd ordering hints, VT pinning, or disabling
  autologin.

This is a hypothesis, not proven. To prove it we would need to either
(a) trace exactly what process the kernel thinks holds `card1` during
the failure window, or (b) measure how long after `amdgpu` module
load the device becomes openable for an unprivileged user.

### Why this didn't happen before

The recent `nixos-rebuild boot` pulled in a nixpkgs bump that updated
some combination of kernel, amdgpu firmware, kwin, and SDDM. Boot
timing shifted by milliseconds and the autologin path now consistently
lands on the wrong side of the race.

## Decision

**Live with the password screen.** Manual login at SDDM is reliable
(~3s of typing) and the rest of the system is healthy. Bosun,
watchtower, and Plasma all work normally once logged in. This is a
personal gaming PC, not infrastructure — the cost-benefit of further
debugging does not justify the time investment right now.

The kmscon comment-out is left in place as a tiny cleanup (one fewer
moving part on the boot path) even though it did not solve the race.
`console.font = terminus 20n` continues to provide a readable kernel
console on tty1.

## Future Investigation Paths

If autologin becomes worth fixing later, in order of expected
effort/impact:

1. **Disable autologin entirely** in `services.displayManager.autoLogin`
   — confirms the issue is autologin-specific (not boot-time DRM
   readiness in general). One-line config change.

2. **Pin SDDM autologin to a different VT** —
   `services.displayManager.sddm.settings.X11."X-Greeter".VTNumber = 7;`
   or similar Wayland setting. Might dodge the race if it's tty1-bound.

3. **Add systemd ordering hint** to delay `display-manager.service`
   until `systemd-modules-load.service` is fully done plus a small
   sleep, giving amdgpu time to settle.

4. **Switch SDDM to Wayland greeter** (already on Wayland) but try
   the X11 greeter instead — different DRM access path, might dodge
   the race entirely.

5. **Capture `lsof /dev/dri/card1` during the race** via a oneshot
   systemd unit triggered on `display-manager.service` start, so
   future-you knows definitively what is holding the device.

6. **Bisect nixpkgs** to find the exact change that introduced the
   race — useful only if upstream owns the fix.

## Verification After Fix (when there is one)

On the next boot:

```
ssh mba@gpc0.lan
sudo journalctl -b 0 | grep -c "Failed to open /dev/dri/card1"
# expect: 0  (or single-digit if there is a brief race that resolves)
systemctl is-active display-manager.service
# expect: active
loginctl list-sessions
# expect: a session for user mba (CLASS=user, TTY=tty1 or tty2),
#         not a session for user sddm (greeter)
```

If the count is `0` and a session for `mba` shows up without manual
login, the race is resolved.

## References

- This file: `hosts/gpc0/docs/AUTOLOGIN-RACE.md`
- Linked from: `hosts/gpc0/configuration.nix` (kmscon block)
- Investigation: 2026-04-30 conversation with Claude (sessions for
  fleetcom-bosun rollout + post-reboot dbus-broker switch).
