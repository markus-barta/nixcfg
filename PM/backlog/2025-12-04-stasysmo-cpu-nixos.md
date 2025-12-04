# 2025-12-04 - StaSysMo CPU Utilization Not Working on NixOS

## Description

CPU utilization metric does not work correctly in StaSysMo on NixOS. Observed on hsb0.

## Type

Bug

## Affected Host

- `hsb0` (NixOS)

## Expected Behavior

CPU utilization should display accurate percentage (e.g., `C 5%`) based on delta calculation from `/proc/stat` samples.

## Actual Behavior

CPU utilization is not being reported correctly (needs investigation to determine exact symptom - always 0%, always ?, or other).

## Probable Cause

Based on the daemon implementation, CPU% is calculated as delta between `/proc/stat` samples. Possible causes:

- `/proc/stat` parsing issue on NixOS
- Daemon not properly calculating delta
- File permissions on `/dev/shm/stasysmo/`
- Daemon timing issues

## Investigation Steps

1. Check daemon is running: `systemctl status stasysmo-daemon`
2. Check output files: `ls -la /dev/shm/stasysmo/`
3. Check CPU file contents: `cat /dev/shm/stasysmo/cpu`
4. Check daemon logs: `journalctl -u stasysmo-daemon`
5. Manually verify `/proc/stat` is readable

## Acceptance Criteria

- [ ] Identify root cause of CPU utilization failure
- [ ] Fix the daemon or reader script
- [ ] Verify CPU% displays correctly on hsb0
- [ ] Test on other NixOS hosts to confirm fix works generally
- [ ] Document any platform-specific quirks discovered

## Related Files

- `modules/shared/stasysmo/daemon.sh` - Daemon that samples metrics
- `modules/shared/stasysmo/reader.sh` - Reader that displays in prompt
- `modules/shared/stasysmo/nixos.nix` - NixOS module

## Notes

- RAM, Load, and Swap metrics may or may not be affected (needs verification)
- macOS uses a different CPU measurement method (`ps` based), so this is Linux-specific
