# P5300-uptime-kuma-apprise-integration

## Context

Uptime Kuma is running on `hsb0` via the native NixOS service. The user wants to use Apprise for notifications, but the UI reports that Apprise is not installed. An existing Apprise service (API) is running on `hsb1`.

## Goals

- [ ] Install `apprise` CLI on `hsb0`
- [ ] Ensure Uptime Kuma service on `hsb0` has `apprise` in its `PATH`
- [ ] Enable the use of Apprise notifications in Uptime Kuma

## Implementation Plan

1. Update `hosts/hsb0/configuration.nix` to include `pkgs.apprise` in `environment.systemPackages`.
2. Update `hosts/hsb0/configuration.nix` to include `pkgs.apprise` in `systemd.services.uptime-kuma.path`.
3. Deploy to `hsb0` using `gpc0` as build host.
4. Verify the "Apprise is not installed" message is gone in the Uptime Kuma UI.

## Risks

- 🟢 LOW: Only affects Uptime Kuma service on a home server.

## References

- `hosts/hsb0/configuration.nix`
- `hosts/hsb1/docs/RUNBOOK.md` (Apprise service on hsb1)
