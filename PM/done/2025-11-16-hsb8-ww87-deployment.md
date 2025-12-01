# 2025-11-16 - hsb8 Deployment to Parents' Home (ww87)

## Description

Deploy hsb8 to parents' home location (ww87). The `enable-ww87` script is already prepared and documented.

## Source

- Original: `hosts/hsb8/docs/📋 BACKLOG.md` (Future Consideration)
- Documentation: `hosts/hsb8/docs/enable-ww87.md`
- Status at extraction: Prepared but not yet executed

## Scope

Applies to: hsb8 (currently at jhw22 for testing)

## Acceptance Criteria

- [x] Server physically transported to ww87
- [x] Server connected to parents' network
- [x] `enable-ww87` script executed successfully
- [x] Network reconfigured (gateway 192.168.1.5 → 192.168.1.1)
- [x] AdGuard Home enabled and accessible
- [x] DNS service operational
- [x] Remote SSH access verified
- [x] Optionally: DHCP server enabled when ready

## Notes

- **Requires physical access** - server must be at parents' home
- Script location: `enable-ww87` command available on hsb8
- The script applies config BEFORE git commit/push (network changes needed first)
- DHCP intentionally disabled by default for safety
- See `hosts/hsb8/docs/enable-ww87.md` for full deployment guide

## Future Consideration

- **Home Assistant**: Enable Home Assistant service on hsb8 after deployment to ww87 for smart home automation at parents' location
