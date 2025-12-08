# 2025-12-07 - hsb8: Deploy Uzumaki Module

## Status: DONE (2025-12-08)

**Deployed successfully.** Pending: test suite execution and reboot verification.

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

- [x] hsb8 is online and accessible
- [x] Deploy: `nixos-rebuild switch --flake .#hsb8`
- [ ] Run test suite: `hosts/hsb8/tests/run-all-tests.sh` _(pending - next access)_
- [ ] Verify fish functions work: `fish -c "type pingt"` _(pending)_
- [ ] Verify StaSysMo works (if enabled) _(pending)_
- [ ] Reboot verification _(pending - next access)_
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
