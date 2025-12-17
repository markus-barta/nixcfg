# hsb0 WiFi Enablement

**Status:** Cancelled  
**Date:** 2025-12-02  
**Host:** hsb0 (Mac mini 2011)  
**Reason:** Not needed - Gigabit Ethernet is primary/faster connection

---

## Summary

hsb0 has a Broadcom BCM4331 WiFi chip (Apple AirPort) that is NOT currently enabled. Investigation revealed it's possible but complex, with known stability issues. Since hsb0 uses Gigabit Ethernet as primary connection, WiFi enablement was deprioritized.

---

## Hardware Detection

```text
[   11.122672] b43-phy0: Broadcom 4331 WLAN found (core revision 29)
[   11.123092] b43-phy0: Found PHY: Analog 9, Type 7 (HT), Revision 1
[   11.123106] b43-phy0: Found Radio: Manuf 0x17F, ID 0x2059, Revision 0, Version 1
[   11.123110] b43-phy0 warning: 5 GHz band is unsupported on this PHY
```

| Item          | Value                         |
| ------------- | ----------------------------- |
| **Chip**      | Broadcom BCM4331              |
| **Card**      | Apple AirPort                 |
| **Mac Model** | Macmini5,1 / 5,2 / 5,3 (2011) |
| **5 GHz**     | Not supported by b43 driver   |

---

## Two Driver Options

### Option 1: `b43` (Open Source)

**Current state:** Driver loaded, firmware missing.

```text
b43-phy0 ERROR: Firmware file "b43/ucode29_mimo.fw" not found
```

**To enable:**

```nix
hardware.firmware = [ pkgs.b43Firmware_6_30_163_46 ];
```

**Pros:** Open source, in-tree driver  
**Cons:** No 5 GHz support, potentially less stable than wl

### Option 2: `broadcom_sta` / `wl` (Proprietary) — RECOMMENDED

**This is the better option for Mac mini 2011.**

```nix
{
  nixpkgs.config.allowUnfree = true;
  boot.extraModulePackages = [ config.boot.kernelPackages.broadcom_sta ];
  boot.kernelModules = [ "wl" ];
  boot.extraModprobeConfig = "options wl disable_bar=1";  # helps Bluetooth
  boot.blacklistedKernelModules = [ "b43" "bcma" "ssb" "brcmsmac" ];
  boot.kernelParams = [ "pcie_aspm=off" ];  # Optional but recommended

  # Fix WiFi after suspend/resume
  powerManagement.resumeCommands = ''
    modprobe -r wl && modprobe wl || true
  '';
}
```

---

## Known Issues & Fixes (Mac mini 2011 + BCM4331)

### 1. WiFi Unstable / Constant Drops

Most common issue with `wl` on this model.

**Fix:** Use NixOS 24.05+ or unstable — the patched `broadcom_sta` package is included by default since ~mid-2023.

### 2. No WiFi Until EFI Whitelist Disabled

Mac mini 2011 refuses third-party drivers from EFI unless patched.

**One-time fix** (from macOS or live USB):

```bash
sudo perl -i.bak -pe 's|\x73\x05\x00\x75\x6d|\x73\x05\x00\x74\x6d|s' \
  /System/Library/CoreServices/PlatformSupport.plist
```

Or use: https://github.com/dokmic/apple-efi-whitelist-disable

### 3. Bluetooth Conflicts

The BCM4331 is a combo WiFi+Bluetooth card sharing one USB bus. The `wl` driver sometimes hogs the bus.

**Workarounds:**

- Add kernel parameter: `pcie_aspm=off`
- Load `wl` with `disable_bar=1` option (shown in config above)
- Use external USB Bluetooth dongle

### 4. Sleep/Wake Breaks WiFi

WiFi disappears after suspend/resume.

**Fix:** Reload module on resume (shown in config above).

---

## Complete NixOS Configuration (If Needed)

```nix
# hosts/hsb0/configuration.nix - WiFi enablement (CURRENTLY DISABLED)
{
  # Uncomment to enable WiFi on Mac mini 2011

  # nixpkgs.config.allowUnfree = true;  # Already set for other packages

  # boot.extraModulePackages = [ config.boot.kernelPackages.broadcom_sta ];
  # boot.kernelModules = [ "wl" ];
  # boot.extraModprobeConfig = "options wl disable_bar=1";
  # boot.blacklistedKernelModules = [ "b43" "bcma" "ssb" "brcmsmac" ];
  # boot.kernelParams = [ "pcie_aspm=off" ];

  # powerManagement.resumeCommands = ''
  #   modprobe -r wl && modprobe wl || true
  # '';

  # networking.wireless.enable = true;  # wpa_supplicant
  # OR
  # networking.networkmanager.enable = true;
}
```

---

## Why Cancelled

1. **Not needed** — hsb0 uses Gigabit Ethernet (faster than 2.4 GHz WiFi)
2. **Complexity** — Requires EFI patch, driver configuration, potential Bluetooth conflicts
3. **Stability concerns** — Known issues with sleep/wake, random disconnects
4. **Original use case gone** — WiFi frequency monitoring script was for raspi's WiFi connection, not hsb0's

---

## References

- https://wireless.docs.kernel.org/en/latest/en/users/drivers/b43/
- https://github.com/dokmic/apple-efi-whitelist-disable
- NixOS Wiki: Broadcom WiFi
- Grok analysis (2025-12-02)

---

## To Resurrect This

1. Apply EFI whitelist patch (one-time, requires macOS or live USB)
2. Add the `broadcom_sta` configuration above
3. Blacklist `b43` driver
4. Test stability before relying on it
