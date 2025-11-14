# Hardware Overview

## System Information

- **Model Name:** iMac
- **Model Identifier:** iMac19,1
- **Processor Name:** 8-Core Intel Core i9
- **Processor Speed:** 3,6 GHz
- **Number of Processors:** 1
- **Total Number of Cores:** 8
- **L2 Cache (per Core):** 256 KB
- **L3 Cache:** 16 MB
- **Hyper-Threading Technology:** Enabled
- **Memory:** 16 GB
- **Architecture:** x86_64 (Intel)
- **System Firmware Version:** 2075.100.3.0.3
- **OS Loader Version:** 583~2317
- **SMC Version (system):** 2.46f12

## Graphics & Display

- **Graphics Card:** Radeon Pro Vega 48
- **VRAM:** 8 GB
- **Bus:** PCIe x16
- **Metal Support:** Metal 3
- **Display:** Built-In Retina LCD
- **Resolution:** Retina 5K (5120 x 2880)
- **Color Depth:** 30-Bit Color (ARGB2101010)
- **Display Size:** 27-inch

## Storage

- **Drive Type:** Apple SSD SM1024L
- **Capacity:** ~796 GB (1 TB physical)
- **Protocol:** PCI-Express
- **File System:** APFS
- **S.M.A.R.T. Status:** Verified
- **Internal:** Yes

**Note:** Separate APFS volume for `/nix` store (disk1s7)

## Operating System

- **macOS Version:** 15.7.2 (Sequoia)
- **Build Version:** 24G325
- **Architecture:** x86_64-darwin

**Migration Note:** This is macOS Sequoia (15.x). The migration plan specifically avoids nix-darwin to prevent conflicts with major macOS updates. This hardware info should be updated if/when upgrading to future macOS versions.

## Development Tools

- **Xcode Command Line Tools:** Version 2410
- **Homebrew:** Installed (203 formulae, 13 casks - see migration.md)

## Migration Context

This hardware information is relevant for:

- **Nix platform detection:** `x86_64-darwin` (Intel macOS)
- **Display scaling:** 5K Retina display may require HiDPI considerations for some tools
- **Storage planning:** Separate `/nix` volume ensures Nix store isolation
- **macOS version:** Sequoia (15.7.2) - current as of migration planning
