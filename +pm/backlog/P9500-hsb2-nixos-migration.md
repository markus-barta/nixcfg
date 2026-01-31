# P9500 - HSB2: Raspberry Pi Zero W Migration (NixOS)

## Status: 🔴 FAILED (Blocked by Cross-Compilation)

Migration of `hsb2` (Raspberry Pi Zero W) from Raspbian to NixOS is currently blocked. Multiple build strategies were attempted on `gpc0` (x86_64 build host), but none succeeded.

## Attempted Strategies & Results

| Strategy                 | Tooling                | Result     | Failure Reason                                                                                                    |
| :----------------------- | :--------------------- | :--------- | :---------------------------------------------------------------------------------------------------------------- |
| **1. Remote Deploy**     | `nixos-anywhere`       | ❌ Skipped | Likely to fail due to 512MB RAM and poor `kexec` support on ARMv6l.                                               |
| **2. Virtualized Build** | `diskoImages` (QEMU)   | ❌ Failed  | QEMU VM ran out of space repeatedly, even at 32GB image size. Extremely slow.                                     |
| **3. Native SD Image**   | `sd-image-raspberrypi` | ❌ Failed  | Cross-compilation of the RPi1 kernel (`bcmrpi_defconfig`) is broken in current `nixpkgs` when building on x86_64. |

## Current Configuration State

- **Host Config**: `hosts/hsb2/configuration.nix` is structured to use `disko` for disk management but currently has it commented out to avoid conflicts with the native `sdImage` builder.
- **Hardware Config**: `hosts/hsb2/hardware-configuration.nix` contains the necessary `hostPlatform` and `buildPlatform` settings for cross-compilation.
- **Disk Config**: `hosts/hsb2/disk-config.nix` uses a GPT/ext4 layout compatible with `disko`.

## Blockers

1. **Kernel Cross-Compilation**: `nixpkgs` fails to find `bcmrpi_defconfig` when cross-compiling from x86_64. This appears to be an upstream issue or a mismatch in how the Raspberry Pi kernel is defined for ARMv6l.
2. **Resource Constraints**: The Pi Zero W's 512MB RAM makes on-device building or `nixos-anywhere` high-risk.

## Recommended Next Steps

1. **Manual Image Build**: Attempt to build the SD image on a native ARM machine if available.
2. **Upstream Fix**: Investigate why `bcmrpi_defconfig` is missing in the cross-compilation environment.
3. **Alternative Kernel**: Try using a generic kernel instead of the RPi-specific one, though this may lose hardware-specific optimizations.

## References

- **Host**: `hsb2` (192.168.1.95)
- **Target Arch**: `armv6l-linux`
- **Build Host**: `gpc0` (x86_64-linux)
