# gpc0 Wake-on-LAN Configuration

## Status: BLOCKED — Driver Limitation

**The mainline Linux `alx` driver does NOT support Wake-on-LAN.** Requires patched kernel module.

## Description

Enable Wake-on-LAN on gpc0 (Gaming PC) so it can be remotely powered on via magic packets.

### Key Insight

The hardware 100% supports WOL — the PCI capabilities and kernel messages confirm it. The only blocker is the alx driver deliberately not exposing the WOL interface to userspace.
Since the driver is a module (CONFIG_ALX=m) rather than built-in, patching could potentially be done by just replacing the module rather than rebuilding the entire kernel — though NixOS typically rebuilds anyway.

## Hardware Details

| Component   | Value                                          |
| ----------- | ---------------------------------------------- |
| NIC         | Qualcomm Atheros Killer E2400 Gigabit Ethernet |
| PCI         | `09:00.0`                                      |
| Chipset     | AR8171/AR816x                                  |
| Driver      | `alx` (module: `CONFIG_ALX=m`)                 |
| Kernel      | 6.17.9                                         |
| NixOS       | 26.05.20251127.2fad6ea (Yarara)                |
| Motherboard | MSI Z170A GAMING M3 (MS-7978) v2.0             |
| BIOS        | American Megatrends A.D0 (2018-07-04)          |
| Interface   | `enp9s0`                                       |
| MAC Address | `4C:CC:6A:B2:3E:38`                            |
| Current IP  | `192.168.1.154` (DHCP via NetworkManager)      |

### Hardware WOL Capability (Confirmed)

The hardware **does support WOL** — confirmed via PCI PM capabilities:

```text
Capabilities: [40] Power Management version 3
    Flags: PMEClk- DSI- D1- D2- AuxCurrent=375mA PME(D0+,D1+,D2+,D3hot+,D3cold+)

# Kernel confirms PME support:
pci 0000:09:00.0: PME# supported from D0 D1 D2 D3hot D3cold
```

This proves the NIC can generate wake events in all power states including D3cold (fully powered off).

## Investigation Results (2024-12-04)

### What Works

- **Hardware PME support confirmed**: `PME(D0+,D1+,D2+,D3hot+,D3cold+)` — NIC can wake from all states
- ACPI wakeup enabled for PCIe slot (`PXSX *enabled pci:0000:09:00.0`)
- Device power wakeup enabled via `/sys/class/net/enp9s0/device/power/wakeup`
- NetworkManager managing interface via DHCP (already has `wake-on-lan: magic` configured)
- Sleep states supported: `freeze mem` with `s2idle [deep]`
- WOL worked on same hardware under Windows 10 (Killer Networking Suite driver)

### What Does NOT Work

```bash
# ethtool shows NO WOL capability (tested via nix-shell -p ethtool)
$ ethtool enp9s0
# Missing: "Supports Wake-on:" and "Wake-on:" lines

# Attempting to enable WOL fails
$ ethtool -s enp9s0 wol g
netlink error: Operation not supported
```

- `ethtool` not in system packages (must use `nix-shell -p ethtool`)
- NetworkManager WOL config accepted but ineffective (underlying ethtool fails)
- systemd-networkd `linkConfig.WakeOnLan` would fail for same reason
- No kernel parameters or module options expose WOL (hardcoded disable)
- No existing `boot.kernelPatches` in configuration

### Root Cause

WOL was disabled in the mainline `alx` driver due to a bug causing double wakeups (unresolved upstream since ~2013).

---

## Solution: Patched alx Driver

The only way to enable WOL is to apply an out-of-tree patch to re-enable WOL support.

### Patch Sources

| Source                  | URL                                                                                          | Notes                                               |
| ----------------------- | -------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| Original Bugzilla Patch | <https://bugzilla.kernel.org/attachment.cgi?id=300398>                                       | From 2013, needs adaptation                         |
| Bug Report              | <https://bugzilla.kernel.org/show_bug.cgi?id=61651>                                          | Context and discussion                              |
| DKMS Package (Best)     | <https://github.com/AndiWeiss/alx-wol>                                                       | v3.1 fixes for kernels 6.5+, tested on many distros |
| Ubuntu DKMS             | <https://github.com/jhwshin/alx-wol-dkms>                                                    | Ubuntu-focused                                      |
| Install Script          | <https://gist.github.com/ammgws/ce229a6cdd4657e381cde11363eb6e4d>                            | Debian/Ubuntu                                       |
| AUR Package             | <https://aur.archlinux.org/packages/alx-wol-dkms>                                            | Arch Linux                                          |
| Split Patches (6.x)     | <https://www.linuxquestions.org/questions/slackware-14/alx-wol-working-in-6-1-x-4175722247/> | For newer kernels                                   |

### NixOS Implementation Options

#### Option A: Patch via Nix Kernel Configuration (Recommended)

```nix
# Add to hosts/gpc0/configuration.nix
boot.kernelPatches = [
  {
    name = "alx-wol-patch";
    patch = pkgs.fetchurl {
      url = "https://bugzilla.kernel.org/attachment.cgi?id=300398";
      sha256 = ""; # Compute with: nix-prefetch-url <url>
    };
  }
];
```

For split patches (better compatibility with kernel 6.17):

```nix
boot.kernelPatches = [
  {
    name = "alx-wol-main";
    patch = ./patches/alx-wol-main.patch;
  }
  {
    name = "alx-wol-hw";
    patch = ./patches/alx-wol-hw.patch;
  }
  # ... additional split patches
];
```

Rebuild: `nixos-rebuild switch --upgrade`

#### Option B: Manual Patch and Module Build

```bash
# Download kernel sources
nix-shell -p linuxPackages_latest.kernel

# Navigate to driver
cd drivers/net/ethernet/atheros/alx/

# Apply patch
patch -p1 < /path/to/alx-wol.patch

# Build module
make -C /path/to/kernel M=$PWD

# Install
make -C /path/to/kernel M=$PWD modules_install

# Load
rmmod alx
insmod /lib/modules/6.17.9/extra/alx.ko
```

**Note:** Compilation may take 3+ hours. Reapply after kernel updates.

#### Option C: Downgrade Kernel (Fallback)

If patching fails, WOL wasn't disabled in kernels ≤5.14:

```nix
boot.kernelPackages = pkgs.linuxPackages_5_10;
```

### Post-Patch Configuration

After patching, the original implementation should work:

```nix
# Enable WOL via ethtool service
systemd.services.wol-enable = {
  description = "Enable Wake-on-LAN";
  after = [ "network.target" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    Type = "oneshot";
    ExecStart = "${pkgs.ethtool}/bin/ethtool -s enp9s0 wol g";
  };
};
environment.systemPackages = [ pkgs.ethtool ];
```

### Verification

```bash
# After patching, ethtool should show:
ethtool enp9s0 | grep -i wake
# Expected: "Supports Wake-on: pg" and "Wake-on: g"

# Enable WOL
ethtool -s enp9s0 wol g

# Test from another machine
wakeonlan 4C:CC:6A:B2:3E:38
# Or with broadcast
wakeonlan -i 192.168.1.255 4C:CC:6A:B2:3E:38
```

---

## Known Issues and Considerations

### Kernel Compatibility

- Patch from 2013 may not apply cleanly to kernel 6.17
- Use split patches from LinuxQuestions thread for 6.x kernels
- May need to undefine `PCI_IRQ_LEGACY` in `main.c` to fix compiler errors

### Runtime Issues

- On kernels <6.5: Setting `wol d` (disable) may break interface on wake — reboot or reload module
- Hibernation may only resume loopback — add scripts to down/up interface pre/post-hibernate
- One NixOS user reported ethtool shows support but packets fail (incomplete loading)

### Security

- Building out-of-tree modules requires caution
- Verify patch sources before applying

### Testing Recommendation

Test on a live USB (e.g., Ubuntu with DKMS package) first to validate patch works on this specific hardware before NixOS changes.

---

## Community Resources

- Reddit: <https://www.reddit.com/r/NixOS/comments/1iqip55/enabling_wakeonlan_on_alx_network_cards/>
- Proxmox Forum: <https://forum.proxmox.com/threads/atheros-killer-e2400-ethernet-controller-wol-need-help.153631/>
- Community reports success on MSI boards with Killer E2400

---

## Acceptance Criteria

- [ ] Patch applied to alx driver
- [ ] Kernel rebuilt with patched module
- [ ] `ethtool enp9s0` shows "Supports Wake-on: pg"
- [ ] `ethtool -s enp9s0 wol g` succeeds
- [ ] WOL service enabled in configuration.nix
- [ ] Test WOL from imac0
- [ ] Verify gpc0 wakes from power-off state

## Priority

Low — convenience feature, gpc0 is not critical infrastructure. Requires significant effort (kernel patching).

## Notes

- Requires physical access to apply the first time
- After first successful rebuild, can wake remotely for future updates
- Consider testing on Ubuntu live USB first to validate approach
