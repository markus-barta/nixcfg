# 2025-12-07 - hsb8: Deploy Uzumaki Module

## Status: BACKLOG (Blocked - Host Offline)

## Summary

Deploy the uzumaki module to hsb8. The configuration is ready in the repo but hsb8 is currently offline.

## Context

The uzumaki module restructure is complete for all other hosts. hsb8 has the configuration ready:

```nix
# hosts/hsb8/configuration.nix
imports = [ ../../modules/uzumaki ];

uzumaki = {
  enable = true;
  role = "server";
};
```

However, hsb8 is **offline** and hasn't received a deployment yet.

## Blocker

- **hsb8 is offline** - Cannot deploy until host is back online

## Acceptance Criteria

- [ ] hsb8 is online and accessible
- [ ] Deploy: `nixos-rebuild switch --flake .#hsb8`
- [ ] Run test suite: `hosts/hsb8/tests/run-all-tests.sh`
- [ ] Verify fish functions work: `fish -c "type pingt"`
- [ ] Verify StaSysMo works (if enabled)
- [ ] Update `hosts/DEPLOYMENT.md` to reflect current state

## Tests to Run

```bash
# After deployment
ssh hsb8
cd ~/nixcfg/hosts/hsb8/tests
./run-all-tests.sh
```

## Notes

- hsb8 is at location WW87 (remote site)
- May need physical access or remote power-on to bring online
