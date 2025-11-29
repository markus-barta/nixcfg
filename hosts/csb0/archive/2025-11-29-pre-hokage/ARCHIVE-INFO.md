# csb0 Pre-Hokage Archive

**Created**: 2025-11-29
**Source**: Live configuration from csb0 (`~/nixcfg`)
**Purpose**: Safety archive before Hokage migration

## System State at Archive Time

- **NixOS Version**: 24.11.20240926.1925c60 (Vicuna)
- **Uptime**: 267 days (before snapshot restart)
- **Generation**: 22
- **Docker Containers**: 8

## Contents

This archive contains the complete `~/nixcfg` repository from csb0, including:

- `hosts/csb0/configuration.nix` - The working configuration
- `hosts/csb0/hardware-configuration.nix`
- `hosts/csb0/disk-config.zfs.nix`
- `modules/mixins/` - Old mixin structure (being replaced by Hokage)
- `flake.nix` - The old flake configuration

## Usage

If needed during migration, reference these files for:

- Original service configurations
- Mixin structure that worked
- Fallback configuration patterns

## Related Backups

| Type    | Location        | Snapshot ID          |
| ------- | --------------- | -------------------- |
| Netcup  | SCP Panel       | pre-hokage-migration |
| Restic  | Hetzner Storage | 270bca1b             |
| Archive | This folder     | -                    |
