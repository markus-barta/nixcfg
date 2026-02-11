# wake-on-lan

**Host**: gpc0
**Priority**: P63
**Status**: Blocked - Driver Limitation
**Created**: 2024-12-04

---

## Problem

Want to enable Wake-on-LAN on gpc0 (Gaming PC) for remote power-on. Hardware supports WOL (confirmed via PCI PM capabilities), but **mainline Linux `alx` driver does NOT support WOL**. Requires patched kernel module.

## Solution

Apply out-of-tree patch to re-enable WOL support in `alx` driver. WOL was disabled in mainline due to unresolved double-wakeup bug (~2013).

## Implementation

### Option A: Patch via Nix Kernel (Recommended)

- [ ] Download split patches for kernel 6.x from LinuxQuestions or GitHub (AndiWeiss/alx-wol)
- [ ] Add patches to `hosts/gpc0/patches/` directory
- [ ] Update `hosts/gpc0/configuration.nix` with `boot.kernelPatches`:
  - Add alx-wol-main.patch
  - Add alx-wol-hw.patch (if needed)
- [ ] Rebuild kernel: `nixos-rebuild switch --upgrade`
- [ ] Verify `ethtool enp9s0` shows "Supports Wake-on: pg"
- [ ] Enable WOL: `ethtool -s enp9s0 wol g`
- [ ] Create systemd service to enable WOL on boot
- [ ] Add `pkgs.ethtool` to `environment.systemPackages`

### Testing & Verification

- [ ] Test from imac0: `wakeonlan 4C:CC:6A:B2:3E:38`
- [ ] Verify gpc0 wakes from power-off state
- [ ] Document in README and RUNBOOK

## Acceptance Criteria

- [ ] Patch applied to alx driver
- [ ] Kernel rebuilt with patched module
- [ ] `ethtool enp9s0` shows "Supports Wake-on: pg"
- [ ] `ethtool -s enp9s0 wol g` succeeds
- [ ] WOL service enabled at boot
- [ ] Test WOL from imac0 successful
- [ ] gpc0 wakes from power-off

## Notes

### Hardware Details

- **NIC**: Qualcomm Atheros Killer E2400 Gigabit Ethernet (AR8171/AR816x)
- **PCI**: 09:00.0
- **Driver**: alx (module: CONFIG_ALX=m)
- **Kernel**: 6.17.9
- **Interface**: enp9s0
- **MAC**: 4C:CC:6A:B2:3E:38
- **Current IP**: 192.168.1.154 (DHCP)

### Hardware WOL Support (Confirmed)

```
PME# supported from D0 D1 D2 D3hot D3cold
```

NIC can wake from all power states including D3cold (fully powered off).

### Current Investigation Results

- ✅ Hardware PME support confirmed
- ✅ ACPI wakeup enabled for PCIe slot
- ✅ Device power wakeup enabled
- ✅ NetworkManager has `wake-on-lan: magic` configured
- ❌ `ethtool` shows NO WOL capability (driver disabled)
- ❌ `ethtool -s enp9s0 wol g` fails: "Operation not supported"

### Patch Sources

- **Best**: https://github.com/AndiWeiss/alx-wol (v3.1 for kernels 6.5+)
- **Original**: https://bugzilla.kernel.org/attachment.cgi?id=300398 (2013, needs adaptation)
- **Bug Report**: https://bugzilla.kernel.org/show_bug.cgi?id=61651
- **AUR**: https://aur.archlinux.org/packages/alx-wol-dkms
- **Split Patches (6.x)**: https://www.linuxquestions.org/questions/slackware-14/alx-wol-working-in-6-1-x-4175722247/

### Kernel Compatibility Issues

- Patch from 2013 may not apply cleanly to kernel 6.17
- Use split patches for 6.x kernels
- May need to undefine `PCI_IRQ_LEGACY` in `main.c`
- On kernels <6.5: Setting `wol d` may break interface on wake

### Testing Recommendation

Test on Ubuntu live USB with DKMS package first to validate patch works on this hardware before making NixOS changes.

### Alternative: Downgrade Kernel (Fallback)

If patching fails, WOL wasn't disabled in kernels ≤5.14:

```nix
boot.kernelPackages = pkgs.linuxPackages_5_10;
```

### Priority & Risk

- **Priority**: 🟢 LOW (convenience feature, gpc0 not critical infrastructure)
- **Effort**: HIGH (kernel patching, 3+ hours compile time)
- **Risk**: Requires physical access for first application
- **Benefit**: Remote wake for future updates

### Community Resources

- Reddit: https://www.reddit.com/r/NixOS/comments/1iqip55/enabling_wakeonlan_on_alx_network_cards/
- Proxmox Forum: https://forum.proxmox.com/threads/atheros-killer-e2400-ethernet-controller-wol-need-help.153631/
